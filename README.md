# OpenPresentation v0.4.4 — Smooth Audio Meters and Muted Startup

The mixer now uses 60 Hz smooth ballistics, clearly marked **Pre** cue meters and **Post** Master levels, stereo L/R, 0 to -48 dBFS scale, white peak-hold markers aligned to the meter, and a readable CLIP warning. Master remains an estimated sum, not an audio-device loopback. Video and audio players now apply mute/zero volume before playback resumes to prevent a first-frame sound leak.

# OpenPresentation v0.4.3 Alpha — Live Audio Meters

The Program fader now shows live decoded PCM stereo meters, and the Master fader shows an estimated combined stereo level after the master gain. The Next cue remains idle until it is actually playing. Bars represent RMS audio level, with a white peak-hold line and a red potential-clipping warning. These are **signal-derived meters, not output-device loopback**.

## Earlier highlights

### v0.4.2 — Autosave and crash recovery

Unsaved slide changes are captured to separate recovery snapshots every five seconds and offered at next launch after an interrupted session. Snapshots do not overwrite saved shows or back up media files.

### v0.4.1 — Zoom and Text Outlines

**Blind Editor zoom:** The bottom-left zoom dropdown offers **Zoom to Fill** and percentage presets. Scroll the mouse wheel over the canvas or pinch on a trackpad to zoom in/out. Shift+scroll or the scrollbars pan an enlarged slide. Zoom is a view-only setting; it never changes Program or the saved show.

**Text outlines:** Select a text layer and set **Text outline** color and **Outline width** (in authored pixels). A black outline of 2–4 px around white text helps on busy backgrounds. Outlines render consistently in Preview and Program. Existing shows have no outline unless you enable it.

# OpenPresentation v0.4.0 Alpha — Custom Canvas Sizes

OpenPresentation now supports configurable *authored* canvas dimensions instead of forcing every show to 1920×1080. Select **File → New Show… (⌘N)** and choose a preset or enter custom width and height (64–8192 px). The chooser previews the aspect ratio before you create the show.

Presets include 1920×1080, 1280×720, 3840×2160, portrait 1080×1920 / 2160×3840, square 1080×1080 / 2160×2160, and ultrawide/LED 2560×720 / 3072×768 / 3840×1080. You can also type any valid custom dimensions.

The active canvas size is shown on the operator status bar. Program, Blind editor, thumbnail previews, audience output and windowed output use that ratio; **X/Y/W/H pixel fields use the saved canvas dimensions**. Transparent and inherited backgrounds, multimedia layers, font previews, and eight-point resize handles retain their existing behavior.

**Document compatibility:** New saves use show format v6. Older v1–v5 shows load at **1920×1080** without changing normalized layer positions. There is no in-place Resize Existing Show command yet; that is targeted for v0.4.2. Save a separate copy before experimenting with older show files. An existing v5 reader will not recognize v6 files.

**Test this build:** Create Full HD, portrait, square and ultrawide shows. Add text, shapes, pictures/video, and check editor geometry, thumbnail ratios, external displays, scaling Fit/Fill, Save/Open and the size readout. Try opening an existing show and confirm the ratio remains 16:9. This alpha is provided **AS IS, WITHOUT WARRANTY**; the automated build validates compilation, but it has not been qualified for show-critical use.

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
- Precise **X, Y, W and H** attributes in pixels on the active presentation canvas (X/Y measure the layer's top-left corner).
- Existing Blind/Live workflow, media rendering and show-file format retained.

Older v5 show documents remain compatible: the aspect-lock setting is optional. Starting in v0.3.2, image/video layers default to locked proportions when the field is absent, while older shape/text layers remain free-resize by default. **Variable project canvas sizes are available starting in v0.4.0.** The v0.3.1 font hover browser previews in Blind only.

## Limitations

- Changing the canvas of an existing show is not yet supported. Set the canvas for new shows; older shows open at Full HD. Physical outputs use Fit/Fill against the chosen canvas.
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

### Autosave and recovery (v0.4.2 alpha)

OpenPresentation keeps **local emergency recovery snapshots every five seconds when the authored show has unsaved changes**; it also checks when the app loses focus. It keeps the newest snapshot and two backups, stored under your macOS user's **Application Support/OpenPresentation/Recovery** folder, **not** in your original `.json` show or its `.media` companion directory. A successful manual Save clears the active recovery snapshots. Normal Quit (including choosing Don't Save) discards the active draft; an unexpected crash or Force Quit does not.

On reopening after an interruption, choose **Recover** to restore the newest available unsaved show, **Later** to leave the recovery data intact, or **Discard Recovery** to delete that draft. Recovered work opens as **unsaved** and does **not** automatically go to the audience output. Review the recovery and choose Save or Save As yourself. Media files are **referenced by their original paths** rather than duplicated, so keep source media available. Recovery is not a substitute for real backups.

**Safe test:** create a disposable test show, add a slide and edit it, look for the “Recovery saved” status in the operator footer (allow at least 10 seconds), then use **Apple menu → Force Quit → OpenPresentation → Force Quit**. Reopen OpenPresentation and select Recover. Verify changes, and save to a test `.json` file. Don't do this while a show is live; Force Quit will immediately interrupt all output.

## Live audio meters (v0.4.3)

The Program and Master faders now include stereo RMS bars with a brief peak hold and
red clipping warning. A local MediaToolbox audio tap reads decoded PCM from each
file-based AVPlayerItem without modifying the samples. The meters will be silent
when no audience output is playing, and the **Next** fader stays idle until its
slide is on Program. The master display follows mute/gain and shows **EST**:
independent audio and video players are mixed downstream by macOS, so the
summed level is a *signal-derived estimate*, **not** a calibrated, sample-accurate
Core Audio hardware/device loopback. It does not meter other apps. Audio taps
support local file media, not HLS; unusual formats may lack meter data.

For live events, always verify levels with the physical audio interface or mixing
console. Test local stereo clips, looped background audio, video clips with
embedded audio, fade behaviors, and moving between Windowed/Fullscreen outputs.
