#!/usr/bin/env bash
# hype-version: 2.2-excludes
# mirror-hype.sh v2 — screenshot-worthy Arch Linux mirror seeding progress.
# Deployed correctly? `grep hype-version mirror-hype.sh` must print 2.2-excludes.
#
# Usage:
#   ./mirror-hype.sh          # single snapshot (best for screenshots)
#   ./mirror-hype.sh --live   # in-place refresh, no flicker (Ctrl+C to stop)
#
# Env overrides (for testing): MIRROR_ROOT, LOG_FILE, EXPECTED_GB, MIRROR_SOURCE
set -u
export LC_ALL=${LC_ALL:-C.UTF-8}   # multibyte-safe ${#} for box padding

ROOT="${MIRROR_ROOT:-/srv/http/archlinux}"
LOG="${LOG_FILE:-/var/log/arch-mirror-sync.log}"
EXCLUDE="${RSYNC_EXCLUDE:-/srv/apps/arch-mirror/rsync-exclude.txt}"
EXPECTED_GB="${EXPECTED_GB:-100}"
EXPECTED_GB="${EXPECTED_GB%.*}"   # bar math needs an integer
LIVE=0
[[ "${1:-}" == "--live" ]] && LIVE=1
W=64
STATE_DIR=/tmp/mirror-hype
BASELINE_FILE=$STATE_DIR/baseline      # "<epoch>:<used_kb_at_first_run>"
TOTAL_FILE=$STATE_DIR/upstream-total-v2  # "<epoch>:<exclude-mtime>:<kb>" (7d, re-probes if excludes change)
PROBE_LOCK=$STATE_DIR/probe.lock
PROBE_ATTEMPT=$STATE_DIR/probe-attempt # "<epoch>" (1h retry cooldown on failure)
RATES_FILE=$STATE_DIR/rates            # space-separated MB/s history (last 24)
FILES_CACHE=$STATE_DIR/files           # "<epoch>:<count>"
REPOS_CACHE=$STATE_DIR/repos           # "<epoch>" + lines "name mb"
mkdir -p "$STATE_DIR" 2>/dev/null || true

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\e[1m'; DIM=$'\e[2m'; RST=$'\e[0m'
  CYAN=$'\e[1;36m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'
  MAGENTA=$'\e[1;35m'; BLUE=$'\e[1;34m'; GRAY=$'\e[90m'; RED=$'\e[1;31m'
else
  B=''; DIM=''; RST=''; CYAN=''; GREEN=''; YELLOW=''
  MAGENTA=''; BLUE=''; GRAY=''; RED=''
fi

row() { # row <visible-plain> <colored>
  local plain=$1 text=$2 pad
  pad=$(( W - 2 - ${#plain} ))
  (( pad < 0 )) && pad=0
  printf "${CYAN}║${RST} %s%*s${CYAN}║${RST}\n" "$text" "$pad" ""
}
hr_top()    { local i; printf "${CYAN}╔"; for ((i=0;i<W;i++)); do printf '═'; done; printf "╗${RST}\n"; }
hr_mid()    { local i; printf "${CYAN}╠"; for ((i=0;i<W;i++)); do printf '═'; done; printf "╣${RST}\n"; }
hr_bottom() { local i; printf "${CYAN}╚"; for ((i=0;i<W;i++)); do printf '═'; done; printf "╝${RST}\n"; }

bar_plain() { local pct=$1 w=$2 out i; (( pct<0 )) && pct=0; (( pct>100 )) && pct=100
  out=""; for ((i=0;i<pct*w/100;i++)); do out+="█"; done
  for ((i=${#out};i<w;i++)); do out+="░"; done; printf '%s' "$out"; }
bar_color() { local pct=$1 w=$2 i; (( pct<0 )) && pct=0; (( pct>100 )) && pct=100
  printf "${GREEN}"; for ((i=0;i<pct*w/100;i++)); do printf '█'; done
  printf "${GRAY}";  for ((i=pct*w/100;i<w;i++));  do printf '░'; done
  printf "${RST}"; }
minibar() { # minibar <pct> <width> (cyan) — prints PLAIN blocks, caller colors
  local pct=$1 w=$2 out i; (( pct<0 )) && pct=0; (( pct>100 )) && pct=100
  out=""; for ((i=0;i<pct*w/100;i++)); do out+="█"; done
  for ((i=${#out};i<w;i++)); do out+="░"; done; printf '%s' "$out"; }

human() { awk -v kb="$1" 'BEGIN{
  if (kb >= 1048576) printf "%.1f GB", kb/1048576;
  else if (kb >= 1024) printf "%.1f MB", kb/1024;
  else printf "%d KB", kb }'; }

file_count() {
  local now age=9999 cached="?"
  now=$(date +%s)
  if [[ -f "$FILES_CACHE" ]]; then
    cached=$(cut -d: -f2 "$FILES_CACHE" 2>/dev/null || echo "?")
    age=$(( now - $(cut -d: -f1 "$FILES_CACHE" 2>/dev/null || echo 0) ))
  fi
  if (( age > 120 )); then
    local ferr
    ferr=$(mktemp /tmp/hype-find.XXXXXX 2>/dev/null || echo /tmp/hype-find.err)
    cached=$(find "$ROOT" -type f 2>"$ferr" | wc -l | tr -d ' ')
    # rsync stages into root-owned .~tmp~ dirs mid-sync: un-sudoed runs go
    # blind and undercount. Say so on-screen instead of printing a lie.
    if grep -q 'Permission denied' "$ferr" 2>/dev/null; then cached="$cached (use sudo)"; fi
    rm -f "$ferr"
    echo "$now:$cached" > "$FILES_CACHE" 2>/dev/null || true
  fi
  printf '%s' "$cached"
}

repo_breakdown() { # prints lines "name mb" (cached 90s)
  local now age=9999
  now=$(date +%s)
  if [[ -f "$REPOS_CACHE" ]]; then
    age=$(( now - $(head -n1 "$REPOS_CACHE" 2>/dev/null || echo 0) ))
  fi
  if (( age > 90 )); then
    { echo "$now"
      for d in core extra community multilib iso pool; do
        [[ -d "$ROOT/$d" ]] || continue
        echo "$d $(du -sm "$ROOT/$d" 2>/dev/null | cut -f1)"
      done; } > "$REPOS_CACHE" 2>/dev/null || true
  fi
  tail -n +2 "$REPOS_CACHE" 2>/dev/null
}

# NOTE: [r]sync trick — a plain "rsync" here would make pgrep match the
# shell that invoked it (its cmdline contains the pattern text itself).
sync_alive() { pgrep -f "[r]sync.*archlinux/" >/dev/null 2>&1; }

upstream_src() { # where we sync from: sync log (actual) > env > nothing
  local from_log=""
  if [[ -f "$LOG" ]]; then
    from_log=$(grep -m1 'Starting sync from' "$LOG" 2>/dev/null | sed -E 's/.*Starting sync from //')
  fi
  if [[ -n "$from_log" ]]; then printf '%s' "$from_log"; return 0; fi
  if [[ -n "${MIRROR_SOURCE:-}" ]]; then printf '%s' "$MIRROR_SOURCE"; return 0; fi
  return 1
}

launch_probe() {
  # One-shot background measurement of the REAL upstream total:
  # `rsync --list-only` streams the file list, awk sums regular-file sizes,
  # honoring the SAME --exclude-from as sync.sh so junk like Rackspace's
  # archive/ never inflates the number. Niced/ioniced, cached 7d, 1h cooldown.
  local src now last=0 lock_tmp exmtime=0
  src=$(upstream_src)
  [[ -z "$src" ]] && return 0
  now=$(date +%s)
  [[ -f "$PROBE_ATTEMPT" ]] && last=$(cat "$PROBE_ATTEMPT" 2>/dev/null || echo 0)
  (( now - last < 3600 )) && return 0
  echo "$now" > "$PROBE_ATTEMPT" 2>/dev/null || true
  if ! mkdir "$PROBE_LOCK" 2>/dev/null; then
    # lock exists: fresh only if a probe process is actually alive,
    # else it's wreckage from a kill — clear it and proceed
    if pgrep -f "[r]sync --list-only" >/dev/null 2>&1; then return 0; fi
    rmdir "$PROBE_LOCK" 2>/dev/null || true
    mkdir "$PROBE_LOCK" 2>/dev/null || return 0
  fi
  local args=()
  if [[ -f "$EXCLUDE" ]]; then
    args+=( "--exclude-from=$EXCLUDE" )
    exmtime=$(stat -c %Y "$EXCLUDE" 2>/dev/null || echo 0)
  fi
  lock_tmp="$TOTAL_FILE.tmp"
  ( nice -n 10 ionice -c3 rsync --list-only -r "${args[@]}" "$src" 2>/dev/null \
      | awk -v now="$(date +%s)" -v exm="$exmtime" '/^-/{ gsub(/,/,"",$2); s+=$2 }
          END{ if (s>0) printf "%d:%d:%d", now, exm, s/1024 }' > "$lock_tmp";
    [[ -s "$lock_tmp" ]] && mv "$lock_tmp" "$TOTAL_FILE";
    rmdir "$PROBE_LOCK" ) & disown 2>/dev/null || true
}

upstream_total_kb() { # prints measured upstream KB; returns 1 if unknown yet
  local now age=999999999 cached=0 exm_now=0 exm_then=0
  now=$(date +%s)
  [[ -f "$EXCLUDE" ]] && exm_now=$(stat -c %Y "$EXCLUDE" 2>/dev/null || echo 0)
  if [[ -f "$TOTAL_FILE" ]]; then
    age=$(( now - $(cut -d: -f1 "$TOTAL_FILE" 2>/dev/null || echo 0) ))
    exm_then=$(cut -d: -f2 "$TOTAL_FILE" 2>/dev/null || echo 0)
    cached=$(cut -d: -f3 "$TOTAL_FILE" 2>/dev/null || echo 0)
  fi
  # v1 cache has only 2 fields → f3 empty → 0 → auto re-probe. Exclude edits
  # change exmtime → stale total discarded. Both migrate silently.
  if (( age <= 604800 )) && (( cached > 0 )) && (( exm_then == exm_now )); then
    printf '%s' "$cached"
    return 0
  fi
  launch_probe
  return 1
}

snapshot() {
  local used_kb disk_kb files cur rate eta pct elapsed src phase phase_c
  local plain text a b i name mb rpct session_dl
  used_kb=$(du -sk "$ROOT" 2>/dev/null | cut -f1); used_kb=${used_kb:-0}
  disk_kb=$(df -k "$ROOT" 2>/dev/null | awk 'NR==2{print $2}'); disk_kb=${disk_kb:-1}
  files=$(file_count)

  # denominator: measured upstream total when known, else the GB estimate
  local total_kb total_known=0 total_label seed_title
  if total_kb=$(upstream_total_kb); then
    total_known=1
    total_label="$(human "$total_kb")"
    seed_title="SEEDING $(human "$total_kb")"
  else
    total_kb=$(( EXPECTED_GB * 1048576 ))
    total_label="~${EXPECTED_GB} GB*"
    seed_title="SEEDING THE MIRROR"
  fi
  pct=$(awk -v u="$used_kb" -v t="$total_kb" 'BEGIN{ printf "%d", (u/t)*100 }')
  (( pct > 100 )) && pct=100

  # session baseline: downloaded since first hype run
  if [[ ! -f "$BASELINE_FILE" ]]; then echo "$(date +%s):$used_kb" > "$BASELINE_FILE" 2>/dev/null || true; fi
  session_dl=$(awk -v now="$used_kb" -v base="$(cut -d: -f2 "$BASELINE_FILE" 2>/dev/null || echo "$used_kb")" \
    'BEGIN{ d=now-base; if(d<0)d=0; printf "%.1f GB", d/1048576 }')

  # rate sample (3s) + history for sparkline
  a=$(du -sk "$ROOT" 2>/dev/null | cut -f1); a=${a:-0}
  sleep 3
  b=$(du -sk "$ROOT" 2>/dev/null | cut -f1); b=${b:-0}
  local mbs
  mbs=$(awk -v d=$(( b - a )) 'BEGIN{ printf "%.1f", d/1024/3 }')
  rate="$mbs MB/s"
  echo -n "$mbs " >> "$RATES_FILE" 2>/dev/null || true
  # cap history at last 24 samples
  if [[ -f "$RATES_FILE" ]]; then
    awk '{ n=NF>24?NF-23:1; for(i=n;i<=NF;i++) printf "%s ", $i }' "$RATES_FILE" > "$RATES_FILE.tmp" 2>/dev/null \
      && mv "$RATES_FILE.tmp" "$RATES_FILE" 2>/dev/null || true
  fi
  local spark
  spark=$(awk 'BEGIN{ split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █", lv, " ") }
    { max=0.1; for(i=1;i<=NF;i++) if($i+0>max) max=$i+0;
      for(i=1;i<=NF;i++){ idx=int(($i/max)*7)+1; if(idx>8)idx=8; printf "%s", lv[idx] } }' \
      "$RATES_FILE" 2>/dev/null)
  spark=${spark:-"▁"}

  eta=$(awk -v u="$b" -v t="$total_kb" -v d=$(( b - a )) 'BEGIN{
    if (d <= 0) print "--:--"; else { s=(t-u)/d*3; printf "%02d:%02d", s/3600, (s%3600)/60 } }')

  # phase badge
  phase="IDLE"; phase_c="$GRAY"
  if sync_alive; then
    if tail -n 8 "$LOG" 2>/dev/null | grep -qE '\[[0-9]+\] [a-z.><*+]+ +[^ ]'; then
      phase="● TRANSFERRING"; phase_c="$GREEN"
    else
      phase="◌ INDEXING UPSTREAM"; phase_c="$YELLOW"
    fi
  elif [[ -f "$ROOT/mirror-status.txt" ]]; then
    if grep -q 'status: failed' "$ROOT/mirror-status.txt" 2>/dev/null; then
      phase="✖ SYNC FAILED"; phase_c="$RED"
    elif grep -q 'status: success' "$ROOT/mirror-status.txt" 2>/dev/null; then
      phase="✓ IN SYNC"; phase_c="$GREEN"
    fi
  fi

  # current + recent files
  if [[ -f "$LOG" ]]; then
    cur=$(grep -E '\[[0-9]+\]' "$LOG" 2>/dev/null | tail -n 1 | sed -E 's/^.*\[[0-9]+\] //; s/^[^ /]+ //')
    [[ -z "$cur" ]] && cur="(building file list…)"
    src=$(grep -m1 'Starting sync from' "$LOG" 2>/dev/null | sed -E 's/.*Starting sync from //')
    src=${src:-"(unknown source)"}
  else
    cur="(log not found)"; src="(unknown source)"
  fi
  [[ ${#cur} -gt 42 ]] && cur="…${cur: -41}"

  elapsed="--:--"
  if [[ -f "$LOG" ]]; then
    local start
    start=$(grep -m1 'Starting sync from' "$LOG" 2>/dev/null | grep -oE '^[0-9-]{10} [0-9:]{8}')
    if [[ -n "$start" ]]; then
      elapsed=$(awk -v s="$(date -d "$start" +%s 2>/dev/null || echo 0)" -v n="$(date +%s)" \
        'BEGIN{ if(s>0){ d=n-s; printf "%02d:%02d", d/3600, (d%3600)/60 } else print "--:--" }')
    fi
  fi

  # service health (best effort)
  local ng ex
  # tr strips the stray blank line docker prints on stdout when it errors
  ng=$(docker inspect -f '{{.State.Health.Status}}' arch-mirror-nginx 2>/dev/null | tr -d '[:space:]' || echo "n/a")
  ex=$(docker inspect -f '{{.State.Health.Status}}' arch-mirror-exporter 2>/dev/null | tr -d '[:space:]' || echo "n/a")
  [[ -z "$ng" ]] && ng="n/a"; [[ -z "$ex" ]] && ex="n/a"

  hr_top
  plain=" ◣ ARCH LINUX MIRROR  ·  DAY ONE — $seed_title"
  text=" ${B}◣ ARCH LINUX MIRROR${RST}  ${DIM}·  DAY ONE — $seed_title${RST}"
  row "$plain" "$text"
  plain=" status  $phase"
  text=" ${DIM}status${RST}  ${phase_c}${B}$phase${RST}"
  row "$plain" "$text"
  hr_mid
  plain=" source  $src";               text=" ${DIM}source${RST}  $src";               row "$plain" "$text"
  plain=" target  $ROOT  (disk $(human "$disk_kb"))"
  text=" ${DIM}target${RST}  $ROOT  ${DIM}(disk $(human "$disk_kb"))${RST}";            row "$plain" "$text"
  plain="";                            text="";                                        row "$plain" "$text"
  plain=" $(bar_plain "$pct" 30)  $(human "$used_kb") / $total_label   ${pct}%"
  text=" $(bar_color "$pct" 30)  ${B}$(human "$used_kb")${RST} / $total_label   ${B}${pct}%${RST}"
  row "$plain" "$text"
  if (( total_known == 0 )); then
    plain=" * estimate: background probe is measuring the live upstream total"
    text=" ${DIM}* estimate: background probe is measuring the live upstream total${RST}"
    row "$plain" "$text"
  fi
  plain=" throughput $spark  $rate (eta $eta)"
  text=" ${DIM}throughput${RST} ${CYAN}$spark${RST}  $rate ${DIM}(eta $eta)${RST}"
  row "$plain" "$text"
  plain="";                            text="";                                        row "$plain" "$text"
  plain=" elapsed $elapsed   session +$session_dl   files $files"
  text=" ${YELLOW}◷ elapsed${RST} $elapsed   ${YELLOW}⇩ session${RST} +$session_dl   ${YELLOW}▦ files${RST} $files"
  row "$plain" "$text"
  plain=" now ▶ $cur"
  text=" ${MAGENTA}◆ now${RST} ${B}$cur${RST}"
  row "$plain" "$text"
  # recent files ticker (older → newer)
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    name=$(echo "$line" | awk '{print $1}'); mb=$(echo "$line" | awk '{print $2}')
    [[ ${#name} -gt 14 ]] && name="${name:0:13}…"
    rpct=$(awk -v m="$mb" -v t="$used_kb" 'BEGIN{ printf "%d", (m*1024/t)*100 }')
    plain="   $name  $(minibar "$rpct" 12)  ${mb}M"
    text="   ${DIM}$name${RST}  ${CYAN}$(minibar "$rpct" 12)${RST}  ${DIM}${mb}M${RST}"
    row "$plain" "$text"
  done < <(repo_breakdown | sort -k2 -nr | head -n 5)
  plain="";                            text="";                                        row "$plain" "$text"
  plain=" nginx [$ng]   exporter [$ex]   arch.itanishq.space"
  if [[ "$ng" == "healthy" ]]; then text_ng="${GREEN}● nginx [$ng]${RST}"; else text_ng="${GRAY}○ nginx [$ng]${RST}"; fi
  if [[ "$ex" == "healthy" ]]; then text_ex="${GREEN}● exporter [$ex]${RST}"; else text_ex="${GRAY}○ exporter [$ex]${RST}"; fi
  text=" $text_ng   $text_ex   ${BLUE}arch.itanishq.space${RST}"
  row "$plain" "$text"
  hr_bottom
}

if (( LIVE )); then
  # In-place redraw: cursor home + erase-below. No `clear` → no flicker,
  # scrollback preserved, output never "disappears".
  trap 'printf "${RST}\n"; tput cnorm 2>/dev/null || true; exit 0' INT TERM
  tput civis 2>/dev/null || true
  clear
  while true; do
    printf '\e[H'
    snapshot
    printf '\e[J'
    sleep 8
  done
else
  snapshot
fi
