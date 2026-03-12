# CoreAudio Deadlock & Zero-Sample Research for mic-warm

## Query
Research and debug macOS mic-warm tool issues: (1) AVCaptureSession + CoreAudio deadlocks on Apple Silicon when Bluetooth devices connect/disconnect - AudioObjectRemovePropertyListener blocks on CAGuard::WaitFor while CoreAudio needs dispatch_sync to main queue, (2) AVCaptureSession reports sessionRunning=true but delivers zero audio samples on built-in mic after Bluetooth transition, (3) AVFoundation's internal DeviceIsAliveListener deadlocking on property listener cleanup. We need to understand known issues with these primitives on macOS 26 (Tahoe) and Apple Silicon.

## Gemini
Model unavailable (empty output, command failed)

## Codex
Partial result only. Found Apple documentation for queueing and route-change behavior, plus Apple forum threads showing Tahoe-era AVFoundation audio regressions. Did not complete full analysis before timeout.

## Claude (Opus subagent)
Comprehensive analysis covering 7 areas:

### Known Issues
- CAGuard/pthread_cond_wait deadlock during AudioObjectRemovePropertyListener is a long-standing architectural issue, not new to Tahoe
- Apple Silicon CMIO DAL has heavier cross-thread synchronization than Intel path, making deadlocks more likely
- AVFoundation's own DeviceIsAliveListener has a latent deadlock bug (Apple's code calling RemovePropertyListener from main thread)
- Chromium and WebKit both documented and worked around this exact pattern

### Key Recommendations
1. Move ALL AVCaptureSession operations off the main thread to a dedicated serial queue
2. Move sample buffer delegate to a non-main queue (currently on .main)
3. Issue 2 (AVFoundation internal deadlock) cannot be fixed from user code
4. Zero-sample issue is likely CMIO graph corruption; test `killall coreaudiod` as diagnostic
5. Consider migrating to AVAudioEngine to bypass CMIO layer entirely
6. Debounce Bluetooth device transitions

### AVAudioEngine as Alternative
- Bypasses CMIO entirely, uses CoreAudio HAL directly
- Less susceptible to CMIO graph deadlocks
- Input tap runs on internal real-time audio thread, decoupled from main
- Still subject to HAL-level issues if coreaudiod is corrupted

### Comparison Table
| Feature | AVCaptureSession | AVAudioEngine | AudioQueue | HAL Direct |
|---|---|---|---|---|
| CMIO involvement | Yes | No | No | No |
| Main thread sensitivity | High | Low | Low | Low |
| Deadlock risk | Highest | Low | Low | Lowest |

## Web Research Findings
- macOS Tahoe has KNOWN widespread CoreAudio issues (Apple acknowledged, patch in development)
- Bluetooth coreaudiod hangs reported since 2014
- mediaserviced crashes on Bluetooth disconnect/reconnect
- AVCaptureSession zero-sample issue observed on macOS Sequoia+
- Workaround: `sudo killall coreaudiod` restarts audio subsystem

## Synthesis

### Consensus
All sources agree: the deadlock pattern is architectural in CoreAudio's HAL, worsened by Apple Silicon's CMIO DAL, and compounded by Bluetooth device transitions. The main thread is the critical bottleneck.

### Actionable Recommendations (priority order)
1. **Immediate:** Move all session operations and sample buffer delegate off main thread
2. **Immediate:** Remove per-device listener accumulation (never cleaned up, causes duplicates)
3. **Short-term:** Add `killall coreaudiod` as automated recovery after N failed restarts
4. **Medium-term:** Evaluate AVAudioEngine migration to bypass CMIO entirely
5. **Accept:** AVFoundation's internal DeviceIsAliveListener deadlock is unfixable from user code
6. **Wait:** Apple's Tahoe patch may resolve the broader OS-level issues
