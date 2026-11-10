## v0.4.9-alpha — Live Shared 12 FPS Program preview

- Instead of static placeholders, Auto responds to detected lag by switching only the small Program monitor to moving frames sampled from the active audience's AVPlayerItemVideoOutput. It uses the audience's existing decoded pixel buffers rather than allocating separate AVPlayers in Program.
- Added manual **Shared 12 FPS** preview selection alongside Auto, Full Video and Low-load. Shared mode requires an open audience window; with none open, Program falls back to native full video.
- Frames are sampled at most 12 times/second, with each image capped at 360 pixels on its longest edge. One shared timer and per-stream sampling cache update preview CALayers directly without SwiftUI layout invalidations.
- Reduced Auto false positives by ignoring most minor main-thread timing variation (two >180ms overshoots, or one >500ms stall, now needed).
- Actual Fullscreen/Windowed players retain their original frame rates, audio ownership, transitions, playheads, and output priority. GIF animation remains active in sampled preview mode.
- Limitations: First samples can take a moment; some codecs or protection modes may not supply pixel buffers, and video areas may appear black in sampled mode. Select Full Video for those sources. This is not yet a unified GPU compositor, and soft-loop dissolves may be less smooth in sampled preview. Test on macOS hardware before live use.

## v0.4.8 — Pressure-adaptive Program Preview

- Changed Program Preview Auto from a **video-count threshold** to a performance-sensitive policy. Even heavy slides begin with a full-motion Program preview; Auto reduces only if the operator main-thread heartbeat shows repeated significant stalls (or one severe stall), macOS reports memory pressure, or ProcessInfo reports serious/critical thermal pressure.
- A simple decaying stall score avoids triggering on ordinary timer jitter. Preview returns to full-motion after 30 seconds of stable observations, with protection against rapid mode thrashing. When no audience output is open, Auto keeps the Program preview fully animated.
- The reduced-preview badge now explains its **actual cause** (Interface lag, Memory pressure, or Thermal pressure). Full Video and Low-load remain unconditional manual overrides.
- The app's memory-pressure notifications are event-driven; the 4 Hz operator heartbeat does not increase video decoder or display refresh rates and only publishes UI changes on state transitions.
- Added pure tests of stable eight-video playback, short hiccups, sustained stalls, recovery, memory/thermal events, manual overrides and output close.
- **Limits:** These are indirect resource-pressure signals, not direct GPU/VideoToolbox frame-delivery metrics. Local-file AVPlayer access logs are not a reliable frame-drop sensor. This change does not lower preview video FPS; doing so efficiently requires a separate frame-sampling/compositing pipeline. Audience playback is unchanged.

## v0.4.7 — Smooth meter gradient and Fullscreen output protection

- Replaced the meter's discrete green/yellow/red threshold switching with a **fixed full-height six-stop gradient**. A rising peak bar reveals the green→yellow→orange→red spectrum continuously instead of changing its entire color at a threshold.
- Added **Program Preview Quality** selection to the Program monitor: Auto (default), Full Video, and Low-load. Under Auto, when an audience output is open and a slide has four or more visible video sources, the *small Program monitor only* stops redundant video decoding and displays labeled lightweight video placeholders instead. Audio controls, text/shape layout, audience video timing, and the audience output remain unaffected.
- The Program monitor explicitly displays “VIDEO PREVIEW REDUCED” while lightweight preview is in use, and Full Video restores the full-motion monitor if desired.
- Rationale: a slide with eight videos and Fullscreen + Windowed + Program could previously run up to 24 distinct AVPlayer decoders, increasing memory and compositor load. This mode lowers the redundant monitor load without reducing audience frame rates. It does not eliminate independent Fullscreen + Windowed decoders.
- Added tests for the high-load preview policy, with the existing output work/synchronization suite retained.
- **Caution:** When preview is reduced, its video areas are placeholders rather than live frames. This is an intentional operational tradeoff, selectable at any time. A shared frame compositor is a future enhancement.

## v0.4.6 — Peak meter display cadence fix

