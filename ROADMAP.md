# OpenPresentation Roadmap

**Current alpha: v0.5.0.1.** The persistent show-audio bus and seamless output
handoff are implemented and have been tested on macOS hardware. The priorities
below were reordered to put Metal rendering ahead of Stream Deck controls.
The first Metal Program preview and rolling frame diagnostics are available
behind an explicit, session-only experimental Preview choice; audience output
is unchanged. A reported M5 Pro crash is still under investigation.

## v0.5.x — Metal rendering and multi-output foundation (next)

**Goal:** Render one synchronized show frame and present it efficiently to the
Program monitor and multiple audience destinations. Preserve the continuous
show-audio bus introduced in v0.4.13.

- **v0.5.0 — Measure and prove the rendering path (prototype).** Instrument frame timing,
  missed display deadlines, decoder/frame availability, memory pressure, and
  texture transfers. Benchmark real 1-, 4-, and 8-video slides on Apple Silicon,
  including the M5 Pro and existing M1 Pro test machines, with output windows
  open and closed. Build a Metal proof of concept that composites video and
  static layers without changing the on-air renderer by default.
- **v0.5.1 — Shared GPU compositor.** Move from independent window-specific
  video rendering toward a single frame source per media take, shared across
  destinations. Use AVFoundation's decoded pixel buffers and GPU textures,
  preserving aspect modes, alpha, z-order, text, shapes, images, GIFs, fades,
  and the authored canvas resolution. Keep the original renderer available as
  a compatibility fallback until visual parity and timing are verified.
- **v0.5.2+ — Multiple canvases and projection mapping.** Independent output
  assignments, slices/crops of a larger canvas, position/rotation/scale,
  overlap guides, edge blending and calibration. Add output-safe handling of
  monitor changes and disconnections; keep the operator display recoverable.

**Release gates:** No audio restart when toggling outputs; no slide/show-file
format regressions; predictable transitions; measured output-frame behavior
under heavy video load; and extended local hardware testing. Metal is not a
promise that every video codec or output configuration will run smoothly:
profiling and fallback modes remain essential.

## v0.6.x — Stream Deck and external show control

- Add a local-only, authenticated control interface sharing the existing
  ShowController commands (Take, Next/Previous, Clear, Blackout, media transport,
  collection selection) and publishing show-state feedback.
- Implement a companion Elgato Stream Deck plugin with configurable actions,
  stateful button indicators, safe reconnection and explicit connection errors.
- The local control interface must be testable without physical Stream Deck
  hardware. Consider other control surfaces only after the command protocol is
  stable.

## v0.7.x — Professional output protocols

- Add NDI output after the shared-renderer timing and pixel format are stable.
- Add DeckLink/SDI output with explicit device discovery and format negotiation.
- Test failure recovery and output synchronization with actual supported
  hardware before advertising show-ready compatibility.

## Later — Cross-platform architecture

- Keep show models, transport decisions, transition planning and output
  configuration independent of AppKit/SwiftUI wherever practical.
- Design a renderer abstraction that can eventually target Metal on macOS and
  other graphics APIs on Windows/Linux, without assuming the macOS backend is
  portable unchanged.

## Engineering quality across all milestones

- [x] GitHub Actions macOS compile and portable model checks
- [x] Crash recovery/autosaving and Program audio metering
- [x] Persistent audio bus independent of output window lifecycle
- [ ] Instruments profiling, frame-drop telemetry and GPU workload baselines
- [ ] Extended audio/video/multi-output soak testing
- [ ] Automated UI coverage, improved Undo/Redo and signed/notarized builds

This is a planning document, not a commitment to specific release dates.

---

# Earlier milestones and historical planning notes

## v0.4.2 — Blind Editor Zoom and Text Outlines (Implemented)

- Editor-only wheel/pinch/preset/Zoom to Fill; scroll an enlarged slide.
- Text outline color and pixel thickness, rendered in both Preview and Program.
- Preserve optional metadata compatibility with older shows.

## v0.4.2 — Planned existing-show canvas resizing

- Add a deliberate **Change Show Canvas** command with a visible preview, confirmation and Undo.
- Offer proportional normalized scaling (default), pixel-preserving translation and center anchoring. Existing v5 shows must continue to load at 1920×1080.
- Expand multiscreen visual regression testing for portrait and ultrawide video, animated GIF, transparency and fullscreen output cropping.

**v0.4.0 implemented:** source canvas presets/custom dimensions, New Show chooser, v6 save/load, legacy default, renderer/editor/output/thumbnail aspect ratio and pixel field migration.

## Implemented in v0.3.2

- Media frames lock proportions by default, with Option (⌥) drag for independent X/Y stretching.
- Fit/Fill/Stretch pixel mapping in image and video inspector.
- Square, Circle, and Equilateral Triangle vector presets and shape conversion at pixel-correct dimensions.

## Implemented in v0.3.1

- Searchable font browser with font names and `Aa Bb 123` samples displayed in their own typefaces.
- Hover-to-preview on the selected text layer directly on the Blind canvas; click to apply with undo.
- Visual-only previews do not change saved show data or Program.

# Earlier editor and canvas backlog

## v0.3.x — Editor (historical)

- [x] Eight free-resize handles for selected visual layers
- [x] Optional aspect-ratio lock
- [x] Exact pixel X/Y/width/height editing (1920×1080 canvas)
- [ ] Full undo/redo coverage for dragging, resizing, and attribute changes
- [x] Font browser with sample names drawn in their actual typefaces and non-destructive hover preview
- [ ] More granular group transforms, alignment/distribution tools

## v0.4 — Variable-size project canvas (implemented for new shows)

- [ ] New-show dialog with 16:9, 4:3, portrait, square, ultrawide, and custom pixel presets
- [ ] Save canvas width/height in show metadata with backwards compatibility
- [ ] Resize editor, output, thumbnails, renderer and hit testing to respect saved canvas size
- [ ] Controlled existing-show canvas resizing, including layer coordinate conversion

## Original stability and production readiness checklist

- [ ] Build and test on macOS via GitHub Actions
- [ ] Extended audio/video/output soak tests, including windowed/fullscreen transitions
- [ ] Recovery after crashes, safe autosaving, and comprehensive Undo/Redo
- [ ] Renderer profiling with Instruments on Apple Silicon
- [ ] Accessibility, localization, automated UI tests and signed/notarized binaries

This is a planning document, not a promise of release timing.

### v0.4.3 — Live audio metering
Implemented decoded-PCM Program and estimated Master meter displays for the
current file-based AVPlayer architecture. Future work: sample-synchronous
master mix telemetry once a unified audio-mixing engine is available.
