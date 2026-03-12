# mic-warm Findings Bible

A cumulative reference of everything discovered about CoreAudio, AVCaptureSession, Bluetooth audio, and macOS behavior through debugging mic-warm. This document grows over time. Each finding includes evidence quality so we know what's proven vs. speculative.

---

## Evidence Ratings

- **VERIFIED**: Reproduced reliably, root cause confirmed
- **OBSERVED**: Seen in logs/thread dumps, root cause understood but not reproduced on demand
- **INFERRED**: Deduced from symptoms and known architecture, not directly observed
- **EXTERNAL**: Reported by Apple, other developers, or web research

---

## 1. CoreAudio Architecture

### 1.1 The CAGuard Deadlock Pattern
**Rating: VERIFIED**

CoreAudio's HAL uses CAGuard (pthread_mutex + pthread_cond) for internal synchronization. `AudioObjectRemovePropertyListener` is synchronous: it waits for any in-flight listener callbacks to complete before returning. If a listener callback needs `dispatch_sync` to the same thread that called `RemovePropertyListener`, deadlock is guaranteed.

```
Thread A (main): RemovePropertyListener -> CAGuard::Lock -> WaitFor(callback completion)
Thread B (CoreAudio): callback -> dispatch_sync(main) -> blocked (main is in WaitFor)
```

**Evidence:** Thread dumps from PID 804 (2026-03-02) and PID 782 (2026-03-11) both show this exact pattern. Chromium and WebKit have documented identical deadlocks.

**Implication:** Never call AudioObjectRemovePropertyListener (or any API that triggers it, like AVCaptureSession.removeOutput) from the main thread.

### 1.2 AudioObjectAddPropertyListenerBlock Stacks Without Limit
**Rating: VERIFIED**

Calling `AudioObjectAddPropertyListenerBlock` multiple times for the same property on the same device ID adds multiple listeners. CoreAudio does not deduplicate. Each fires independently on property changes.

**Evidence:** After 6 calls to `installPerDeviceListeners()`, log showed 6x duplicate "[device] isRunningSomewhere changed" entries per event.

**Implication:** Must track and remove old listeners before adding new ones, or guard with a flag to prevent re-installation.

### 1.3 Per-Device Listeners Fire on CoreAudio Internal Threads
**Rating: EXTERNAL**

Apple's TN2091 states property listener procs "may be called from any thread." In practice, when using `AudioObjectAddPropertyListenerBlock` with a dispatch queue, they fire on that queue. But the removal path (`AudioObjectRemovePropertyListenerBlock`) still involves CAGuard synchronization with whatever thread the HAL is using internally.

**Evidence:** Apple documentation (TN2091), Chromium source code comments.

### 1.4 coreaudiod Can Enter Corrupted State
**Rating: EXTERNAL**

The `coreaudiod` daemon manages all audio routing on macOS. It can enter states where:
- Devices report as alive/running but deliver no audio data
- Bluetooth device transitions hang indefinitely
- The daemon accumulates memory without releasing it

`sudo killall coreaudiod` restarts the daemon automatically (launchd respawns it). This clears corrupted state.

**Evidence:** Widely reported on Apple Developer Forums, Stack Overflow, and macOS troubleshooting guides. Our 118-session zero-sample run on built-in mic (2026-03-10/11) is consistent with this.

---

## 2. AVCaptureSession Behavior

### 2.1 CMIO Graph Deadlock During Bluetooth Teardown
**Rating: OBSERVED (1x production-equivalent, verified via thread dump)**

When tearing down an AVCaptureSession on the main thread during a Bluetooth device transition:
1. `removeOutput()` calls into CMIOGraphStop
2. CMIOGraphStop calls AudioObjectRemovePropertyListener
3. AudioObjectRemovePropertyListener acquires CAGuard and waits for in-flight callbacks
4. A CoreAudio callback needs dispatch_sync(main) to deliver a property notification
5. Main thread is blocked in WaitFor, deadlock.

**Evidence:** Thread dump of PID 804 (2026-03-02), frozen for 3 days. Exact call stack: `removeOutput` -> `CMIOGraphStop` -> `AudioObjectRemovePropertyListener` -> `CAGuard::WaitFor`.

**Fix applied:** Moved removeOutput/removeInput/stopRunning to `DispatchQueue.global(qos: .utility).async` in commit `bf504cc`.

**Side effect:** This fix likely caused the 118-session zero-sample spiral (Finding 2.3) because the old session's CMIO graph stays active while the new session opens the same device.

**Status:** Fix needs modification. Old session teardown should complete (or time out) before new session opens.

### 2.2 AVFoundation Internal DeviceIsAliveListener Deadlock
**Rating: OBSERVED (1x, verified via thread dump)**