- Made filled stereo bars follow the **measured audio peaks**, not RMS average, so the peak-hold line rides the bar when new peaks occur. It holds briefly when the bar drops and decays back toward the current level.
- Replaced three independent fixed 60 Hz SwiftUI meter timers with native animation timelines. The OS schedules display updates to suit each window's display refresh (60, 120, 144 Hz when supported), without increasing decoded-audio polling or affecting video frame rate.
- All ballistic calculations are elapsed-time-based to remain consistent at different effective refresh rates or under frame drops; preserve the Pre/ Post fader routing and the Windowed Output optimizations.
- Added independent pure-Foundation tests of rising-peak alignment, hold/decay, clipping and display cadence at 60/120/144 Hz.
- Remaining occasional Program preview stalls under many video layers should be diagnosed as playback/compositing and memory pressure, not CPU-core affinity. Fullscreen audience output retains priority.

## v0.4.5 — Windowed-output workload and smooth-meter follow-up

- Correct output priority: Fullscreen > Windowed > silent Program monitor. When Windowed is the only audience output, it no longer chases the possibly delayed Program preview through repeated seeks.
- Reduced main-thread video end/loop observer frequency on non-primary surfaces (Fullscreen 30 Hz, Windowed 20 Hz, Program 10 Hz) while preserving AVPlayerLayer's native video frame presentation rate.
- Drift corrections run once per second rather than once per output window; lower-priority streams use a 3-second seek cooldown and larger tolerance to avoid seek thrashing under multi-video loads.
- Disabled unnecessary MediaToolbox PCM meter taps on silent Program preview players or video sources with audio disabled; disabled video audio tracks are excluded from playback when available.
- v0.4.4's true Pre/Post-fader audio meters, 60 Hz display smoothing, dBFS scales and muted-startup fix remain included.
- Added portable output-priority and metering-policy tests and macOS CI build validation.
- **Limit:** Each visible output still has independent AVPlayer video decoders. A shared frame compositor remains future work; benchmark high-layer-count shows on the target Mac before production.

## v0.4.4 — Fluid mixer redesign, Pre/Post routing, silent media startup

- Redesigned the mixer to clarify Pre on each cue and Post on Master; L/R stereo level columns include dBFS ticks (0, -6, -12, -24, -48), a labeled white peak-hold marker, and clear clipping text instead of the unexplained circle and vertical EST/dB text.
- Display refresh now follows a 60 Hz ballistic smoother with fast attack, slower release and 1.2 second peak hold, independent of the 20 Hz PCM poll cadence. Peak indicator placement uses a top-aligned, clamped coordinate system.
- Cue metering uses source PCM **before its cue fader**, while Master uses source + cue + Master gains. The Master is still a signal-derived estimate, not a device loopback.
- Prevented brief startup audio leaks when video/audio is disabled: retained video engines apply the new mute/zero-volume setting **before** reattaching/resuming; new media players start muted at volume zero.
- Added portable tests for pre/post gain staging, smoothing and peak geometry. Validate transitions/loop playback and media-audio-disabled with an actual macOS output before using in production.

## v0.4.3 — Live PCM Audio Meters (Alpha)
- Added live stereo RMS level bars, peak hold, and red peak/clip indicators alongside the Program and Master mixer faders. The Next meter remains idle until the next cue is taken on Program.
- Added per-player decoded-PCM observation with file-based AVAudioMix / MediaToolbox audio taps, including local audio and video media. Audio samples pass through the taps unchanged.
- Levels follow source PCM, cue gain, video fade envelopes, player mute and Master gain; idle/muted playback displays silence. An offline display scope is not used to meter Program.
- Master combines active players using a signal-derived estimate; **not a sample-synchronous physical-output measurement**, and does not monitor other macOS apps or hardware. See meter tooltip.
- Preserved independent player pools, per-surface audio ownership, Core Audio routing and program transition handling.
- Added a portable meter-math regression test and a macOS CI step. Requires hands-on testing with stereo audio, video/audio, looping playback and video crossfades.

# v0.4.2-alpha — Autosave and Crash Recovery

