import AppKit
import SwiftUI

/// Stable owner for presentation state. The app scene and its macOS menus
/// must not observe every Program transition: recreating command views while
/// an NSMenu is being tracked can dismiss the View menu or change enabled
/// Edit items. OperatorView, not the App scene, observes ShowController.
@MainActor
private final class OpenPresentationSession {
    let show = ShowController()
    let output = OutputManager()
    let fileActions = ShowFileActions()
    let recovery: RecoveryCoordinator

    init() {
        let recovery = RecoveryCoordinator(show: show)
        self.recovery = recovery
        fileActions.onSuccessfulSave = { [weak recovery] in recovery?.didSave() }
        fileActions.onWillReplaceShow = { [weak recovery] in recovery?.willReplaceShow() }
    }
}

@main
@MainActor
struct OpenPresentationApp: App {
    @NSApplicationDelegateAdaptor(OpenPresentationTerminationDelegate.self) private var terminationDelegate
    @State private var session = OpenPresentationSession()
    @State private var presentingHelp = false
    @State private var presentingNewShow = false

    var body: some Scene {
        WindowGroup("OpenPresentation") {
            OperatorView(show: session.show, output: session.output, fileActions: session.fileActions,
                         recovery: session.recovery)
                .frame(minWidth: 1060, minHeight: 730)
                .onAppear {
                    terminationDelegate.show = session.show
                    terminationDelegate.fileActions = session.fileActions
                    terminationDelegate.recovery = session.recovery
                    // Install a stable native Edit/View menu once the operator
                    // window has appeared. Menu actions read state on demand;
                    // Program frame updates never rebuild these NSMenus.
                    OpenPresentationNativeMenus.shared.attach(show: session.show, output: session.output)
                    DispatchQueue.main.async {
                        OpenPresentationNativeMenus.shared.installIfNeeded()
                        session.recovery.startIfNeeded()
                    }
                }
                .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
                    session.recovery.autosaveIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                    session.recovery.autosaveIfNeeded()
                }
                .sheet(isPresented: $presentingHelp) {
                    OpenPresentationHelpView()
                }
                .sheet(isPresented: $presentingNewShow) {
                    NewShowCanvasSetup(onCreate: { name, canvas in
                        // Do not destroy the existing show if saving is
                        // cancelled. Confirm only after the new setup is ready.
                        guard session.fileActions.confirmMayReplaceCurrentShow(session.show) else { return }
                        session.recovery.willReplaceShow()
                        session.show.newBlankShow(canvasSize: canvas, title: name)
                        presentingNewShow = false
                    }, onCancel: { presentingNewShow = false })
                }
        }
        .commands {
            // Places Open/Save in the standard macOS File menu, not in a
            // separate application toolbar or custom menu.
            CommandGroup(replacing: .newItem) {
                Button("New Show…") { presentingNewShow = true }
                    .keyboardShortcut("n", modifiers: .command)
                Divider()
                Button("Open Show…") { session.fileActions.openShow(into: session.show) }
                    .keyboardShortcut("o", modifiers: .command)
                // Only the recent-file submenu observes file changes. The
                // scene's other menus never observe Program-frame updates.
                Menu("Open Recent") {
                    RecentShowCommands(fileActions: session.fileActions, show: session.show)
                }
                Divider()
                Button("Save Show") { session.fileActions.saveShow(from: session.show) }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save Show As…") { session.fileActions.saveShowAs(from: session.show) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("About OpenPresentation & Support…") { presentingHelp = true }
                Divider()
                Button("Email Feature Suggestions") {
                    NSWorkspace.shared.open(URL(string: "mailto:william.hymes@hitechproductions.com?subject=OpenPresentation%20Feedback")!)
                }
                Button("HiTech Productions Website") {
                    NSWorkspace.shared.open(URL(string: "https://www.hitechproductions.com/")!)
                }
            }
            CommandMenu("Presentation") {
                Button("Toggle Live / Blind Mode") {
                    session.show.mode = session.show.mode == .blind ? .live : .blind
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Next Slide") { session.show.advance(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous Slide") { session.show.advance(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Divider()
                Button("Toggle Blackout") { session.show.toggleBlackout() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Toggle Clear") { session.show.toggleClear() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                Button("Toggle Windowed Output") {
                    session.output.toggleWindowed(controller: session.show)
                }
                Button("Toggle Fullscreen Output") {
                    session.output.toggleFullscreen(controller: session.show)
                }
            }
        }

        // A Settings scene automatically creates OpenPresentation > Settings…
        // (Command-,) in the macOS application menu.
        Settings {
            AppSettingsView(output: session.output)
        }
    }
}

/// New-show dimensions are chosen before replacing the active document.
/// The editor, Program, and saved show all use the same canvas selection.
@MainActor
private struct NewShowCanvasSetup: View {
    let onCreate: (String, ShowCanvasSize) -> Void
    let onCancel: () -> Void
    @State private var title = "Untitled Show"
    @State private var preset: ShowCanvasPreset = .fullHD
    @State private var pixelWidth = 1920
    @State private var pixelHeight = 1080

