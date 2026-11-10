# SplatShell

A native macOS app for viewing and editing 3D Gaussian Splatting scenes. It wraps [SuperSplat](https://github.com/playcanvas/supersplat), the PlayCanvas splat editor, in a `WKWebView` and opens files straight from disk, so scenes of tens of millions of splats load without a server or a browser tab.

The renderer and the editing tools are SuperSplat's. SplatShell adds the window, the menus, file handling and updates.

## What it does

- Opens `.ply`, `.spz`, `.splat`, `.sog` and `.ssproj` from File > Open or from Finder ("Open With")
- Reads files from disk on demand. An 11 GB PLY is never copied or held in memory as a file
- Serves the bundled SuperSplat build from inside the app. Nothing listens on a port
- Draws SuperSplat's unsorted stochastic mode while the camera moves and a sorted frame when it stops, which keeps very large scenes at display rate
- Updates itself with [Sparkle](https://sparkle-project.org)

On an M4 Max with 64 GB, a 48 million splat scene (11 GB, SH degree 3) loads in about 90 seconds and orbits at 60 fps. It uses about 17 GB of memory.

## Requirements

- Apple silicon Mac
- A macOS version whose WebKit has WebGPU. Developed and tested on macOS 26

## Build

Needs Xcode (Swift 6 toolchain), Node.js 20.19 or later and git.

```bash
./scripts/bundle.sh
open build/SplatShell.app
```

The script clones a pinned SuperSplat commit into `.build/supersplat`, builds it, builds the app and assembles `build/SplatShell.app` with an ad hoc signature, which runs on the Mac that built it.

## Not there yet

- Saving and exporting. SuperSplat hands saves to the browser as downloads, and the app does not handle those yet
- Z-up scenes open lying on their side. Rotate them in SuperSplat's Transform panel

## Credits

- [SuperSplat](https://github.com/playcanvas/supersplat) by PlayCanvas, MIT License. Its license is included in the app bundle
- [Sparkle](https://github.com/sparkle-project/Sparkle), MIT License
