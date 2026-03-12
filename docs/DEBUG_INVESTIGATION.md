# mic-warm Debug Investigation

## Branch: `debug-logging`

## The Problem

When using AirPods Pro, the transcription app (SuperWhisper/WhisperFlow) picks up the mic quickly but the signal goes flat after 3-4 seconds. This does not happen with the built-in MacBook Air microphone.

## Status: Unresolved

The original "signal goes flat" bug has **never been captured** in debug logs. The debug build has been deployed but spent most of its runtime either deadlocked or not running due to bugs in the instrumentation itself. As of 2026-03-05, the debug build is running with both deadlock fixes applied and new silent-sample detection added.

## Timeline

### 2026-03-01: Initial investigation

- Analyzed `/tmp/mic-warm.log` from production build (7600+ lines, 695 sessions)
- Found Bluetooth connection flapping: 311 device events, 17 flap bursts (rapid alternation between AirPods and built-in mic)
- Found 469 zero-sample sessions vs 109 successful on MacBook Air Microphone
- User reported the issue self-resolved after switching to built-in mic and back to AirPods
- Decision: deploy a debug build with instrumented logging, no behavior changes

### 2026-03-01: Debug build deployed (`a1cb4cc`)

Changes from master (all logging-only, no behavior changes):
- Enabled startup device snapshot
- Enabled per-device CoreAudio property listeners (isAlive, isRunning, isRunningSomewhere, volume)
- Enabled KVO observer on `AVCaptureSession.isRunning`
- Enabled session lifecycle notifications (start, stop, interrupt, error)
- Enabled detailed heartbeat logging with CoreAudio device state
- Enabled first-sample/10th-sample latency logging
- Enabled dropped-frame logging
- Version bumped to `0.9.2-debug`

### 2026-03-01: KVO deadlock discovered and fixed (`812212b`)

- Debug build deadlocked on its first AirPods transition (100% repro, 2/2)
- Root cause: `logAllDevices()` inside KVO `observeValue` handler
- Deadlock path: `removeObserver` (main) waits for in-flight KVO, KVO calls `logAllDevices` which queries CoreAudio, CoreAudio has callbacks queued for main thread
- Fix: removed `logAllDevices()` from KVO handler
- **This bug was introduced by the debug build.** Master has KVO `#if false`'d out.
- **Verified and repeatable:** 2/2 occurrences on AirPods transitions

### 2026-03-02: CMIO graph deadlock discovered

- Process started Mon Mar 2 09:49, ran fine on built-in mic for 19 minutes
- At 10:08:47, AirPods connected. Default input changed to AirPods.
- At 10:08:50, debounce fired, `startSession()` began tearing down old session
- Process froze at `removeOutput()` and never recovered
- Process remained frozen for 3 days until discovered on Mar 5

### 2026-03-05: CMIO deadlock diagnosed via thread dump and fixed (`bf504cc`)

- `sample` command on PID 804 revealed the exact deadlock:
  - Main thread: `removeOutput` -> `CMIOGraphStop` -> `AudioObjectRemovePropertyListener` -> `CAGuard::WaitFor()`
  - CoreAudio thread: `HALDevice::Teardown` -> `PropertiesChanged` -> `dispatch_sync(main)` (blocked)
- Fix: moved `removeOutput`/`removeInput`/`stopRunning` entirely to background thread
- **This bug exists in master too.** The `removeOutput` on main thread code is identical. The debug build's additional CoreAudio listeners may widen the timing window, but the fundamental race condition is latent in production.
- **Observed once, not repeated.** Production had 0/694 observed deadlocks, but most teardowns were built-in mic (no concurrent Bluetooth transition).

### 2026-03-05: Silent-sample detection added

- Identified critical gap: the debug build detects when samples STOP but not when samples arrive as SILENCE (all-zero buffers)
- "Signal goes flat" most likely means audio buffers flowing but empty
- Added: per-buffer silence check, silent streak tracking, `SIGNAL FLAT` heartbeat alert
- Added: `scripts/check-health.sh` for automated health monitoring

## What We're Observing Now

| Signal | Detection | Log marker |
|--------|-----------|------------|
| Samples stop entirely | Heartbeat (5s) | `NO NEW SAMPLES` |
| Samples arrive as silence | Per-buffer check | `SIGNAL FLAT` / `Silent streak ended` |
| Session stops unexpectedly | KVO + notification | `SESSION STOPPED` |
| Session interrupted by OS | Notification | `AVCaptureSessionWasInterrupted` |
| Device disconnects | CoreAudio listener | `isAlive changed` |
| Device stops running | CoreAudio listener | `isRunning changed` |
| Default input changes | CoreAudio listener | `Default input device changed` |
| Device list changes | CoreAudio listener | `Device list changed` |
| Dropped audio frames | Delegate callback | `DROPPED FRAME` |
| Teardown hangs | 10s watchdog | `WARNING: session teardown did not complete` |
| Auto-recovery triggered | Heartbeat logic | `AUTO-RECOVERY` |

## Monitoring

Run the health check:
```bash
./scripts/check-health.sh          # human-readable
./scripts/check-health.sh --json   # for automation
```

Key things to look for in `/tmp/mic-warm.log`:
```bash
# Signal flat events (the original bug)
grep "SIGNAL FLAT\|Silent streak" /tmp/mic-warm.log

# Any anomalies
grep "\*\*\*" /tmp/mic-warm.log

# Session transitions (look for patterns around AirPods)
grep "Device event\|Debounce\|Stopping old\|Opening device\|First sample" /tmp/mic-warm.log
```

## Commits on `debug-logging`

1. `a1cb4cc` - Enable instrumented debug logging for AirPods audio investigation
2. `812212b` - Fix KVO deadlock in debug build during AirPods teardown
3. `bf504cc` - Fix CMIO graph deadlock during Bluetooth device transitions
4. (pending) - Add silent-sample detection and health check script

## What Needs to Happen Next

1. **Wait for reproduction.** The debug build needs to run undisturbed through several AirPods connect/disconnect cycles to capture the original "signal goes flat" event.
2. **Review findings.** When `SIGNAL FLAT` or other anomalies appear, analyze the surrounding log context.
3. **Decide on master merge.** The CMIO deadlock fix (`bf504cc`) should probably go to master since the bug exists there too, but it's only been observed once.
