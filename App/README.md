# Mic Warm app

The native menu-bar app (bundle id `com.drewburchfield.micwarm`, version 1.0.0). Code lives in
`Sources/MicWarmApp`; this folder holds the bundle's Info.plist and icon.

## Build and run

```bash
scripts/install-app.sh             # build, install in /Applications, launch
scripts/build-app.sh               # .build/Mic Warm.app, native arch
scripts/build-app.sh --universal   # arm64 + x86_64
```

The app runs the same capture engine as the CLI (`Sources/MicWarmEngine`) and logs to
`~/Library/Logs/mic-warm/app.log`, next to the CLI's `mic-warm.log` and the shared `bt.log`.

## Living beside the command-line mic-warm

The app and the CLI share one instance lock, so only one holds the mic. While the CLI's
LaunchAgent (`com.user.keep-mic-warm`) is loaded, the app stands by with a dimmed glyph and
leaves the mic alone. **Switch to Mic Warm App** in its menu disables the agent (it stays off
across logins), stops the CLI, takes the lock, and turns on Open at Login.

To go back, hold Option while opening the menu and pick **Switch Back to Command-Line
mic-warm**. The app releases the mic, re-enables and starts the agent, and quits.

## Menu

- Header and detail: what the app is doing, with a status dot.
- Pause / Resume: releases the mic and keeps it closed, across relaunches, until resumed.
- Open at Login, Sound Settings…, About, Quit.
- Hold Option for diagnostics: Preview State (shows any glyph without touching the engine),
  Show Logs in Finder, and Switch Back to Command-Line mic-warm.

`--state <warm|recovering|paused|needs-access>` at launch starts previewing that glyph.
`"Mic Warm.app/Contents/MacOS/Mic Warm" --render-glyphs <dir>` writes each state's menu-bar
glyph as PNG at 1x and 2x.

Ad-hoc builds get a new code hash each time, so macOS asks for microphone access after each
rebuild. `MIC_WARM_SIGN_IDENTITY` signs with a stable identity instead; `install-app.sh`
picks the first Apple Development identity it finds.

## Icons

- Menu-bar glyph: "Fire circle", drawn in code from the comp geometry
  (`FireCircleGlyph.swift`) as an 18 × 18 pt template image. The stone ring spins while
  recovering and holds still under Reduce Motion.
- App icon: "Night". `AppIcon/AppIcon.svg` is the full drawing and `AppIcon/AppIcon-small.svg`
  the simplified one for 16 and 32 px. `scripts/make-app-icon.sh` renders both into
  `AppIcon.icns` (needs Google Chrome and ImageMagick, so the .icns is committed).
