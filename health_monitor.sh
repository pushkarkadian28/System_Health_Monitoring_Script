#!/usr/bin/env bash
#
# health_monitor.sh
#
# Monitors CPU usage, memory usage, disk space, and running process count.
# Every check is fully logged to a log file with a timestamp, regardless
# of mode. In watch mode, the console shows a live dashboard that redraws
# in place each cycle instead of scrolling, so it stays readable during
# a long-running session. Exits non-zero if any alert fired on a single
# run, so it's safe to use in cron or as a monitoring check.
#
# Usage:
#   ./health_monitor.sh
#   ./health_monitor.sh -c 90 -m 85 -d 90
#   ./health_monitor.sh -w 60
#
# Options:
#   -c   CPU usage alert threshold, percent (default: 80)
#   -m   Memory usage alert threshold, percent (default: 80)
#   -d   Disk usage alert threshold, percent, checked on every mounted
#        real filesystem, not just / (default: 80)
#   -p   Process count alert threshold (default: 500; a sudden spike can
#        indicate a fork bomb or runaway process spawning children)
#   -l   Log file path (default: health_monitor.log)
#   -w   Watch mode: redraw a live dashboard every N seconds until
#        Ctrl+C, instead of running once and exiting

set -uo pipefail

CPU_THRESHOLD=80
MEM_THRESHOLD=80
DISK_THRESHOLD=80
PROC_THRESHOLD=500
LOG_FILE="health_monitor.log"
WATCH_INTERVAL=0

usage() {
    echo "Usage: $0 [-c CPU_PCT] [-m MEM_PCT] [-d DISK_PCT] [-p PROC_COUNT] [-l LOG_FILE] [-w INTERVAL_SECONDS]"
    exit 1
}

while getopts "c:m:d:p:l:w:h" opt; do
    case "$opt" in
        c) CPU_THRESHOLD="$OPTARG" ;;
        m) MEM_THRESHOLD="$OPTARG" ;;
        d) DISK_THRESHOLD="$OPTARG" ;;
        p) PROC_THRESHOLD="$OPTARG" ;;
        l) LOG_FILE="$OPTARG" ;;
        w) WATCH_INTERVAL="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

ALERT_FIRED=0

# Writes a timestamped line to the log file only. This is the "log
# maker", every check always writes here in full, whether or not the
# console is showing scrolling output or a redrawn dashboard.
log() {
    local msg="$1"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] $msg" >> "$LOG_FILE"
}

alert() {
    local msg="$1"
    ALERT_FIRED=1
    log "ALERT: $msg"
}

ok() {
    local msg="$1"
    log "OK: $msg"
}

# --- CPU usage ---
# Reads /proc/stat twice, one second apart, and computes usage from the
# delta. More reliable across distros than parsing `top`'s output, which
# varies in format between versions.
CPU_USAGE=0
check_cpu() {
    local cpu1 cpu2
    cpu1=($(head -1 /proc/stat))
    sleep 1
    cpu2=($(head -1 /proc/stat))

    local idle1=${cpu1[4]}
    local idle2=${cpu2[4]}

    local total1=0 total2=0
    for v in "${cpu1[@]:1}"; do total1=$((total1 + v)); done
    for v in "${cpu2[@]:1}"; do total2=$((total2 + v)); done

    local total_delta=$((total2 - total1))
    local idle_delta=$((idle2 - idle1))

    CPU_USAGE=0
    if (( total_delta > 0 )); then
        CPU_USAGE=$(( (100 * (total_delta - idle_delta)) / total_delta ))
    fi

    if (( CPU_USAGE >= CPU_THRESHOLD )); then
        alert "CPU usage at ${CPU_USAGE}% (threshold: ${CPU_THRESHOLD}%)"
    else
        ok "CPU usage at ${CPU_USAGE}%"
    fi
}

# --- Memory usage ---
MEM_USAGE=0
check_memory() {
    local mem_total mem_available

    mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    mem_available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)

    if [[ -z "$mem_total" || -z "$mem_available" || "$mem_total" -eq 0 ]]; then
        log "WARNING: Could not read memory info from /proc/meminfo"
        MEM_USAGE=0
        return
    fi

    MEM_USAGE=$(( 100 * (mem_total - mem_available) / mem_total ))

    if (( MEM_USAGE >= MEM_THRESHOLD )); then
        alert "Memory usage at ${MEM_USAGE}% (threshold: ${MEM_THRESHOLD}%)"
    else
        ok "Memory usage at ${MEM_USAGE}%"
    fi
}

