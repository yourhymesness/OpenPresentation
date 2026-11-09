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

# Roadmap

## v0.3.x — Editor (current)

- [x] Eight free-resize handles for selected visual layers
- [x] Optional aspect-ratio lock
- [x] Exact pixel X/Y/width/height editing (1920×1080 canvas)
- [ ] Full undo/redo coverage for dragging, resizing, and attribute changes
- [x] Font browser with sample names drawn in their actual typefaces and non-destructive hover preview
- [ ] More granular group transforms, alignment/distribution tools

## v0.4 — Variable-size project canvas

- [ ] New-show dialog with 16:9, 4:3, portrait, square, ultrawide, and custom pixel presets
- [ ] Save canvas width/height in show metadata with backwards compatibility
- [ ] Resize editor, output, thumbnails, renderer and hit testing to respect saved canvas size
- [ ] Controlled existing-show canvas resizing, including layer coordinate conversion

## Stability and production readiness

- [ ] Build and test on macOS via GitHub Actions
- [ ] Extended audio/video/output soak tests, including windowed/fullscreen transitions
- [ ] Recovery after crashes, safe autosaving, and comprehensive Undo/Redo
- [ ] Renderer profiling with Instruments on Apple Silicon
- [ ] Accessibility, localization, automated UI tests and signed/notarized binaries

This is a planning document, not a promise of release timing.