- New Foundation-based `RecoverySnapshotStore`: every five seconds while an edited show is dirty, store a separate atomic recovery JSON with two older generations. The original show file is never overwritten by autosave.
- New `RecoveryCoordinator`: prompts at startup to Recover, keep for Later, or discard the latest unsaved work. Recovery loads off-air and is deliberately marked unsaved until the user chooses Save/Save As.
- Show identity follows each new/opened document, including untitled shows; a deliberate Save, discard/replacement, or normal Quit clears only the active document's emergency drafts. Force Quit/crash bypasses that cleanup.
- The operator footer reports successful recovery saves and failures. Source media remains referenced at its original file paths; large media files are not copied every autosave.
- Added Foundation-only tests for rotation, corruption fallback, original-file integrity, distinct unsaved-show identities, and recovery cleanup. macOS CI builds the full app plus these regression tests.
- To simulate failure **only with a disposable test show**, wait for “Recovery saved” then Force Quit via macOS. Never test with an active event or client show on-air.

# v0.4.1 — Blind Editor Zoom and Text Outlines

- Added a bottom-left **Zoom** menu to the Blind layer editor with Zoom to Fill and 10%, 25%, 50%, 75%, 100%, 125%, 150%, 200%, and 400% presets. Zoom to Fill is the default and adjusts to the available editor area.
- Mouse wheel zooms while the pointer is over the canvas. Trackpad pinch zooms. Hold Shift while scrolling to pan an enlarged canvas; scrollbars are available too. Zoom is a **view-only** setting; layer coordinates, saved shows, and Program output do not change.
- Added **Text outline** color and **Outline width** controls in the text inspector. The default is black, 0 px (off), so existing shows look unchanged. Try 2–4 px black outlines around white text for contrast.
- Outlined text is drawn in the shared renderer (Preview, thumbnails, Program, external outputs). Width is in authored canvas pixels and scales along with text.
- Text outline settings are optional per-layer show metadata, compatible with the existing v6 show format and older v1–v5 migrated shows.
- Added a portable test for zoom scaling, input gestures and optional outline persistence, plus macOS CI build coverage.
- **Testing note:** Verify mouse-wheel interception and trackpad magnification with real macOS hardware; pure Swift tests do not exercise AppKit events.

# v0.4.0-alpha — Custom Presentation Canvases

- New Show (⌘N) opens a canvas setup sheet with HD/Full HD/4K, 9:16 portrait, square and ultrawide/LED presets, plus editable custom width and height (64–8192 pixels).
- Source canvas size and reduced aspect-ratio label are displayed in the operator status area.
- Presentation show format **v6** persists `canvasWidth` and `canvasHeight`. Older show formats 1–5 load at 1920×1080 without altering their normalized layer geometry; v6 saves preserve the new dimensions.
- Slide renderer, Program monitor, Blind layer editor, library thumbnails, output fit/fill and windowed audience output now use the authored canvas ratio rather than a fixed 16:9 reference.
- The layer X/Y/W/H inspector and the native-size media scaling commands are measured against the selected canvas. Circle/Square/Equilateral Triangle presets keep correct pixel geometry across aspect ratios.
- Canceling New Show leaves the existing document unchanged; Create checks for unsaved work before replacing it.
- Added `CanvasSizePersistence.swift` tests and a macOS GitHub Actions step for migration, presets and pixel geometry. No change to media output, audio session or transition algorithms beyond the canvas geometry inputs.
- **Planned, not in v0.4.0:** changing the dimensions of an existing show and applying scale/anchor migration. Use File → New Show to select a canvas size, then import/copy slides as appropriate.

# v0.3.2 — Media stretching and precise shape presets

- Images, animated GIFs, and videos now maintain resize proportions by default; hold Option (⌥) during any of the eight resize-handle drags to temporarily allow free X/Y stretching. Option-drag also selects Stretch media pixel mapping so the content visibly distorts rather than letterboxing.
- Added an explicit Media pixels option (Fit / Fill / Stretch) to image/video layer attributes, retaining existing right-click presets and the persistent Lock ratio toggle.
- Added Square, Circle and Equilateral Triangle as new shape types in Add Object and the Shape inspector. Their initial pixel geometry is mathematically constrained: 280×280 for squares/circles and 320×277.13 for equilateral triangles.
- Changing an existing object to one of the constrained shapes normalizes its pixel aspect ratio within canvas bounds. Constrained shapes lock aspect ratio by default but can be deliberately overridden with Option.
- Existing Rectangle, Ellipse, Triangle and rounded rectangle behavior is retained, and older show files remain compatible (new enum cases, no new required saved fields).
- Added pure tests for media lock/override behavior, shape proportions, and round-trip serialization. Full macOS Xcode build is verified by GitHub Actions after publishing.

