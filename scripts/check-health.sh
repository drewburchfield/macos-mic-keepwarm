#!/bin/bash
# check-health.sh - Health check for the mic-warm daemon
# Outputs structured findings for human or automated review.
# Exit codes: 0 = healthy, 1 = issues found, 2 = not running
#
# Usage:
#   ./scripts/check-health.sh              # Human-readable summary
#   ./scripts/check-health.sh --json       # JSON output for automation

set -euo pipefail

LOG="${MIC_WARM_LOG:-$HOME/Library/Logs/mic-warm/mic-warm.log}"
# Installs from before v0.11 log to /tmp until install.sh is re-run.
[[ ! -f "$LOG" && -f /tmp/mic-warm.log ]] && LOG="/tmp/mic-warm.log"
JSON_MODE=false
[[ "${1:-}" == "--json" ]] && JSON_MODE=true

issues=()
warnings=()

# 1. Is the process running?
PIDS=$(pgrep -f "mic-warm$" || true)
PID=$(echo "$PIDS" | head -1)
if [[ -z "$PID" ]]; then
    issues+=("PROCESS_NOT_RUNNING: mic-warm is not running")
elif [[ $(echo "$PIDS" | wc -l) -gt 1 ]]; then
    issues+=("MULTIPLE_INSTANCES: $(echo $PIDS) are all running")
fi

# 2. Is the log file present and recent?
if [[ ! -f "$LOG" ]]; then
    issues+=("NO_LOG_FILE: $LOG does not exist")
else
    # Check last modification time
    if [[ "$(uname)" == "Darwin" ]]; then
        last_mod=$(stat -f %m "$LOG")
    else
        last_mod=$(stat -c %Y "$LOG")
    fi
    now=$(date +%s)
    age_seconds=$((now - last_mod))

    if [[ $age_seconds -gt 30 ]]; then
        age_human="${age_seconds}s"
        if [[ $age_seconds -gt 3600 ]]; then
            age_human="$(( age_seconds / 3600 ))h $(( (age_seconds % 3600) / 60 ))m"
        elif [[ $age_seconds -gt 60 ]]; then
            age_human="$(( age_seconds / 60 ))m $(( age_seconds % 60 ))s"
        fi
        issues+=("LOG_STALE: Last log entry was ${age_human} ago (process may be deadlocked)")
    fi

    # 3. Parse last 200 lines for anomalies
    tail_lines=$(tail -200 "$LOG")

    # Check for deadlock warnings
    deadlock_count=$(echo "$tail_lines" | grep -c "WARNING:.*did not complete" || true)
    if [[ $deadlock_count -gt 0 ]]; then
        issues+=("DEADLOCK_WARNING: $deadlock_count deadlock warning(s) in recent log")
    fi

    # Check for signal-flat events. Silent-recovery ends most of them within seconds, so a
    # flat episode is an issue only while it is still open or after recovery gave up.
    flat_count=$(echo "$tail_lines" | grep -c "SIGNAL FLAT" || true)
    last_flat=$(echo "$tail_lines" | grep -n "SIGNAL FLAT" | tail -1 | cut -d: -f1 || true)
    last_restored=$(echo "$tail_lines" | grep -n "\[silent-recovery\] Audio restored\|Silent streak ended" | tail -1 | cut -d: -f1 || true)
    if [[ -n "$last_flat" && ( -z "$last_restored" || $last_restored -lt $last_flat ) ]]; then
        issues+=("SIGNAL_FLAT: signal is flat and has not recovered ($flat_count flat heartbeat(s) in recent log)")
    elif [[ $flat_count -gt 0 ]]; then
        warnings+=("SIGNAL_FLAT_RECOVERED: $flat_count flat heartbeat(s) in recent log, since recovered")
    fi

    restored_count=$(echo "$tail_lines" | grep -c "\[silent-recovery\] Audio restored" || true)
    if [[ $restored_count -gt 0 ]]; then
        warnings+=("SILENT_RECOVERY: $restored_count flat episode(s) ended in recent log")
    fi
    cap_count=$(echo "$tail_lines" | grep -c "\[silent-recovery\] Attempt cap reached" || true)
    if [[ $cap_count -gt 0 ]]; then
        warnings+=("RECOVERY_CAP: silent-recovery hit its attempt cap $cap_count time(s); the Bluetooth link may be held by another device")
    fi

    # Check for silent streaks
    silent_count=$(echo "$tail_lines" | grep -c "Silent streak ended" || true)
    if [[ $silent_count -gt 0 ]]; then
        warnings+=("SILENT_STREAKS: $silent_count silent streak(s) ended in recent log")
    fi

    # Check for zero-sample heartbeats
    zero_count=$(echo "$tail_lines" | grep -c "ZERO SAMPLES\|NO NEW SAMPLES" || true)
    if [[ $zero_count -gt 0 ]]; then
        warnings+=("SAMPLE_GAPS: $zero_count zero/no-sample heartbeat(s) in recent log")
    fi

    # Check for auto-recovery events
    recovery_count=$(echo "$tail_lines" | grep -c "AUTO-RECOVERY" || true)
    if [[ $recovery_count -gt 0 ]]; then
        warnings+=("AUTO_RECOVERY: $recovery_count auto-recovery event(s) in recent log")
    fi

    # Check for dropped frames
    drop_count=$(echo "$tail_lines" | grep -c "DROPPED FRAME" || true)
    if [[ $drop_count -gt 0 ]]; then
        warnings+=("DROPPED_FRAMES: $drop_count dropped frame(s) in recent log")
    fi

    # Get current session info from last heartbeat
    last_heartbeat=$(echo "$tail_lines" | grep "heartbeat:" | tail -1 || true)
    last_line=$(tail -1 "$LOG")
