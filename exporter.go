package main

import (
	"bufio"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	mirrorSize = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "arch_mirror_size_bytes",
		Help: "Size of each repository in bytes",
	}, []string{"repo"})

	mirrorFiles = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "arch_mirror_files_total",
		Help: "Number of files in each repository",
	}, []string{"repo"})

	lastSync = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "arch_mirror_last_sync_timestamp",
		Help: "Unix timestamp of last successful sync",
	})

	syncStatus = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "arch_mirror_sync_status",
		Help: "Sync status: 1=success, 0=failed",
	})

	syncDuration = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "arch_mirror_sync_duration_seconds",
		Help: "Duration of last sync in seconds",
	})

	diskUsage = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "arch_mirror_disk_usage_bytes",
		Help: "Disk usage for mirror partition",
	}, []string{"mountpoint", "type"})
)

func init() {
	prometheus.MustRegister(mirrorSize, mirrorFiles, lastSync, syncStatus, syncDuration, diskUsage)
}

func collectMirrorMetrics(mirrorPath string) {
	repos := []string{"core", "extra", "community", "multilib", "iso", "pool"}

	for _, repo := range repos {
		repoPath := filepath.Join(mirrorPath, repo)
		var size int64
		var files int64

		filepath.Walk(repoPath, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return nil
			}
			if !info.IsDir() {
				size += info.Size()
				files++
			}
			return nil
		})

		mirrorSize.WithLabelValues(repo).Set(float64(size))
		mirrorFiles.WithLabelValues(repo).Set(float64(files))
	}
}

func collectSyncMetrics(logPath string) {
	file, err := os.Open(logPath)
	if err != nil {
		return
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	var lastSyncTime time.Time
	var lastStatus float64 = 0

	for scanner.Scan() {
		line := scanner.Text()
		if strings.Contains(line, "Sync completed successfully") {
			lastStatus = 1
			// Extract timestamp from log line
			if t, err := time.Parse("2006-01-02 15:04:05", strings.Split(line, " - ")[0]); err == nil {
				lastSyncTime = t
			}
		} else if strings.Contains(line, "Sync failed") {
			lastStatus = 0
		}
	}

	if !lastSyncTime.IsZero() {
		lastSync.Set(float64(lastSyncTime.Unix()))
	}
	syncStatus.Set(lastStatus)
}

func collectDiskMetrics() {
	// NOTE: /srv on the host is bind-mounted to /mirror in this container,
	// so stat the mount we actually have. Statfs("/srv") would report the
	// container rootfs instead and give misleading disk numbers.
	mountpoint := os.Getenv("MIRROR_PATH")
	if mountpoint == "" {
		mountpoint = "/mirror"
	}
	var stat syscall.Statfs_t
	if err := syscall.Statfs(mountpoint, &stat); err != nil {
		return
	}
	diskUsage.WithLabelValues(mountpoint, "total").Set(float64(stat.Blocks * uint64(stat.Bsize)))
	diskUsage.WithLabelValues(mountpoint, "free").Set(float64(stat.Bfree * uint64(stat.Bsize)))
	diskUsage.WithLabelValues(mountpoint, "available").Set(float64(stat.Bavail * uint64(stat.Bsize)))
}

func metricsHandler(w http.ResponseWriter, r *http.Request) {
	mirrorPath := os.Getenv("MIRROR_PATH")
	if mirrorPath == "" {
		mirrorPath = "/mirror"
	}
	logPath := os.Getenv("SYNC_LOG_PATH")
	if logPath == "" {
		logPath = "/var/log/arch-mirror-sync.log"
	}

	collectMirrorMetrics(mirrorPath)
	collectSyncMetrics(logPath)
	collectDiskMetrics()

	promhttp.Handler().ServeHTTP(w, r)
}

func main() {
	http.HandleFunc("/metrics", metricsHandler)
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		w.Write([]byte("OK"))
	})
	http.ListenAndServe(":9100", nil)
}