# v0.3.1 — Visual Font Browser (Alpha)

- Replaced the native font Picker with a searchable floating font browser. Installed font families are displayed in their own typefaces, with an “Aa Bb 123” sample.
- Hovering over a font temporarily previews that typeface directly on the selected text layer on the Blind canvas. Leaving the font or dismissing the browser rolls the preview back immediately, without modifying the slide model or Program.
- Clicking a font commits it and registers one undo checkpoint. Switching slides or layers cancels a pending preview.
- Added a Foundation-only regression test to confirm the hover draft does not mutate or reserialize the authored slide.
- Preserved v0.3.0's eight resize handles and fixed the stale geometry-undo method calls from the initial v0.3.0 source ZIP, matching the latest GitHub main.

# v0.3.0-alpha — Advanced Layer Editor and Open Source Setup

- Added eight resize handles for visual layers (corners and edge midpoints), independent axis resizing for shapes/text/media, and optional aspect-ratio lock.
- Added exact X/Y/W/H pixel inputs for the current 1920×1080 authored canvas. X/Y are the top-left position; values are clamped inside the canvas.
- Geometry implementation is pure model code with portable regression tests; resize operations register a single undo checkpoint.
- Preserved compatible v5 show data by making aspect-ratio lock optional, defaulting to off.
- Prepared for GitHub with a clear README, contributing/security guidance, CI workflow, issue templates and `.gitignore`.
- The **GitHub repository is not created or published** by this source archive; the maintainer must create the empty repository and push this source.
- No rendering/audio/output changes. macOS runtime tests and Xcode build required before release is qualified.

# v0.2.34.1 — Layer Cut & Undo fix

- Enabled **Edit → Cut** for selected, unlocked layers in Blind mode. The native Edit command now calls the same editor Cut operation as `⌘X`; standard text selection Cut still uses macOS text editing.
- Cut serializes the selected unlocked layers to the system clipboard first. Only after a successful write does it remove them from the slide, preventing data loss if copying fails. Locked layers remain protected.
- Cutting multiple selected layers is one undoable operation (`⌘Z` or Edit → Undo); Redo restores the cut. Paste on a different slide preserves size, position, layer properties, and grouping.
- Renamed the existing paste-only history registration to a general layer-change checkpoint. No changes to Program, output windows, playback, menus outside of Cut, or show-file format.
- Validation: the clipboard layer-payload round-trip and six portable regression suites pass, along with Swift parsing and Xcode project-file validation; AppKit clipboard/menu functionality needs confirmation in Xcode on macOS.

# v0.2.34 — Output-fullscreen menu recovery

- Fixed the specific View-menu regression triggered by opening **Windowed Output** and taking that output window into native macOS full screen. The system could replace OpenPresentation's custom View submenu with the default **Show Tab Bar / Show All Tabs / Enter Full Screen** commands when the output became the key/main window. Menu repair now reacts to AppKit window key/main/fullscreen/close lifecycle notifications, not just application reactivation.
- Keep the original AppKit Edit/View submenu instances and reattach them when the application root menu changes. Reinstallation is deferred to the next main-actor turn so it does not rewrite the menu mid-window notification.
- Disable macOS tab grouping for the Windowed Output test window, while preserving its green-button full-screen capability.
- No changes to audio, video, slides, show-file version or the stable menu/clipboard actions introduced in v0.2.33.
- **Needs Mac verification:** Fullscreen/window focus and native menu tracking cannot be exercised on Linux. In Xcode, open Windowed Output, make it full screen using the green button, then inspect View both while fullscreen and after closing the output. Repeat with automatic slides.

# v0.2.33 — AppKit Edit/View menu routing and stability test

