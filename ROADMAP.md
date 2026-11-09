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
- [ ] Font browser with sample names drawn in their actual typefaces and non-destructive hover preview
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