# --- Disk usage ---
# Checks every real mounted filesystem, skipping virtual ones (tmpfs,
# devtmpfs, overlay used for containers, etc.) that don't represent
# actual disk capacity worth alerting on.
DISK_LINES=()
check_disk() {
    DISK_LINES=()
    local line filesystem use_pct mount_point

    while read -r line; do
        filesystem=$(echo "$line" | awk '{print $1}')
        use_pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
        mount_point=$(echo "$line" | awk '{print $6}')

        [[ "$use_pct" =~ ^[0-9]+$ ]] || continue

        if (( use_pct >= DISK_THRESHOLD )); then
            alert "Disk usage at ${use_pct}% on ${mount_point} (${filesystem}), threshold: ${DISK_THRESHOLD}%"
            DISK_LINES+=("ALERT  ${use_pct}%  ${mount_point}")
        else
            ok "Disk usage at ${use_pct}% on ${mount_point} (${filesystem})"
            DISK_LINES+=("OK     ${use_pct}%  ${mount_point}")
        fi
    done < <(df -h -x tmpfs -x devtmpfs -x overlay -x squashfs --output=source,size,used,avail,pcent,target 2>/dev/null | tail -n +2)
}

# --- Running process count ---
PROC_COUNT=0
check_processes() {
    PROC_COUNT=$(ps -e --no-headers | wc -l)

    if (( PROC_COUNT >= PROC_THRESHOLD )); then
        alert "Running process count at ${PROC_COUNT} (threshold: ${PROC_THRESHOLD})"
    else
        ok "Running process count at ${PROC_COUNT}"
    fi
}

# --- Top resource consumers ---
TOP_CPU=()
TOP_MEM=()
collect_top_processes() {
    log "Top 5 CPU-consuming processes:"
    TOP_CPU=()
    while read -r pid comm cpu; do
        TOP_CPU+=("PID $pid  $comm  ${cpu}% CPU")
        log "  PID $pid  $comm  ${cpu}% CPU"
    done < <(ps -eo pid,comm,%cpu --sort=-%cpu --no-headers | head -5)

    log "Top 5 memory-consuming processes:"
    TOP_MEM=()
    while read -r pid comm mem; do
        TOP_MEM+=("PID $pid  $comm  ${mem}% MEM")
        log "  PID $pid  $comm  ${mem}% MEM"
    done < <(ps -eo pid,comm,%mem --sort=-%mem --no-headers | head -5)
}

run_check() {
    ALERT_FIRED=0
    log "===== Health check started ====="
    check_cpu
    check_memory
    check_disk
    check_processes
    collect_top_processes

    if (( ALERT_FIRED )); then
        log "===== Health check complete: ALERTS FIRED ====="
    else
        log "===== Health check complete: all metrics normal ====="
    fi
}

status_word() {
    local usage="$1" threshold="$2"
    if (( usage >= threshold )); then
        echo "ALERT"
    else
        echo "OK"
    fi
}

# Redraws the terminal in place with a compact live view of the last
# check. Full detail always lives in the log file regardless of what's
# shown here, this is just the human-facing summary.
render_dashboard() {
    clear
    echo "System Health Monitor  (watch mode, every ${WATCH_INTERVAL}s, Ctrl+C to stop)"
    echo "Last check: $(date '+%Y-%m-%d %H:%M:%S')     Log file: ${LOG_FILE}"
    echo "============================================================"
    printf "%-8s %-10s %s\n" "STATUS" "METRIC" "VALUE"
    printf "%-8s %-10s %s\n" "------" "------" "-----"
    printf "%-8s %-10s %s%%\n" "$(status_word "$CPU_USAGE" "$CPU_THRESHOLD")" "CPU" "$CPU_USAGE"
    printf "%-8s %-10s %s%%\n" "$(status_word "$MEM_USAGE" "$MEM_THRESHOLD")" "Memory" "$MEM_USAGE"
    printf "%-8s %-10s %s\n" "$(status_word "$PROC_COUNT" "$PROC_THRESHOLD")" "Processes" "$PROC_COUNT"

    echo ""
    echo "Disk:"
    for line in "${DISK_LINES[@]}"; do
        echo "  $line"
    done

    echo ""
    echo "Top CPU:"
    for line in "${TOP_CPU[@]}"; do
        echo "  $line"
    done

    echo ""
    echo "Top Memory:"
    for line in "${TOP_MEM[@]}"; do
        echo "  $line"
    done

    echo "============================================================"
    if (( ALERT_FIRED )); then
        echo "STATUS: ALERTS FIRED, see ${LOG_FILE} for full history."
    else
        echo "STATUS: all metrics normal."
    fi
}

if (( WATCH_INTERVAL > 0 )); then
    log "Starting watch mode, checking every ${WATCH_INTERVAL}s."
    while true; do
        run_check
        render_dashboard
        sleep "$WATCH_INTERVAL"
    done
else
    run_check
    cat "$LOG_FILE"
    exit $ALERT_FIRED
fi
