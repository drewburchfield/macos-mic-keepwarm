# macos-mic-keepwarm

Fix the 2-5 second push-to-talk activation delay on macOS.

If you use voice transcription apps like SuperWhisper, WhisperFlow, Wispr Flow, or any push-to-talk tool and experience a delay before recording starts, especially with AirPods or Bluetooth audio, this is for you.

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

Third-party audio drivers from Teams, Zoom, and other conferencing apps (installed at `/Library/Audio/Plug-Ins/HAL/`) can add startup latency. If you have `MSTeamsAudioDevice.driver`, `ZoomAudioDevice.driver`, or similar, try disabling them:

```bash
sudo mv /Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver /Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver.disabled
sudo mv /Library/Audio/Plug-Ins/HAL/ZoomAudioDevice.driver /Library/Audio/Plug-Ins/HAL/ZoomAudioDevice.driver.disabled
sudo killall coreaudiod
```

Teams and Zoom still work for calls without these custom drivers.

## The Fix

A single lightweight background process that holds the microphone input stream open. The mic hardware stays powered on and ready, so push-to-talk activation is always instant.

No virtual audio devices needed. No BlackHole, Loopback, or SoundFlower. Just ffmpeg reading from the mic and discarding the audio.

### How It Works

```
ffmpeg -f avfoundation -i ":0" -f null /dev/null
```

That's it. ffmpeg opens the default audio input device and sends the audio to `/dev/null` (nowhere). Nothing is recorded, stored, or transmitted. The only effect is that the microphone hardware stays awake.

- CPU usage: ~0%
- Battery impact: negligible
- Privacy: no audio is captured or stored anywhere
- Works with: built-in mic, AirPods, Bluetooth headsets, USB mics, any input device

### Note on the Orange Dot

macOS will show the orange microphone indicator dot in the menu bar, attributed to "ffmpeg". This is accurate: ffmpeg has the mic open. But it's not listening to you. The audio goes straight to `/dev/null`.

## Installation

### Prerequisites

Install ffmpeg if you don't have it:

```bash
brew install ffmpeg
```

### Quick Start (Run Once)

```bash
chmod +x keep-mic-warm.sh
./keep-mic-warm.sh
```

### Persistent Install (Survives Reboots)

```bash
chmod +x install.sh
./install.sh
```

This creates a LaunchAgent that:
- Starts automatically on login
- Restarts automatically if killed
- Runs silently in the background

macOS will prompt you to grant ffmpeg microphone access on first run. Click "Allow".

### Uninstall

```bash
chmod +x uninstall.sh
./uninstall.sh
```

## Why Don't Transcription Apps Do This?

They should. SuperWhisper's own changelog acknowledges "handling push to talk shortcut if microphone is slow to start." The correct engineering solution is to keep the audio input stream open between recordings and use a ring buffer with lookback. When the user presses push-to-talk, start reading from the buffer, including audio captured just before the keypress.

The likely reason they don't: the orange microphone indicator dot. Apps don't want users seeing "SuperWhisper is using your microphone" 24/7, even though the alternative is a broken user experience.

Apple could fix this by providing a fast-wake API or a low-power standby mode for the mic hardware. As of macOS Tahoe 26.2, no such API exists.

## Why Not Use BlackHole or a Virtual Audio Device?

You don't need one. BlackHole, Loopback, and SoundFlower create virtual audio routing devices, which adds complexity and can introduce their own latency and compatibility issues. This fix works directly with your real microphone hardware. It's simpler and has fewer things that can break.

## Affected Apps

This delay affects any push-to-talk or voice transcription app on macOS, including but not limited to:
- SuperWhisper
- WhisperFlow
- Wispr Flow
- macOS Dictation
- Any app that activates the microphone on-demand rather than continuously

## System Requirements

- macOS (tested on Tahoe 26.2, likely affects Sequoia and earlier)
- Apple Silicon Mac (M1/M2/M3/M4) - Intel Macs may also be affected
- ffmpeg (`brew install ffmpeg`)
- Microphone permission for ffmpeg

## License

MIT
