# System Health Monitoring Script

Submission for the Accuknox DevOps Trainee Practical Assessment, Problem Statement 2 (Objective 1: System Health Monitoring).

Monitors CPU usage, memory usage, disk space, and running process count on a Linux system. Alerts to the console and a log file when any metric crosses its threshold.

## What it does

- **CPU usage**: computed from `/proc/stat` deltas over a 1-second window, rather than parsing `top`'s output, which varies in format across distros and versions.
- **Memory usage**: read from `/proc/meminfo`, using `MemAvailable` rather than raw `MemFree`, since `MemAvailable` accounts for reclaimable cache and gives a more accurate picture of actual pressure.
- **Disk usage**: checks every real mounted filesystem, not just `/`. Virtual filesystems (tmpfs, devtmpfs, overlay, squashfs) are excluded since they don't represent real disk capacity worth alerting on.
- **Process count**: total running processes, alerts if it spikes past a threshold, useful for catching fork bombs or runaway process spawning.
- **Top consumers**: shows the top 5 CPU and top 5 memory consuming processes on every run, for context, not itself an alert condition.

Every run is logged with a timestamp, and the script exits with status code 1 if any alert fired, 0 if everything is normal, so it plugs cleanly into cron or any monitoring pipeline that checks exit codes.

## Requirements

- Bash
- Standard Linux utilities: `awk`, `ps`, `df`, `sleep`. No external packages.

## Usage

Run once with default thresholds (80% for CPU, memory, and disk; 500 processes):

```
chmod +x health_monitor.sh
./health_monitor.sh
```

Set custom thresholds:

```
./health_monitor.sh -c 90 -m 85 -d 90 -p 300
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-c` | CPU usage alert threshold, percent | 80 |
| `-m` | Memory usage alert threshold, percent | 80 |
| `-d` | Disk usage alert threshold, percent (checked per mounted filesystem) | 80 |
| `-p` | Process count alert threshold | 500 |
| `-l` | Log file path | `health_monitor.log` |
| `-w` | Watch mode: repeat every N seconds until Ctrl+C, instead of running once | off |

## Example: all metrics normal

```
[2026-08-15 16:44:58] ===== Health check started =====
[2026-08-15 16:44:59] OK: CPU usage at 2%
[2026-08-15 16:44:59] OK: Memory usage at 5%
[2026-08-15 16:44:59] OK: Disk usage at 47% on / (/dev/vda)
[2026-08-15 16:44:59] OK: Running process count at 55
[2026-08-15 16:44:59] Top 5 CPU-consuming processes:
[2026-08-15 16:44:59]   PID 1  process_api  1.5% CPU
...
[2026-08-15 16:44:59] ===== Health check complete: all metrics normal =====
```

Exit code: `0`

## Example: alerts firing

```
[2026-08-15 16:45:03] ALERT: CPU usage at 92% (threshold: 80%)
[2026-08-15 16:45:03] ALERT: Memory usage at 88% (threshold: 80%)
[2026-08-15 16:45:03] OK: Disk usage at 47% on / (/dev/vda)
[2026-08-15 16:45:03] ALERT: Running process count at 612 (threshold: 500)
...
[2026-08-15 16:45:03] ===== Health check complete: ALERTS FIRED =====
```

Exit code: `1`

## Automating it with cron

Run every 5 minutes and log to a fixed location:

```
crontab -e
```

Add:

```
*/5 * * * * /path/to/health_monitor.sh -l /var/log/health_monitor.log >> /var/log/health_monitor_cron.log 2>&1
```

## Watch mode

For continuous local monitoring without cron:

```
./health_monitor.sh -w 60
```

Checks every 60 seconds until you stop it with Ctrl+C. Useful for keeping an eye on a system during a deploy or a load test without needing to schedule anything.

## A note on process-based alerting

The process count threshold is a coarse signal, a sudden jump (e.g. hundreds of new processes in one check) is usually more meaningful than the absolute number itself, since normal process counts vary a lot between a minimal server and one running many services. Treat the default of 500 as a starting point and adjust it to what's normal on your own system after a few runs.
