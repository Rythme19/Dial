# Dial

Quick file actions for macOS. Select files in Finder, tap **fn + control**, and a small
Liquid Glass ring opens under the pointer. Pick a type, then an action. The result lands
next to the original, and Dial never overwrites anything (it adds " 2" instead).
Everything runs locally.

| Type | Actions |
|---|---|
| PDF | Merge (PDFs and images), Split, Compress, Rotate, To JPG, To PNG, Text |
| Image | To JPG, To PNG, To PDF, To WebP, Half size, Compress, Strip info |
| Video | To MP4, To GIF, Compress, Audio only |
| Audio | To MP3, To M4A, To WAV |
| General | Zip, Copy path, New folder, Add date |

With a mixed selection (for example a PDF and an MP4), the ring only shows what works.

## Keys

- **fn + control**: tap and release to open or close the ring (Finder must be in front).
  To use other keys, open **Settings…** from Dial's menu-bar icon and pick any two or more of
  fn, Control, Option, Command and Shift.
- **1–9** or click: choose an item.
- **← →**: move. **Return**: choose.
- **Esc**, or a click in the centre: go back or close.

## Requirements

- macOS 26 on Apple silicon, with the Command Line Tools (`xcode-select --install`).
- For some actions:

  ```bash
  brew install ghostscript ffmpeg webp
  ```

  Ghostscript handles PDF Compress, ffmpeg handles video and audio, and webp handles To WebP.

## Build

```bash
./build.sh            # → build/Dial.app
./build.sh install    # also copies it to ~/Applications and restarts it
```

On first launch, macOS asks for two permissions:

- **Accessibility**: to notice fn + control (System Settings → Privacy & Security → Accessibility).
- **Automation → Finder**: to read which files are selected.

The build is ad-hoc signed, so macOS may ask again after each rebuild. If fn + control stops
working, remove Dial from the Accessibility list and add it again.

## Develop

```bash
build/Dial.app/Contents/MacOS/Dial --selftest <folder of sample files>
```

The self-test checks the fn + control detection and the mixed-selection rules, then runs every action
on temporary copies.

`--demo [--dark] [--level PDF] [--hot N] [--press N] files…` shows the ring in a fixed
state for screenshots. `design/radial-preview.html` is the HTML mock it was designed from.

```
Sources/Actions.swift     file kinds, the action catalog, conversion engines
Sources/RadialMenu.swift  menu model and the SwiftUI ring
Sources/main.swift        menu-bar app, shortcut detection and Settings, Finder selection, self-test
design/icon.swift         draws AppIcon.icns (swift design/icon.swift)
```