- Replaced the volatile SwiftUI-managed Edit and View submenus with stable native AppKit `NSMenu` instances. Their menu items have fixed identities, and native validation runs when the menu is opened rather than rebuilding the menu as Program changes.
- Fixed the mismatch between `⌘C` / `⌘V` and Edit → Copy / Paste: the Blind editor now registers explicit selected-layer actions with the menu coordinator. Copy and Paste in the menu use the same custom layer clipboard and preserve native text-field behavior.
- Edit → Undo / Redo / Select All / Delete Selected Layers are routed to the Blind editor when appropriate. Nonapplicable commands remain disabled in Live mode. Cut remains native text-only (layer Cut is not yet implemented).
- Replaced the View submenu with stable Live/Blind, Slide Icons/List, Windowed/Fullscreen Output and Operator Full Screen actions. Existing Presentation and File commands remain in place.
- No changes to saved-show format, compositor, audio/video players, or transition timing.
- **Verification limitation:** Native macOS menus cannot be compiled or interacted with in this environment. Confirm keyboard + menu actions and keep Edit/View open across multiple automatic slide transitions on the target Mac.

# v0.2.32 — Native menu stability follow-up

- Isolated the application's menu/scene ownership from `ShowController`'s frequent `@Published` slide-take updates. The operator workspace still observes the show normally, but the top-level SwiftUI `App` no longer observes Program changes and consequently should not recompose the native Edit and View menus every time Auto advances a slide.
- Kept the File → Open Recent submenu responsive to file changes via a narrowly observed submenu view, without restoring high-frequency menu invalidation.
- No changes to video/audio playback, background compositing, slide timing, canvas rendering, or the saved show-file schema (v5).
- **Status:** Portable Swift parser and project tests only; macOS runtime verification of both menus during automatic transitions is required. If the issue persists, capture a screen recording and note the macOS/Xcode versions and whether the menu is open when a slide changes.

# v0.2.31 — Background compositing and operator stability

- Transparent/empty slides clear the previous Program background by default. Added per-slide **Keep Previous Background** to explicitly retain the previous background color, image or video. The opt-in is serialized as optional metadata compatible with version-5 show files.
- Changed Dissolve to blend background and foreground passes separately, preventing mid-transition brightness dips between identical backgrounds and delayed snaps to black on transparent destinations. Continuous video backgrounds keep their existing specialized path.
- Removed the Blind slide-library green live dot.
- Improved the Auto Transition button: slide-in/fade-in countdown and a fade-out sweep tied to an automatic take's actual transition duration.
- Suppressed unintended Program text/layout animations during takes.
- Made Presentation menu labels stable and stopped Program-driven slide changes from unnecessarily clearing editor focus, aimed at preventing the disappearing View menu. Requires macOS runtime verification.
- Updated tests for transparent clearing, explicit retention and inherited background audio, while preserving media sessions and v5 compatibility.
- **Verification:** Swift syntax and portable model tests pass; no native macOS GUI/Xcode build was run here.

# v0.2.30 — Transparency, Staged Blind Edits and Loop Navigation

- Dimmed Program/Next audio mixer strips when no enabled audio media is present; retained Master and inherited background-audio awareness.
- Removed redundant Program audience-content and mixer cue-level captions.
- Aligned Slide Auto Time with the right-side transition-duration control, across from Global Auto Time.
- Prevented Blind layer selection decorations persisting into the Live-mode panel animation.
- Enabled whole-area clicking on transparent thumbnails in the Blind slide list.
- Added Blind slide clipboard Copy/Paste/Duplicate and confirmed Delete; copied slides preserve notes, background, timing, collection and layer settings while regenerating unique IDs.
- Added bounded document undo/redo for layer pastes (including pasted images/text) and slide paste/duplicate/delete, with editor buttons and keyboard shortcuts while the editor is focused.

- Fixed re-taking an edited slide: Program transitions from the previous on-air snapshot into the staged revision instead of snapping immediately. Unchanged retakes remain seamless, and shared video sessions are preserved.
- Dissolves fade out outgoing foreground alongside incoming content, preventing stale text from popping away at the end of a transparent transition.