AVFoundation's own code (`AVFCapture.framework`) has a latent deadlock in its `_DeviceIsAliveListener` handler. When a Bluetooth device's `isAlive` property changes to 0:
1. AVFoundation's listener fires on a CoreAudio thread
2. It calls `_refreshConnectionID` -> `_removePropertyListeners`
3. `_removePropertyListeners` calls `AudioObjectRemovePropertyListener`
4. This triggers the same CAGuard deadlock as Finding 2.1

**Evidence:** Thread dump of PID 782 (2026-03-11). Call stack inside `AVFCapture` framework, not our code. Main thread stuck in `__DeviceIsAliveListener_block_invoke`.

**Implication:** We cannot fix this. It's an Apple framework bug. Moving our code off main thread reduces (but doesn't eliminate) exposure, because AVFoundation's internal callback may still target main.

### 2.3 Zero-Sample Delivery After Bluetooth Transition
**Rating: OBSERVED (118 consecutive sessions, 2026-03-10/11)**

After an AirPods connection, the built-in mic entered a state where AVCaptureSession reported `isRunning=true` but delivered zero audio buffers. This persisted across 118 automatic session restarts over ~18 hours. Connecting AirPods (a different device) immediately resolved it.

**Evidence:** Log analysis of `/tmp/mic-warm.log`, sessions 2-119. Each session: `startRunning()` succeeds, `isRunning=true`, zero samples for 30s, auto-recovery triggers restart.

**Probable cause (INFERRED):** The background teardown of the old session (Finding 2.1 fix) leaves the CMIO graph partially active. The new session tries to open the same built-in mic device, but CMIO sees it as still in use by the old session. The new session starts "successfully" but no audio data flows through the disconnected CMIO graph.

**Supporting evidence:** Connecting a different device (AirPods) forces CMIO to build a completely new graph, bypassing the corrupted built-in mic node.

### 2.4 Session Running on Main Queue Is a Liability
**Rating: EXTERNAL (Apple documentation)**

Apple's AVCaptureSession documentation states: "The startRunning() method is a blocking call which can take some time, therefore you should perform session setup on a serial queue so that the main queue isn't blocked."

This applies to all session mutation methods: startRunning, stopRunning, addInput, removeInput, addOutput, removeOutput, beginConfiguration, commitConfiguration.

**Evidence:** Apple developer documentation for AVCaptureSession.

**Current state in mic-warm:** All session operations run on main thread. Sample buffer delegate also dispatches to main.

### 2.5 Sample Buffer Delegate on Main Can Starve
**Rating: INFERRED**

In a headless LaunchAgent (no AppKit event loop), the main RunLoop is only pumped by `dispatchMain()`. If the main thread blocks for any reason (CoreAudio notification, session teardown, KVO callback), sample buffer delivery pauses. In the worst case, CoreAudio's internal buffers fill up and frames are dropped.

**Evidence:** We have observed DROPPED FRAME events in logs, though not correlated with specific main-thread blocks. The architecture makes this theoretically certain.

---

## 3. Bluetooth / AirPods Behavior

### 3.1 AirPods isRunningSomewhere Toggles Constantly
**Rating: VERIFIED**

AirPods Pro's `isRunningSomewhere` property toggles between 0 and 1 every 10-30 seconds during normal use. This is AirPods power management cycling the audio hardware on/off. It does NOT indicate a problem and should NOT trigger session restarts.

**Evidence:** Continuous observation in `/tmp/mic-warm.log` across multiple sessions. The pattern is consistent and does not correlate with audio issues.

### 3.2 Bluetooth Connection Flapping
**Rating: VERIFIED**

AirPods can rapidly alternate between connected/disconnected states, causing the default input device to flap between AirPods and built-in mic. In one log analysis: 311 device events, 17 flap bursts.

**Evidence:** Log analysis from 2026-03-01, 695 sessions, 7600+ lines.

**Mitigation:** 3-second debounce on device change events (already implemented).

### 3.3 SCO/A2DP Codec Switching Looks Like a Disconnect
**Rating: EXTERNAL**

When a phone call starts or another app requests microphone access, AirPods switch from A2DP (high quality audio) to SCO (telephony) codec. This causes a brief device reconfiguration that triggers `isAlive`, `isRunning`, `sampleRate`, and `streamConfiguration` change notifications. It can look like a disconnect/reconnect in logs.

**Evidence:** Apple Developer Forums, Bluetooth audio documentation.

---

## 4. macOS Tahoe (26) Issues

### 4.1 Widespread CoreAudio Regressions
**Rating: EXTERNAL**