fi

# Escape a string for a JSON string literal.
json_str() {
    # Drop control characters JSON cannot carry raw (tab, LF and CR are escaped below).
    local s
    s=$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    s=${s//$'\n'/\\n}
    printf '"%s"' "$s"
}

# Output
if $JSON_MODE; then
    echo "{"
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"pid\": ${PID:-null},"
    echo "  \"log_age_seconds\": ${age_seconds:-null},"
    echo "  \"status\": \"$([ ${#issues[@]} -eq 0 ] && echo 'healthy' || echo 'unhealthy')\","
    echo "  \"issues\": ["
    for i in "${!issues[@]}"; do
        echo "    $(json_str "${issues[$i]}")$([ $i -lt $((${#issues[@]}-1)) ] && echo ',')"
    done
    echo "  ],"
    echo "  \"warnings\": ["
    for i in "${!warnings[@]}"; do
        echo "    $(json_str "${warnings[$i]}")$([ $i -lt $((${#warnings[@]}-1)) ] && echo ',')"
    done
    echo "  ],"
    echo "  \"log_path\": $(json_str "$LOG"),"
    echo "  \"last_heartbeat\": $(json_str "${last_heartbeat:-none}"),"
    echo "  \"last_log_line\": $(json_str "${last_line:-none}")"
    echo "}"
else
    echo "=== mic-warm health check ($(date)) ==="
    echo ""
    if [[ -n "${PID:-}" ]]; then
        echo "Process: running (PID $PID)"
    else
        echo "Process: NOT RUNNING"
    fi
    echo "Log: $LOG (age ${age_seconds:-?}s)"
    echo ""

    if [[ ${#issues[@]} -gt 0 ]]; then
        echo "ISSUES:"
        for issue in "${issues[@]}"; do echo "  [!] $issue"; done
        echo ""
    fi

    if [[ ${#warnings[@]} -gt 0 ]]; then
        echo "WARNINGS:"
        for w in "${warnings[@]}"; do echo "  [~] $w"; done
        echo ""
    fi

    if [[ ${#issues[@]} -eq 0 && ${#warnings[@]} -eq 0 ]]; then
        echo "Status: HEALTHY"
    elif [[ ${#issues[@]} -eq 0 ]]; then
        echo "Status: OK (with warnings)"
    else
        echo "Status: UNHEALTHY"
    fi

    if [[ -n "${last_heartbeat:-}" ]]; then
        echo ""
        echo "Last heartbeat: $last_heartbeat"
    fi
fi

# Exit code
if [[ -z "${PID:-}" ]]; then
    exit 2
elif [[ ${#issues[@]} -gt 0 ]]; then
    exit 1
else
    exit 0
fi