- Transparent slide takes inherit the currently live Program color/image/video background without changing saved slide transparency.
- Editor and library thumbnails display transparent slides on a checkerboard; black slides remain black.
- Full Program transition frames are backed with black when needed, avoiding abrupt foreground popping. Shared video backgrounds keep their decoder session during subsequent transparent takes.
- Blind mode freezes the Program navigation sequence until Live mode is restored; editing in Blind no longer changes upcoming Program takes.
- Previous/Next respect Loop Collection at both ends. One-slide collections do not restart identical media.
- Switching editor slides closes the macOS background Color Picker panel.
- Next arrow placed after its label; slide-to-slide morphing removed from video transport UI.
- Requested native font Picker labels render in their own font families where macOS honors custom menu styling.
- Added `ROADMAP.md` with planned non-destructive font hover preview, eight-point free resizing, exact layer pixel dimensions, and custom canvas sizes / new-show presets. These larger editing features are **not part of v0.2.30**.
- PresentationShow remains v5. Not a fully Xcode-compiled or macOS-runtime-verified release.

# v0.2.29 — Inspector, Transport and Blind Editor Cleanup

- Removed audio gain and mute controls from the Program video transport in both Live and Blind. Program transport now only handles video source selection, play/pause and seeking. Per-video audio enable/gain remains in the video layer inspector and Background Video Settings; per-slide/mix audio controls remain in the Audio Mixer.
- Removed the redundant full-page ScrollView from the Blind slide editor and sized its canvas to the space available, eliminating the artificial outer scrollbar. The independent Layers inspector remains scrollable when there are more layers or attributes than fit on screen.
- Removed the Opacity control for audio-only layers. Group Opacity operates only on visual layers in mixed groups; audio-layer volumes remain independent.
- Reduced the fixed Program transport footprint to give the 16:9 preview more space. No changes to the audio/video decoding engine, output routing or show format.

# v0.2.28 — Program, Transition and Blind Inspector Polish

- In **Live mode only**, moved Previous and Next into a full-width top row, with Clear Slide and Blackout directly below. Blind mode retains its compact single-row controls.
- Removed the redundant inner gray Transition background, leaving one uniform dark card surface consistent with the other operator panels.
- Moved Slide Notes and background color, HEX, transparency, image import and video background controls to a fixed location on the right side of Blind's editor. The long layer-attributes list scrolls independently. Background video playback controls open in a popover.
- Reclaimed Blind Program preview space by removing the empty transport reserve on slides without video, compacting active video transport into two rows, and hiding redundant status text in the smaller Blind Program panel.
- No changes to slide data, underlying AVFoundation playback, transition timing, saved-show format, or audio routing.

# v0.2.27 — Program Controls & Canvas Polish

- Centered the Live and Blind resize handles in a 20pt reserved gap between panels.
- Expanded and compacted Program video transport to prevent its content overflowing into a scrollbar.
- Aligned Global and Slide Auto Time menus side by side.
- Moved Previous, Next, Clear Slide, and Blackout inside Program in both modes.
- Replaced native Blackout button tint with inactive-window-safe red/green backgrounds, animated between states.
- Removed audio-only objects from the visual canvas while preserving their Layers-list management and playback.
- Retained existing playback, document schema, and Live/Blind editing protection.

## v0.2.26 — November 8, 2026
- Moved global transition duration to the right of the effect selector on the same row.
- Maximized Program preview within a responsive 16:9 viewport without disturbing reserved transport space.
- Relocated Live Previous/Next under Program and above the Slides section.
- Matched Notes/Transition column height to adjacent Live control panels and filled the Blind Transition slot.
- Matched the Blind Audio Mixer to the neutral gray live Program surface and removed the shield icon.
- Added dedicated Previous/Next Program-take controls to Blind Program; removed redundant Blind footer navigation.
- Decoupled Blind editing selection from automatic Program takes and manual Program navigation.
- Kept existing media engine, saved-show schema v5, and automatic playback timing.

## v0.2.25 — November 8, 2026

- Centered Auto Transition and Loop Collection buttons, aligned them above timing selectors, and switched enabled/disabled appearances to contrasting neutral grays.
- Placed global Transition Time and Auto Time menus side by side while preserving slide-specific overrides.
- Extended the Program card's gray background to the entire allotted panel height.
- Removed splitter lines and kept only a centered draggable grab handle, retaining drag bounds and saved layout sizes.
- Unified Live Slides header, view mode, count, and the slide list/grid inside one shared gray container.
- No change to v5 show-file structure or to the playback and output engines.

## v0.2.24 — November 8, 2026