macOS Tahoe (26) has known, widespread audio issues that Apple has acknowledged:
- Audio crackling and drops
- Audio quality degradation over time
- AirPods disconnecting/reconnecting in loops
- coreaudiod hangs during Bluetooth transitions
- mediaserviced crashes on Bluetooth disconnect/reconnect

Apple is developing an OS-level patch.

**Evidence:** Multiple Apple Developer Forum threads, user reports on MacRumors, Apple support communities. Apple has acknowledged the issues.

**Implication:** The original "signal goes flat after 3-4 seconds on AirPods" complaint may be a Tahoe regression, not a mic-warm bug. The OS-level patch may resolve it without any changes on our end.

### 4.2 AVCaptureSession Zero-Buffer Values on Sequoia+
**Rating: EXTERNAL**

Reports exist of AVCaptureSession delivering audio buffers with zero values (not empty buffers, but buffers filled with silence) on macOS Sequoia and later. This matches our "signal goes flat" symptom description.

**Evidence:** Apple Developer Forums posts from late 2025.

---

## 5. Debug Build Findings

### 5.1 KVO on AVCaptureSession.isRunning Is Dangerous During Teardown
**Rating: VERIFIED (2/2 reproductions)**

Adding a KVO observer on AVCaptureSession's `running` property and calling `logAllDevices()` inside `observeValue` causes a three-way deadlock during AirPods teardown:
1. `removeObserver` on main thread waits for in-flight KVO delivery
2. KVO handler calls `logAllDevices()` which queries CoreAudio properties
3. CoreAudio has callbacks queued for the main thread

**Evidence:** 100% reproduction rate (2/2) on AirPods transition. Fixed in commit `812212b`.

**Note:** This was a debug-build-only bug. Master has KVO `#if false`'d out. The debug build enabled it for monitoring.

### 5.2 Debug Build Widens Deadlock Timing Window
**Rating: INFERRED**

The additional CoreAudio property listeners in the debug build (8 listener types per device, vs. 0 in master) increase the number of concurrent callbacks during device transitions. This widens the timing window for deadlocks.

**Evidence:** The CMIO deadlock (Finding 2.1) was observed on the debug build's first AirPods transition but was never observed in 694 production sessions. The underlying code path exists in master, but the debug build's extra listeners make it more likely to hit the timing window.

### 5.3 Debug Build Memory Leak
**Rating: OBSERVED**

After 123 sessions, the debug build's physical memory footprint was 268.4MB. This is caused by:
- Per-device listener accumulation (Finding 1.2): each restart adds ~8 listeners per device without removing old ones
- AVCaptureSession objects retained by background teardown closures

**Evidence:** Thread dump of PID 782 showing 268.4MB physical footprint.

---

## 6. Recovery Strategies

### 6.1 Killing coreaudiod Clears Corrupted State
**Rating: EXTERNAL**

`sudo killall coreaudiod` causes launchd to automatically restart the daemon, clearing any corrupted internal state. All audio apps reconnect automatically.

**Caveat:** Requires root privileges. A LaunchAgent running as the user cannot `killall coreaudiod` without a privileged helper or sudoers entry.

### 6.2 Connecting a Different Device Bypasses CMIO Corruption
**Rating: OBSERVED**

When the built-in mic was stuck in zero-sample state (Finding 2.3), connecting AirPods immediately resolved it. The new device forces CMIO to build a new graph node, bypassing the corrupted state.

**Evidence:** Session 120 in the 2026-03-10/11 log: AirPods connected, samples flowing immediately.

### 6.3 Session Auto-Recovery via Restart
**Rating: VERIFIED**

The heartbeat-based auto-recovery (restart session after 15s of no new samples, or 30s of zero samples) successfully detects stuck sessions. However, restarting the session on the same device does NOT fix CMIO-level corruption (Finding 2.3).

**Evidence:** 118 consecutive auto-recovery restarts all failed on the same device.

---

## Appendix: Thread Dump Signatures

### CMIO Graph Deadlock (PID 804, 2026-03-02)
```
Main thread:
  removeOutput -> CMIOGraphStop -> AudioObjectRemovePropertyListener -> CAGuard::WaitFor

CoreAudio thread:
  HALDevice::Teardown -> PropertiesChanged -> dispatch_sync(main) [BLOCKED]
```

### AVFoundation Internal Deadlock (PID 782, 2026-03-11)
```
Main thread:
  __DeviceIsAliveListener_block_invoke -> _refreshConnectionID ->
  _removePropertyListeners -> AudioObjectRemovePropertyListener -> CAGuard::WaitFor

CoreAudio thread:
  [delivering property change notification] -> dispatch_sync(main) [BLOCKED]
```

---

*Last updated: 2026-03-12*
*Branch: debug-logging (commit 6ab6b51)*
