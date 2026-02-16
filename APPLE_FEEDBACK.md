# Apple Feedback Report

This documents a formal bug report and API request submitted to Apple through Feedback Assistant regarding microphone hardware power management on Apple Silicon Macs.

## Status

| Field | Detail |
|-------|--------|
| **Feedback ID** | FB21969131 |
| **Status** | Submitted |
| **Date** | February 16, 2026 |
| **Category** | macOS > Audio |
| **Type** | Suggestion |
| **Environment** | macOS Tahoe 26.2 (25C56), M4 MacBook Air |

## Submission Title

> Microphone hardware sleep causes 2-5 second activation delay on Apple Silicon Macs; no low-power standby or fast-wake API exists

## Summary of Report

On Apple Silicon Macs, macOS aggressively power-manages the microphone hardware. Two issues create significant latency for push-to-talk and voice transcription applications:

1. **Hardware sleep**: when no application is actively capturing audio input, the mic hardware enters a sleep state. The next capture start takes 2-5 seconds before audio samples are delivered. This recurs every time the mic has been idle for approximately 30-60 seconds.

2. **Bluetooth device switching**: when AirPods or a Bluetooth headset become the active input device, SCO channel negotiation adds 1-3 seconds of delay regardless of whether the mic was idle. This compounds with hardware sleep when both conditions are present.

There is currently no public API for an application to request that audio input hardware remain in a low-power standby state, pre-warm the hardware before capture, or receive audio samples with guaranteed low-latency startup.

## Findings Included

The submission includes detailed reproduction steps, measurements, and the following additional findings discovered during investigation:

- **AVCaptureSession.stopRunning() deadlock on Bluetooth disconnect**: circular deadlock between coreaudiod's HALB_Guard, BTAudioHALPlugin, and the calling process's CMIO pipeline when a Bluetooth device disappears during active capture. Documented with spindump evidence from a live deadlock capture.
- **CoreAudio output device listeners trigger kTCCServiceAudioCapture on macOS 26.2**: registering property listeners on output devices or system-wide output properties triggers a "record system audio" TCC prompt, separate from the standard microphone permission. This is a breaking change from earlier macOS versions.
- **Siri voice trigger interference**: CSBuiltInVoiceTrigger can preempt third-party audio capture sessions, causing recordings to cut off after 5-7 seconds.
- **Third-party HAL plugin latency**: Audio HAL plugins from Teams and Zoom add startup latency and cause coreaudiod to consume excessive CPU when idle.
- **TCC path-based permission fragility**: Homebrew upgrades move binaries to new versioned paths, silently orphaning microphone permission grants.
- **Device change notification complexity**: multiple rapid events per single device change, Bluetooth readiness lag behind notification delivery, bidirectional switching asymmetry, transient nil default device during handoff.
- **coreaudiod restart invalidation**: active AVCaptureSessions silently stop delivering samples with no notification to the application.
- **DispatchSource signal handling unreliability**: signal handlers installed via DispatchSource with dispatchMain() can fail to fire.

## Suggested API Additions

The report proposes three alternative API approaches that would allow applications to avoid the permanent microphone indicator workaround:

1. A `prepareForCapture()` pre-warming hint on AVCaptureSession
2. A `kAudioDevicePropertyStandbyMode` CoreAudio property for low-power hardware standby
3. A `maintainsStandbyState` property on AVCaptureDevice

## Attachments Submitted

- System information report (generated via Feedback Assistant)
- Sysdiagnose archive (containing spindump with live deadlock evidence)
- Full analysis document with reproduction steps, measurements, and all findings
- Source code of the workaround tool ([main.swift](Sources/MicWarm/main.swift))
- Sample log output demonstrating device switching and auto-recovery behavior

## Workaround

This repository implements the only reliable workaround: a lightweight native Swift binary that holds the microphone input stream open, preventing hardware sleep and keeping the Bluetooth audio channel negotiated. See the [README](README.md) for details.

## Updates

This section will be updated if Apple responds or the status changes.

*No response received yet.*