- Mixer faders stretch vertically with mute controls anchored at the bottom; matched cue identity animates Next-to-Program movement, and Blind mode shows a gray live-audio warning.
- Swapped Collections and Audio Mixer positions; placed Live Notes above Transition in a split column, moved Blind Notes below layer attributes, and gave Slides a gray heading card.
- Reserved Program/video-transport height and clamped Live's splitter position to the same limits used by the layout.
- Added slide gain/mute controls within the Program video transport, and changed the Notes expansion icon to an edit symbol.
- Added saved global Auto Transition timing presets + custom time, per-slide timing overrides, and a button-style Loop Collection control.
- Kept Auto running while editing in Blind mode; moved its status/countdown button into Blind Program rather than its Transition controls.
- Preserved Live/Blind mode on opening show files; app starts with a blank show. Added New Blank Show and unsaved-change confirmation for Quit/show replacement.
- v5 JSON format retained with optional `globalAutoAdvanceSeconds` key; no conversion required for existing shows.

## v0.2.23 — Operator Workspace, Auto Transition and Escape Clear

- Fixed-label Auto Transition button with active/inactive styling and a countdown sweep.
- Automatic playback now continues onto untimed slides (10-second fallback) and loops through the selected collection if enabled.
- Mixer cue strips move and fade between Program/Next slide labels; Master moved right of a divider.
- Collections moved to an independent scrollable card with highlighted current selection.
- Slide notes moved to their own card underneath Program.
- Transition, Audio Mixer and Collections panels stretch to the slide-grid boundary. Added draggable, persisted vertical split heights for Live and Blind modes.
- Escape performs Clear Slide while an audience output is open, without closing the output. Repeated Escape does not restore the slide.
- Kept show JSON at format version 5 and the existing media/transition engines intact.

## v0.2.22.1 — November 8, 2026
- Fixed Xcode compiler error in `SlideCanvas.swift`: `cueAudioGainOverride` must precede `continuingVideoPaths` in the `SlideCanvas` initializer. No behavior changes.

# OpenPresentation Changelog

## v0.2.22 — Per-Slide Audio Cue Mixing and Timed Transitions

- Replaced horizontal audio controls with vertical Master, Program and Next faders, mute buttons beneath each strip, and dynamic slide-title labels.
- Persisted cue gain/mute per slide, eliminating the global Next-to-Program gain copy that could amplify outgoing audio before its transition.
- Added gain interpolation for continuous shared-background video between slides.
- Added saved show-level global transition duration, preset selector and custom seconds input.
- Added right-click transition-duration override per slide in all slide views, with default/presets/custom options.
- Replaced the Auto checkbox with an opt-in button and elapsed-dwell progress sweep plus remaining-time indicator.
- Maintained v5 JSON backward compatibility and added regression tests for cue audio, durations and older shows.

**Alpha:** macOS build, drag interactions, and media timing still require real-device testing.

## v0.2.20 — Keyboard Editing, Seamless Re-Take, Support Links

- Delete/Forward Delete selected layers from Blind editor; keep locked layers safe.
- Standard copy/paste of slide layers across slides using ⌘C / ⌘V and right-click Paste.
- Paste external images and plain text as independent slide layers.
- Remove redundant visible Paste controls.
- Retake the currently live slide without a new fade/restart.
- Preserve consecutive shared video backgrounds at full opacity during slide-content dissolves.
- Keep active output toggles green even if the operator window is not active.
- Stabilize the top Live/Blind selector; move Blind status badge to the bottom status bar.
- Add Help → About OpenPresentation & Support including HiTech Productions contact, website, socials, open-source/license, alpha, and no-warranty statements.
- Preserve existing v5 show-file schema.

All features in this alpha release require verification in a macOS Xcode build.

## v0.2.21 — Collections, auto advance, media import and audio faders

- Fixed output toggle hit areas.
- Layer clipboard now preserves exact position, dimensions and properties without offset.
- Added per-slide timed dwell, opt-in automatic take and collection-scoped looping.
- Added named collections and right-click slide assignment; saved in the v5 show JSON with backward-compatible optional metadata.
- Combined image, video and audio import under Add Media… with supported-format filtering.
- Added basic Master/Program/Next cue gain and mute faders. True live PCM metering is deferred.
- Reduced unnecessary transport-layout animations and added small image-decode caching.
- No deliberate changes to the existing AVFoundation playback-session lifecycle.