    private var valid: Bool {
        (ShowCanvasSize.minimum...ShowCanvasSize.maximum).contains(pixelWidth) &&
        (ShowCanvasSize.minimum...ShowCanvasSize.maximum).contains(pixelHeight)
    }
    private var previewRatio: Double {
        Double(max(1, pixelWidth)) / Double(max(1, pixelHeight))
    }
    private var previewWidth: CGFloat { min(240, 148 * previewRatio) }
    private var previewHeight: CGFloat { previewWidth / previewRatio }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("New Presentation", systemImage: "rectangle.on.rectangle")
                .font(.title3.bold())
            Text("Choose the source canvas for this show. Preview, Program, and audience output will share its aspect ratio.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Show title", text: $title)
                .textFieldStyle(.roundedBorder)
            Picker("Canvas preset", selection: $preset) {
                ForEach(ShowCanvasPreset.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .onChange(of: preset) { _, selected in
                if let size = selected.size {
                    pixelWidth = size.width
                    pixelHeight = size.height
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Width (px)").font(.caption).foregroundStyle(.secondary)
                    TextField("Width", value: Binding(
                        get: { pixelWidth },
                        set: { pixelWidth = $0; preset = .custom }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Canvas width in pixels")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Height (px)").font(.caption).foregroundStyle(.secondary)
                    TextField("Height", value: Binding(
                        get: { pixelHeight },
                        set: { pixelHeight = $0; preset = .custom }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Canvas height in pixels")
                }
            }
            if !valid {
                Text("Each dimension must be 64–8192 pixels.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            VStack(spacing: 10) {
                ZStack {
                    Color.gray.opacity(0.11)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(red: 0.10, green: 0.16, blue: 0.28))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 2)
                        }
                        .frame(width: previewWidth, height: min(previewHeight, 148))
                }
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(valid ? ShowCanvasSize(width: pixelWidth, height: pixelHeight).sizeLabel +
                     "  ·  " + ShowCanvasSize(width: pixelWidth, height: pixelHeight).ratioLabel
                     : "Enter a valid canvas size")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create Show") {
                    guard valid else { return }
                    onCreate(title, ShowCanvasSize(width: pixelWidth, height: pixelHeight))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(22)
        .frame(width: 490)
    }
}

/// Rebuild this *submenu* only when recent files change, never on slide
/// takes. This preserves the useful dynamic Recent list without making the
/// parent macOS Edit / View menu tree dependent on the Program clock.
private struct RecentShowCommands: View {
    @ObservedObject var fileActions: ShowFileActions
    let show: ShowController

    var body: some View {
        if fileActions.recentShows.isEmpty {
            Text("No Recent Shows")
        } else {
            ForEach(fileActions.recentShows, id: \.self) { url in
                Button(url.lastPathComponent) { fileActions.openShow(at: url, into: show) }
                    .help(url.path)
            }
            Divider()
            Button("Clear Menu") { fileActions.clearRecent() }
        }
    }
}

/// Actions supplied by the currently mounted Blind layer editor. They do not
/// publish SwiftUI updates and are queried only when the native Edit menu opens.
@MainActor
struct LayerEditorMenuActions {
    let hasSelection: () -> Bool
    let canCut: () -> Bool
    let cut: () -> Void
    let copy: () -> Void
    let paste: () -> Bool
    let selectAll: () -> Void
    let deleteSelection: () -> Void
}

/// Stable AppKit menus, independent of the show clock and SwiftUI's dynamic
/// first-responder command reconstruction. In v0.2.32 the standard Edit menu
/// was not connected to the layer clipboard (only the key monitor was); the
/// SwiftUI-generated View menu also stopped tracking during automatic takes.
/// Both menus are now built once, with stable item identities and explicit
/// validation at the moment a menu opens, not on each Program state change.
@MainActor
final class OpenPresentationNativeMenus: NSObject, NSMenuItemValidation, NSMenuDelegate {
    static let shared = OpenPresentationNativeMenus()

    private weak var show: ShowController?
    private weak var output: OutputManager?
    private var editorActions: LayerEditorMenuActions?
    private var editorOwner: UUID?
    private var installedEditMenu: NSMenu?
    private var installedViewMenu: NSMenu?
    // Native fullscreen windows can become the key/main window without the
    // application deactivating. AppKit/SwiftUI may then install the stock View
    // submenu (Show Tab Bar / Enter Full Screen) in place of ours. Observe
    // window ownership changes rather than observing slide frame updates.
    private var windowMenuObservers: [NSObjectProtocol] = []

    // Stable item tags, used by both AppKit validation and menu-state display.
    private enum Tag {
        static let undo = 6101, redo = 6102, cut = 6103, copy = 6104
        static let paste = 6105, delete = 6106, selectAll = 6107
        static let live = 6201, blind = 6202, icons = 6203, list = 6204
        static let windowed = 6205, fullscreen = 6206, operatorFullscreen = 6207
    }

    func attach(show: ShowController, output: OutputManager) {
        self.show = show
        self.output = output
        observeWindowMenuChangesIfNeeded()
    }

    private func observeWindowMenuChangesIfNeeded() {
        guard windowMenuObservers.isEmpty else { return }
        // Keep these event-driven. Reinstalling menus on each Program frame
        // would reintroduce the menu-tracking bug fixed in earlier builds.
        let events: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.willCloseNotification
        ]
        for name in events {
            let observer = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                // Defer until AppKit has finished its window/menu ownership
                // change; never mutate the menu tree mid-notification.
                Task { @MainActor [weak self] in
                    self?.installIfNeeded()
                }
            }
            windowMenuObservers.append(observer)
        }
    }

    func registerEditor(owner: UUID, actions: LayerEditorMenuActions) {
        editorOwner = owner
        editorActions = actions
    }

    func unregisterEditor(owner: UUID) {
        guard editorOwner == owner else { return }
        editorOwner = nil
        editorActions = nil
    }

    /// Only reattach on startup, app activation or window/fullscreen changes.
    /// Keep stable menu instances even if AppKit reconstructs the root menu.
    /// This intentionally does not observe the slide playback clock.
    func installIfNeeded() {
        guard let root = NSApp.mainMenu else { return }
        if let edit = root.items.first(where: { $0.title == "Edit" }),
           edit.submenu !== installedEditMenu {
            let menu = installedEditMenu ?? makeEditMenu()
            edit.submenu = menu
            installedEditMenu = menu
        }
        if let view = root.items.first(where: { $0.title == "View" }),
           view.submenu !== installedViewMenu {
            let menu = installedViewMenu ?? makeViewMenu()
            view.submenu = menu
            installedViewMenu = menu
        }
    }

    private func item(_ title: String, tag: Int, action: Selector,
                      key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: key)
        result.tag = tag
        result.target = self
        if !key.isEmpty { result.keyEquivalentModifierMask = modifiers }
        return result
    }

