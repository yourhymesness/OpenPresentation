# OpenPresentation v0.3.2 — Free Stretch and Shape Presets

Images/videos/GIFs maintain their rectangle's aspect ratio by default. Hold **⌥ Option while dragging any resize handle** to stretch X/Y independently; this activates **Media pixels: Stretch (distort)** for visual pixels (not merely the frame). The inspector exposes **Media pixels: Fit / Fill / Stretch** and the persistent **Lock ratio** toggle. Use Fit or Fill to restore normal pixel mapping. Audio playback is unaffected.

**Add Object** now includes **Square**, **Circle**, and **Equilateral Triangle**, all created at proper pixel proportions on the current 1920×1080 canvas. Changing an existing shape to one of these presets also normalizes its proportions. Regular Rectangle/Ellipse/Triangle remain freely resizable.

**Testing:** Resize a picture/video using ordinary drag, Option-drag it into unusual proportions, switch Fit/Fill/Stretch, use Undo to restore, then add and transform each new shape. Verify existing shows still open. GitHub Actions builds and tests macOS source after push; native runtime still needs operator verification.

---

# OpenPresentation

**Open-source live presentation software for macOS (Apple Silicon first)**, developed by HiTech Productions.

> **ALPHA SOFTWARE — PROVIDED AS IS, WITHOUT WARRANTY.** OpenPresentation has not yet been qualified for show-critical use. Test outputs, video, audio and saved shows before using it at an event.

OpenPresentation is an evolving ProPresenter-style application with a separate **Program** output and **Blind** editor. It supports slide collections, text and shape layers, images/GIFs/video/audio, fullscreen and windowed outputs, transitions, automatic slide advancement, and per-slide audio controls. This project is independent of and not affiliated with Renewed Vision.

## Getting started

1. Install a recent Xcode for macOS (macOS 14 or later is the current project target).
2. Open `OpenPresentation.xcodeproj` in Xcode.
3. Choose the `OpenPresentation` scheme and **My Mac** destination, then press **⌘R**.
4. Add a slide, switch to **Blind** to edit it, then use **Live** to operate the presentation. Select an audience output in application Settings.

There are currently **no distributed signed/notarized app binaries**. Build the app from the Xcode source. An Apple Silicon Mac is the primary development target; other Mac hardware has not been qualified.

## What's new in v0.3.1 alpha — Visual Font Browser

- **Searchable font browser** in the Blind layer inspector, with installed font-family names displayed in their own typefaces and a sample line (`Aa Bb 123`).
- **Live-on-canvas hover preview**: hover a font to see it on the selected text layer. Leaving the row or closing the browser restores the original, without editing the saved slide or changing Program.
- **Click to apply** the font to that layer, with a single Undo step. Switching slides or layers cancels a pending preview.
- The existing eight-handle resizer and pixel-precise geometry editor from v0.3.0 remain available.

### How to try it

In Blind mode, select a text layer, open the **Font** control in the layer inspector, and search or hover. Move the pointer away to restore the original typeface, or click a choice to commit it. Check that a live Program slide remains unchanged until deliberately taken again.

## What's in v0.3.0 alpha

- **Eight resize handles** (four corners, four edge midpoints) for visual layers; resize width and height independently.
- Optional **Lock ratio** switch in layer attributes when an image/video should keep its visual frame aspect ratio.
- Precise **X, Y, W and H** attributes in pixels on the current **1920×1080** presentation canvas (X/Y measure the layer's top-left corner).
- Existing Blind/Live workflow, media rendering and show-file format retained.

Older v5 show documents remain compatible: the aspect-lock setting is optional. Starting in v0.3.2, image/video layers default to locked proportions when the field is absent, while older shape/text layers remain free-resize by default. **Variable project canvas sizes are planned**, not yet implemented. The v0.3.1 font hover browser previews in Blind only.

## Limitations

- The document canvas is currently fixed at 1920×1080 (16:9). Display scaling can fit other output screens, but that does **not** make the authored canvas variable.
- Image/video media file references and the companion `.media` folder must be kept together when moving a show.
- This release has **not** completed a full macOS Xcode build or performance qualification here; CI on GitHub is intended to catch integration failures, and device testing is required for UI behavior.
- Layer geometry is clamped to the canvas. Overlapping or very small elements may need exact pixel entry rather than dragging.

## Project structure

- `OpenPresentation/App`: application entry point and native menu handling
- `OpenPresentation/Core`: show models, geometry, snapping and playback sequencing
- `OpenPresentation/Interface`: operator UI and Blind layer editor
- `OpenPresentation/Rendering`: Program/output rendering and media playback
- `OpenPresentation/Storage`: show-file loading and saving
- `Tests`: portable model tests

## Contributing and bugs

Open a GitHub Issue with reproducible steps, expected behavior, actual behavior, and your macOS/Xcode versions. For visual glitches, attach screenshots or a screen recording. Read [CONTRIBUTING.md](CONTRIBUTING.md) and [ROADMAP.md](ROADMAP.md) before proposing large features.

Website: [hitechproductions.com](https://www.hitechproductions.com/) · Feature requests/support: [william.hymes@hitechproductions.com](mailto:william.hymes@hitechproductions.com)

## License

[Apache License 2.0](LICENSE). OpenPresentation is provided **AS IS**, without warranties or guarantees. See the license for details.
