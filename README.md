# macos-mic-keepwarm

Fix the 2-5 second push-to-talk activation delay on macOS.

If you use voice transcription apps like SuperWhisper, WhisperFlow, Wispr Flow, macOS Dictation, or any push-to-talk tool and experience a delay before recording starts, especially with AirPods or Bluetooth audio, this is for you.

## The Problem

macOS aggressively power-manages the microphone hardware on Apple Silicon Macs (M1/M2/M3/M4). When no app is actively using the mic, the hardware goes to sleep. The next time a push-to-talk app tries to record, it has to wake the mic hardware first, causing a 2-5 second delay.

This means:
- You press your push-to-talk key and start talking
- The first 2-5 seconds of speech are lost or the app appears frozen
- If you use it again quickly (within ~30-60 seconds), it's instant
- Wait a minute, and the delay is back

This is especially bad with AirPods and Bluetooth headsets, where the audio routing adds even more wake-up latency.

## What I Tried (So You Don't Have To)

I spent hours debugging this across SuperWhisper and WhisperFlow on macOS Tahoe 26.2 (M4 MacBook Air). Here's everything that did NOT fix the activation delay:

- Changing the push-to-talk hotkey (tried Function key, Option+Space, Command+Shift+R)
- Restarting `coreaudiod` and `corespeechd`
- Increasing audio buffer sizes (`HALInputBufferSizeFrames`)
- Changing audio sample rates
- Resetting CoreAudio preferences
- Disabling Continuity Camera
- Granting Input Monitoring and Accessibility permissions
- Changing microphone input sources
- Restarting the Mac
- pmset power management tweaks
- nvram boot-args (not applicable on Apple Silicon)

None of these address the hardware-level mic sleep behavior.

### Related Issue: Recording Cutoff at 5-7 Seconds

During debugging I also discovered that **Siri's Built-In Voice Trigger** (`CSBuiltInVoiceTrigger`) can interfere with push-to-talk apps, causing recordings to cut off after 5-7 seconds. If you're experiencing that issue too, disable Siri voice activation:

1. System Settings > Siri & Spotlight
2. Turn OFF "Listen for 'Siri'" / "Listen for 'Hey Siri'"
3. Turn OFF "Press function key for Siri"

### Related Issue: Virtual Audio Plugins Cause Delay

Third-party audio drivers from Teams, Zoom, and other conferencing apps (installed at `/Library/Audio/Plug-Ins/HAL/`) add significant startup latency to mic activation and cause `coreaudiod` to consume excessive CPU even when idle (measured at 36.8% CPU with plugins enabled, 0.0% after disabling). Even with the keep-warm fix, these plugins can reintroduce delay. If you have `MSTeamsAudioDevice.driver`, `ZoomAudioDevice.driver`, or similar, disable them:

```bash
sudo mv /Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver /Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver.disabled
sudo mv /Library/Audio/Plug-Ins/HAL/ZoomAudioDevice.driver /Library/Audio/Plug-Ins/HAL/ZoomAudioDevice.driver.disabled
sudo killall coreaudiod
```

Teams and Zoom still work for calls without these custom drivers.

## The Fix

A lightweight native Swift binary that holds the microphone input stream open. The mic hardware stays powered on and ready, so push-to-talk activation is always instant.

### Why native instead of ffmpeg?

The previous approach used ffmpeg from Homebrew. It worked, but every `brew upgrade` moves ffmpeg to a new path (e.g. `8.0.1_2` to `8.0.1_3`). macOS TCC tracks mic permissions by binary path for unsigned binaries, so every upgrade silently breaks the mic permission. You get the push-to-talk delay back with no indication why. The native binary lives at `~/.local/bin/mic-warm` with ad-hoc code signing, so the permission grant is stable. If upgrading from the ffmpeg version, the installer handles migration automatically.

### How It Works

`mic-warm` uses `AVCaptureSession` with an audio data output to hold the default microphone open. Audio samples are captured and immediately discarded. Nothing is recorded, stored, or transmitted. The only effect is that the microphone hardware stays awake.

When you connect or disconnect AirPods, a Bluetooth headset, or any audio device, a CoreAudio property listener fires instantly and the session restarts on the new device after a 3-second debounce window (to let Bluetooth handoffs settle).

- CPU usage: ~0%
- Battery impact: negligible
- Privacy: no audio is captured or stored anywhere
- Works with: built-in mic, AirPods, Bluetooth headsets, USB mics, any input device
- Instant device-change detection via CoreAudio event listener (no polling)

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/drewburchfield/macos-mic-keepwarm/master/install.sh | bash
```

This downloads a precompiled universal binary (ARM + Intel), installs it to `~/.local/bin/mic-warm`, and creates a LaunchAgent that:
- Starts automatically on login
- Restarts automatically if killed
- Runs silently in the background

macOS will prompt you to grant mic-warm microphone access. Go to System Settings > Privacy & Security > Microphone and allow it.

### Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/drewburchfield/macos-mic-keepwarm/master/uninstall.sh | bash
```

Or clone the repo and run `./uninstall.sh`.

## The Orange Dot

macOS will show the orange microphone indicator dot in the menu bar, attributed to "mic-warm". This is accurate: mic-warm has the mic open. But it's not listening to you. Audio samples are captured and immediately discarded.

This is the same reason transcription apps don't solve this themselves. They should. SuperWhisper's own changelog acknowledges "handling push to talk shortcut if microphone is slow to start." The correct engineering solution is to keep the audio input stream open between recordings and use a ring buffer with lookback. When the user presses push-to-talk, start reading from the buffer, including audio captured just before the keypress. But apps don't want users seeing "SuperWhisper is using your microphone" 24/7, even though the alternative is a broken user experience.

Apple could fix this by providing a fast-wake API or a low-power standby mode for the mic hardware that doesn't trigger the orange dot. As of macOS Tahoe 26.2, no such API exists.

## Why Not Use BlackHole or a Virtual Audio Device?

You don't need one. BlackHole, Loopback, and SoundFlower create virtual audio routing devices, which adds complexity and can introduce their own latency and compatibility issues. This fix works directly with your real microphone hardware. It's simpler and has fewer things that can break.

## System Requirements

- macOS 13 Ventura, 14 Sonoma, 15 Sequoia, or 26 Tahoe
- Apple Silicon (M1/M2/M3/M4) or Intel Mac (universal binary)
- Microphone permission for mic-warm

## Testing

Run the integration test suite to verify process lifecycle, signal handling, and PID file management:

```bash
./test.sh
```

Device-switching tests require real audio hardware and should be done manually.

## Legacy Shell Script

The original `keep-mic-warm.sh` is kept as a fallback for systems where the native binary can't be used. It requires `ffmpeg` and `switchaudio-osx` from Homebrew. See the file header for details.

## License

MIT