    private func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.autoenablesItems = true
        menu.delegate = self
        menu.addItem(item("Undo", tag: Tag.undo, action: #selector(undoEdit(_:)), key: "z"))
        menu.addItem(item("Redo", tag: Tag.redo, action: #selector(redoEdit(_:)), key: "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", tag: Tag.cut, action: #selector(cutEdit(_:)), key: "x"))
        menu.addItem(item("Copy", tag: Tag.copy, action: #selector(copyEdit(_:)), key: "c"))
        menu.addItem(item("Paste", tag: Tag.paste, action: #selector(pasteEdit(_:)), key: "v"))
        menu.addItem(item("Delete Selected Layers", tag: Tag.delete, action: #selector(deleteLayers(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Select All", tag: Tag.selectAll, action: #selector(selectAllEdit(_:)), key: "a"))
        return menu
    }

    private func makeViewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.autoenablesItems = true
        menu.delegate = self
        menu.addItem(item("Live Mode", tag: Tag.live, action: #selector(switchLive(_:))))
        menu.addItem(item("Blind Mode", tag: Tag.blind, action: #selector(switchBlind(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Slides as Icons", tag: Tag.icons, action: #selector(showSlideIcons(_:))))
        menu.addItem(item("Slides as List", tag: Tag.list, action: #selector(showSlideList(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Windowed Output", tag: Tag.windowed, action: #selector(toggleWindowed(_:))))
        menu.addItem(item("Fullscreen Output", tag: Tag.fullscreen, action: #selector(toggleFullscreen(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Toggle Operator Full Screen", tag: Tag.operatorFullscreen,
                          action: #selector(toggleOperatorFullscreen(_:)), key: "f", modifiers: [.control, .command]))
        return menu
    }

    private var textEditor: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    private var canEditLayers: Bool {
        show?.mode == .blind && editorActions != nil
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let text = textEditor
        let textSelected = (text?.selectedRange().length ?? 0) > 0
        switch menuItem.tag {
        case Tag.undo:
            if let text { return text.undoManager?.canUndo ?? false }
            return canEditLayers && (show?.canUndoSlideEdit ?? false)
        case Tag.redo:
            if let text { return text.undoManager?.canRedo ?? false }
            return canEditLayers && (show?.canRedoSlideEdit ?? false)
        case Tag.cut:
            if text != nil { return textSelected }
            return canEditLayers && (editorActions?.canCut() ?? false)
        case Tag.copy:
            if text != nil { return textSelected }
            return canEditLayers && (editorActions?.hasSelection() ?? false)
        case Tag.paste: return (text != nil || canEditLayers) && !NSPasteboard.general.types.orEmpty.isEmpty
        case Tag.delete: return canEditLayers && (editorActions?.hasSelection() ?? false)
        case Tag.selectAll: return text != nil || canEditLayers
        case Tag.fullscreen: return (output?.isFullscreenOpen ?? false) || output?.selectedScreen != nil
        default: return true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Check marks change only when a menu is *opened*, never while the
        // compositor is delivering automatic takes.
        guard menu === installedViewMenu else { return }
        let isBlind = show?.mode == .blind
        let icons = UserDefaults.standard.string(forKey: "liveSlideViewMode") != "list"
        for option in menu.items {
            switch option.tag {
            case Tag.live: option.state = isBlind ? .off : .on
            case Tag.blind: option.state = isBlind ? .on : .off
            case Tag.icons: option.state = icons ? .on : .off
            case Tag.list: option.state = icons ? .off : .on
            case Tag.windowed: option.state = output?.isWindowedOpen == true ? .on : .off
            case Tag.fullscreen: option.state = output?.isFullscreenOpen == true ? .on : .off
            default: break
            }
        }
    }

    @objc private func undoEdit(_ sender: Any?) {
        if let textEditor { textEditor.undoManager?.undo() }
        else if canEditLayers { show?.undoSlideEdit() }
    }
    @objc private func redoEdit(_ sender: Any?) {
        if let textEditor { textEditor.undoManager?.redo() }
        else if canEditLayers { show?.redoSlideEdit() }
    }
    @objc private func cutEdit(_ sender: Any?) {
        if let textEditor { textEditor.cut(sender) }
        else if canEditLayers && (editorActions?.canCut() ?? false) { editorActions?.cut() }
    }
    @objc private func copyEdit(_ sender: Any?) {
        if let textEditor { textEditor.copy(sender) }
        else if canEditLayers { editorActions?.copy() }
    }
    @objc private func pasteEdit(_ sender: Any?) {
        if let textEditor { textEditor.paste(sender) }
        else if canEditLayers { _ = editorActions?.paste() }
    }
    @objc private func deleteLayers(_ sender: Any?) {
        if canEditLayers { editorActions?.deleteSelection() }
    }
    @objc private func selectAllEdit(_ sender: Any?) {
        if let textEditor { textEditor.selectAll(sender) }
        else if canEditLayers { editorActions?.selectAll() }
    }
    @objc private func switchLive(_ sender: Any?) { show?.mode = .live }
    @objc private func switchBlind(_ sender: Any?) { show?.mode = .blind }
    @objc private func showSlideIcons(_ sender: Any?) { UserDefaults.standard.set("icons", forKey: "liveSlideViewMode") }
    @objc private func showSlideList(_ sender: Any?) { UserDefaults.standard.set("list", forKey: "liveSlideViewMode") }
    @objc private func toggleWindowed(_ sender: Any?) {
        if let show, let output { output.toggleWindowed(controller: show) }
    }
    @objc private func toggleFullscreen(_ sender: Any?) {
        if let show, let output { output.toggleFullscreen(controller: show) }
    }
    @objc private func toggleOperatorFullscreen(_ sender: Any?) {
        NSApp.keyWindow?.toggleFullScreen(sender)
    }
}

private extension Optional where Wrapped == [NSPasteboard.PasteboardType] {
    var orEmpty: [NSPasteboard.PasteboardType] { self ?? [] }
}

/// Appearance for Live mode only. Blind always keeps its navy theme.
/// The persisted key belongs to the app rather than to individual show files.
enum LiveAppearance: String, CaseIterable, Identifiable {
    case system = "Follow System"
    case dark = "Dark"
    case light = "Light"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

private struct AppSettingsView: View {
    @ObservedObject var output: OutputManager

    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            OutputSettingsView(output: output)
                .tabItem { Label("Output", systemImage: "display") }
            AudioSettingsView()
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
        }
        .padding(12)
        .frame(width: 490, height: 320)
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage("liveAppearance") private var liveAppearance = LiveAppearance.system.rawValue

    var body: some View {
        Form {
            Picker("Live mode appearance", selection: $liveAppearance) {
                ForEach(LiveAppearance.allCases) { appearance in
                    Text(appearance.rawValue).tag(appearance.rawValue)
                }
            }
            .pickerStyle(.radioGroup)

            Text("Follow System tracks the appearance set in macOS. " +
                 "Blind always uses the navy theme so off-air editing is easy to recognize.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
    }
}

private struct OutputSettingsView: View {
    @ObservedObject var output: OutputManager

    var body: some View {
        Form {
            Picker("Audience display", selection: $output.selectedDisplayID) {
                if output.displays.isEmpty {
                    Text("No displays detected").tag(UInt32(0))
                } else {
                    ForEach(output.displays) { screen in
                        Text(screen.name + (screen.isPrimary ? " (Main)" : ""))
                            .tag(screen.id)
                    }
                }
            }
            .disabled(output.displays.isEmpty)

            Picker("Scaling", selection: $output.scaleMode) {
                ForEach(OutputScaleMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            Text("Fit shows the entire authored canvas with letterboxing when needed. " +
                 "Fill crops the slide to cover the selected display.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if output.isFullscreenOpen {
                Text("To change the fullscreen display, toggle Fullscreen Output off and back on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .onAppear { output.refreshScreens() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            output.refreshScreens()
        }
    }
}


/// This changes only OpenPresentation's AVFoundation playback route; it does
/// not modify the Mac's global Sound Output setting.
private struct AudioSettingsView: View {
    @AppStorage(AudioOutputRouting.preferenceKey) private var selectedUID = ""
    @State private var devices: [AudioOutputDevice] = []

    private var isMissing: Bool {
        !selectedUID.isEmpty && !devices.contains(where: { $0.id == selectedUID })
    }

    var body: some View {
        Form {
            Picker("Audio output", selection: $selectedUID) {
                Text("System Default").tag("")
                ForEach(devices) { device in
                    Text(device.name).tag(device.id)
                }
                if isMissing {
                    Text("Unavailable device (using System Default)").tag(selectedUID)
                }
            }
            HStack {
                Button("Refresh Devices") { refresh() }
                Spacer()
                Text("\(devices.count) outputs detected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isMissing {
                Label("The saved audio device is disconnected. Audio falls back to System Default.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            Text("Video audio routes only from the active audience output. The Program monitor stays muted. Changing devices during playback may cause a brief interruption.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .onAppear { refresh() }
        .onChange(of: selectedUID) { _, _ in
            VideoPlaybackPool.shared.refreshAudioRouting()
        AudioPlaybackPool.shared.refreshAudioRouting()
        }
    }

    private func refresh() {
        devices = AudioOutputRouting.availableDevices()
        VideoPlaybackPool.shared.refreshAudioRouting()
        AudioPlaybackPool.shared.refreshAudioRouting()
    }
}


/// Shown from macOS Help, never on the projected output.
private struct OpenPresentationHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.largeTitle).foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("OpenPresentation").font(.title2.bold())
                    Text("Alpha software · Open source · Apache License 2.0")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Divider()
            Text("Developed by HiTech Productions")
                .font(.headline)
            Text("OpenPresentation is experimental alpha software, provided AS IS without warranty. It has not been validated for show-critical use. Source code is available under the Apache License 2.0.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Feature suggestions or support:").font(.subheadline.bold())
            Link("william.hymes@hitechproductions.com", destination: URL(string: "mailto:william.hymes@hitechproductions.com")!)
            Divider()
            HStack(spacing: 18) {
                Link("Website", destination: URL(string: "https://www.hitechproductions.com/")!)
                Link("Facebook", destination: URL(string: "https://www.facebook.com/HiTechProductionsTX/")!)
                Link("Instagram", destination: URL(string: "https://www.instagram.com/hitechproductions/")!)
                Link("LinkedIn", destination: URL(string: "https://www.linkedin.com/company/hitech-productions")!)
            }
            .font(.callout)
        }
        .padding(24)
        .frame(width: 610)
    }
}


/// Native Quit confirmation. SwiftUI owns the windows; closing the final
/// window terminates the application and therefore passes through this guard.
@MainActor
final class OpenPresentationTerminationDelegate: NSObject, NSApplicationDelegate {
    weak var show: ShowController?
    weak var fileActions: ShowFileActions?
    weak var recovery: RecoveryCoordinator?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The application menu may be built after WindowGroup first appears.
        // Recheck only on app activation, never during a Program transition.
        OpenPresentationNativeMenus.shared.installIfNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let show, show.hasUnsavedChanges else {
            recovery?.willTerminateNormally()
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Save changes before quitting OpenPresentation?"
        alert.informativeText = "Unsaved edits to \(show.title) will be lost if you don't save."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard fileActions?.saveShow(from: show) == true else { return .terminateCancel }
            recovery?.willTerminateNormally()
            return .terminateNow
        case .alertThirdButtonReturn:
            recovery?.willTerminateNormally()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
