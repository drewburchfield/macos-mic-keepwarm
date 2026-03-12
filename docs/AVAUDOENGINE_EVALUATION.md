# AVAudioEngine Evaluation for mic-warm

## Purpose

Evaluate replacing AVCaptureSession with AVAudioEngine as the core audio capture mechanism in mic-warm. The goal is to reduce deadlock exposure and improve reliability during Bluetooth device transitions.

## Why Consider AVAudioEngine?

mic-warm currently uses AVCaptureSession + AVCaptureAudioDataOutput to hold the microphone open. This works but routes through Apple's CMIO (CoreMediaIO) DAL (Device Abstraction Layer), which introduces:

1. **CMIO graph deadlocks** during session teardown (CMIOGraphStop calls AudioObjectRemovePropertyListener, which can deadlock with CoreAudio's main-thread dispatch_sync)
2. **Zero-sample delivery** when the CMIO graph enters a corrupted state after Bluetooth transitions
3. **AVFoundation internal deadlocks** in DeviceIsAliveListener that we cannot fix (Apple framework bug)

AVAudioEngine bypasses CMIO entirely. It talks directly to the CoreAudio HAL, removing an entire layer of deadlock-prone synchronization.

## Architecture Comparison

### Current: AVCaptureSession Path
```
mic-warm (main thread)
  -> AVCaptureSession
    -> AVCaptureDeviceInput
      -> CMIO DAL Plugin (CoreMediaIO)
        -> CoreAudio HAL
          -> Audio hardware driver
```

### Proposed: AVAudioEngine Path
```
mic-warm (any thread)
  -> AVAudioEngine
    -> AVAudioInputNode (installTap)
      -> CoreAudio HAL (direct)
        -> Audio hardware driver
```

Key difference: AVAudioEngine skips CMIO. The input tap runs on CoreAudio's internal real-time audio thread, fully decoupled from the main thread.

## API Comparison

### Holding the Mic Open

**AVCaptureSession (current):**
```swift
let session = AVCaptureSession()
let device = AVCaptureDevice.default(for: .audio)!
let input = try AVCaptureDeviceInput(device: device)
session.addInput(input)
let output = AVCaptureAudioDataOutput()
output.setSampleBufferDelegate(self, queue: someQueue)
session.addOutput(output)
session.startRunning()
```

**AVAudioEngine (proposed):**
```swift
let engine = AVAudioEngine()
let inputNode = engine.inputNode  // auto-connects to default input
let format = inputNode.outputFormat(forBus: 0)
inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
    // Audio data arrives here on a real-time thread
}
try engine.start()
```

The AVAudioEngine version is simpler. No device input/output management, no session configuration.

### Device Switching

**AVCaptureSession:** Must tear down entire session (removeInput, removeOutput, stopRunning), create new session, add new device. This is where CMIO deadlocks happen.

**AVAudioEngine:** On macOS, `engine.inputNode` automatically reflects the current default input device. When the system default changes, CoreAudio re-routes internally. However, for explicit device selection, you need to set the device on the underlying AudioUnit:

```swift
let inputNode = engine.inputNode
var deviceID: AudioDeviceID = targetDeviceID
AudioUnitSetProperty(
    inputNode.audioUnit!,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global, 0,
    &deviceID,
    UInt32(MemoryLayout<AudioDeviceID>.size)
)
```

**Important caveat:** Changing the device on a running AVAudioEngine may require stop/start. The engine does not always handle hot-swapping gracefully. But the stop/start cycle is much lighter than AVCaptureSession because there's no CMIO graph to tear down.

### Detecting Silence / Signal Flat

**AVCaptureSession:** We check CMSampleBuffer data via CMBlockBufferGetDataPointer, comparing bytes to zero.

**AVAudioEngine:** The tap callback provides AVAudioPCMBuffer, which has typed float arrays:

```swift
inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
    guard let channelData = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameLength)
    var maxAmplitude: Float = 0
    for i in 0..<frames {
        maxAmplitude = max(maxAmplitude, abs(channelData[0][i]))
    }
    let isSilent = maxAmplitude < 1e-6  // effectively zero
}
```

This is cleaner than the CMBlockBuffer approach and gives us actual amplitude values instead of raw byte comparison.

### Error Recovery

**AVCaptureSession:** Notifications (AVCaptureSessionRuntimeError, AVCaptureSessionWasInterrupted). Recovery requires full session rebuild.

**AVAudioEngine:** The engine posts `.AVAudioEngineConfigurationChange` when the audio graph needs to be reconfigured (e.g., device disconnected, sample rate changed). Recovery pattern:

```swift
NotificationCenter.default.addObserver(
    forName: .AVAudioEngineConfigurationChange,
    object: engine, queue: nil
) { _ in
    // Engine has already stopped. Reinstall tap and restart.
    engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: newFormat) { ... }
    try? engine.start()
}
```

This is simpler than AVCaptureSession's teardown/rebuild cycle and doesn't involve CMIO.

## Risk Assessment

### What Gets Better

| Problem | AVCaptureSession | AVAudioEngine |
|---------|-----------------|---------------|
| CMIO graph deadlock during teardown | **Observed, fixed with workaround** | **Eliminated** (no CMIO) |
| AVFoundation DeviceIsAliveListener deadlock | **Observed, unfixable** | **Eliminated** (no AVFoundation capture layer) |
| Zero-sample CMIO graph corruption | **Observed (118 sessions)** | **Eliminated** (no CMIO graph) |
| Main thread sensitivity | **High** (all callbacks on main) | **Low** (tap runs on RT thread) |
| Per-device listener accumulation | Our bug, fixable either way | Same |
| Memory footprint per session | Higher (CMIO + AVFoundation overhead) | Lower |

### What Stays the Same

| Problem | Notes |
|---------|-------|
| CoreAudio HAL-level issues | Both frameworks use CoreAudio HAL underneath |
| coreaudiod corruption | If coreaudiod is in a bad state, both fail |
| macOS Tahoe audio regressions | OS-level, affects all audio APIs |
| Bluetooth SCO/A2DP codec switching | Hardware/driver level, not framework level |
| TCC microphone permissions | Same permission model for both |

### What Could Get Worse

| Risk | Severity | Mitigation |
|------|----------|------------|
| AVAudioEngine device hot-swap is less automatic than AVCaptureSession | Medium | Monitor `.AVAudioEngineConfigurationChange`, restart engine on device change |
| AVAudioEngine has no equivalent of AVCaptureDevice.default(for:) for auto-selecting default input | Low | Use AudioObjectGetPropertyData for kAudioHardwarePropertyDefaultInputDevice |
| Less community knowledge for mic-holding use case | Low | The API is well-documented; our use case is simple |
| Format negotiation can fail if device reports unusual formats | Low | Fall back to device's native format |
| installTap can throw if format is incompatible | Low | Catch and retry with device's output format |

## Migration Effort

### Scope
- Single file change (main.swift, ~670 lines)
- Core capture logic is ~150 lines that would be rewritten
- Listener infrastructure (CoreAudio property listeners, notifications) stays identical
- Heartbeat, logging, PID management, signal handling all unchanged
- Silent-sample detection logic changes from CMBlockBuffer to AVAudioPCMBuffer (simpler)

### Estimated Complexity
- **Lines changed:** ~150-200 (out of ~670)
- **New concepts:** AVAudioEngine lifecycle, installTap/removeTap, AVAudioPCMBuffer
- **Removed concepts:** AVCaptureSession, AVCaptureDeviceInput, AVCaptureAudioDataOutput, CMSampleBuffer, CMIO
- **Testing needed:** Built-in mic, AirPods connect/disconnect, AirPods case open/close, sleep/wake, device switching while active

### What Stays
- All CoreAudio helper functions (getAudioProperty, describeDevice, etc.)
- System-level listeners (default device change, device list change)
- Per-device listeners (with cleanup fix)
- Heartbeat logic
- Debounced restart logic
- PID management
- Signal handling
- Logging infrastructure

## Recommendation

**Do not migrate yet.** The P0/P1 fixes to the current AVCaptureSession code address the immediate deadlocks and zero-sample issues without a rewrite. Specifically:

1. Moving to dedicated queues (P0) eliminates the main-thread deadlock vector
2. Fixing listener cleanup (P1) reduces deadlock window and memory leak
3. Adding coreaudiod recovery (P1) handles the zero-sample corruption case

If these fixes resolve the issues, AVAudioEngine migration is unnecessary. If problems persist after the fixes AND after Apple's Tahoe audio patch, then AVAudioEngine becomes the right next step.

### Migration Trigger Criteria
Migrate to AVAudioEngine if, after P0/P1 fixes:
- CMIO deadlocks still occur (indicating the dedicated queue doesn't fully prevent them)
- Zero-sample delivery persists across device transitions
- AVFoundation internal deadlocks continue to freeze the process

### If We Do Migrate
1. Build on a separate branch (e.g., `avaudoengine-eval`)
2. Run side-by-side with current build for at least 1 week
3. Test all Bluetooth transition scenarios
4. Merge to master only after equivalent or better reliability is confirmed
