# Mic Warm app

The native menu-bar app (bundle id `com.drewburchfield.micwarm`, version 1.0.0). Code lives in
`Sources/MicWarmApp`; this folder holds the bundle's Info.plist and icon.

## Build and run

```bash
scripts/build-app.sh               # .build/Mic Warm.app, native arch
scripts/build-app.sh --universal   # arm64 + x86_64
open ".build/Mic Warm.app" --args --state recovering
```

`--state` takes `warm`, `recovering`, `paused`, or `needs-access`. The capture engine is not in
the app yet, so the menu's Preview State submenu switches the glyph by hand.

`"Mic Warm.app/Contents/MacOS/Mic Warm" --render-glyphs <dir>` writes each state's menu-bar
glyph as PNG at 1x and 2x.

## Icons

- Menu-bar glyph: "Fire circle", drawn in code from the comp geometry
  (`FireCircleGlyph.swift`) as an 18 × 18 pt template image. The stone ring spins while
  recovering and holds still under Reduce Motion.
- App icon: "Night". `AppIcon/AppIcon.svg` is the full drawing and `AppIcon/AppIcon-small.svg`
  the simplified one for 16 and 32 px. `scripts/make-app-icon.sh` renders both into
  `AppIcon.icns` (needs Google Chrome and ImageMagick, so the .icns is committed).
