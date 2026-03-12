#!/bin/bash
# check-health.sh - Health check for mic-warm debug build
# Outputs structured findings for human or automated review.
# Exit codes: 0 = healthy, 1 = issues found, 2 = not running
#
# Usage:
#   ./scripts/check-health.sh              # Human-readable summary
#   ./scripts/check-health.sh --json       # JSON output for automation

set -euo pipefail

LOG="/tmp/mic-warm.log"
JSON_MODE=false
[[ "${1:-}" == "--json" ]] && JSON_MODE=true

issues=()
warnings=()

# 1. Is the process running?
PID=$(pgrep -f "mic-warm$" || true)
if [[ -z "$PID" ]]; then
    issues+=("PROCESS_NOT_RUNNING: mic-warm is not running")
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

    # Check for signal-flat events
    flat_count=$(echo "$tail_lines" | grep -c "SIGNAL FLAT" || true)
    if [[ $flat_count -gt 0 ]]; then
        issues+=("SIGNAL_FLAT: $flat_count 'signal flat' event(s) in recent log - original bug may be reproducing")
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

# Output
if $JSON_MODE; then
    echo "{"
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"pid\": ${PID:-null},"
    echo "  \"log_age_seconds\": ${age_seconds:-null},"
    echo "  \"status\": \"$([ ${#issues[@]} -eq 0 ] && echo 'healthy' || echo 'unhealthy')\","
    echo "  \"issues\": ["
    for i in "${!issues[@]}"; do
        echo "    \"${issues[$i]}\"$([ $i -lt $((${#issues[@]}-1)) ] && echo ',')"
    done
    echo "  ],"
    echo "  \"warnings\": ["
    for i in "${!warnings[@]}"; do
        echo "    \"${warnings[$i]}\"$([ $i -lt $((${#warnings[@]}-1)) ] && echo ',')"
    done
    echo "  ],"
    echo "  \"last_heartbeat\": \"${last_heartbeat:-none}\","
    echo "  \"last_log_line\": \"${last_line:-none}\""
    echo "}"
else
    echo "=== mic-warm health check ($(date)) ==="
    echo ""
    if [[ -n "${PID:-}" ]]; then
        echo "Process: running (PID $PID)"
    else
        echo "Process: NOT RUNNING"
    fi
    echo "Log age: ${age_seconds:-?}s"
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
