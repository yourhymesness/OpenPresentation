import AppKit
import Combine
import SwiftUI

struct AudienceDisplay: Identifiable, Equatable {
    let id: UInt32
    let name: String
    let isPrimary: Bool
}

/// Windowed and fullscreen outputs are independent windows, both observing the
/// same immutable Program snapshot / transition timeline.
@MainActor
final class OutputManager: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isWindowedOpen = false
    @Published private(set) var isFullscreenOpen = false
    var isOpen: Bool { isWindowedOpen || isFullscreenOpen }

    @Published var scaleMode: OutputScaleMode = OutputScaleMode(
        rawValue: UserDefaults.standard.string(forKey: "outputScaleMode") ?? "Fit"
    ) ?? .fit {
        didSet { UserDefaults.standard.set(scaleMode.rawValue, forKey: "outputScaleMode") }
    }
    @Published var selectedDisplayID: UInt32 = UInt32(
        UserDefaults.standard.integer(forKey: "selectedOutputDisplayID")
    ) {
        didSet { UserDefaults.standard.set(Int(selectedDisplayID), forKey: "selectedOutputDisplayID") }
    }
    @Published private(set) var displays: [AudienceDisplay] = []
    private var screensByID: [UInt32: NSScreen] = [:]
    private var windowed: NSWindow?
    private var fullscreen: NSWindow?
    private var escapeKeyMonitor: Any?

    var selectedScreen: NSScreen? { screensByID[selectedDisplayID] }

    func refreshScreens() {
        var screens: [UInt32: NSScreen] = [:]
        var values: [AudienceDisplay] = []
        for (index, screen) in NSScreen.screens.enumerated() {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            screens[id] = screen
            values.append(AudienceDisplay(id: id, name: screen.localizedName, isPrimary: index == 0))
        }
        screensByID = screens
        displays = values
        if !values.isEmpty && screens[selectedDisplayID] == nil {
            selectedDisplayID = (values.first(where: { !$0.isPrimary }) ?? values[0]).id
        }
        // If an external display vanishes, close its stale presentation window.
        if let fullScreen = fullscreen,
           fullScreen.screen == nil || (fullScreen.screen.flatMap {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
           }).map({ screens[$0] == nil }) == true {
            closeFullscreen()
        }
    }

    func toggleFullscreen(controller: ShowController) {
        if isFullscreenOpen { closeFullscreen() }
        else { openSelectedFullScreen(controller: controller) }
    }

    func toggleWindowed(controller: ShowController) {
        if isWindowedOpen { closeWindowed() }
        else { openTestWindow(controller: controller) }
    }

    func openSelectedFullScreen(controller: ShowController) {
        refreshScreens()
        guard let screen = selectedScreen else { return }
        openFullScreen(on: screen, controller: controller)
    }

    func openFullScreen(on screen: NSScreen, controller: ShowController) {
        closeFullscreen()
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: true)
        window.level = .screenSaver
        window.backgroundColor = .black
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: AudienceOutputView(
            controller: controller, output: self, scope: "fullscreen"))
        window.delegate = self
        fullscreen = window
        isFullscreenOpen = true
        window.orderFrontRegardless()
        installEscapeClearMonitor(controller: controller)
    }

    func openTestWindow(controller: ShowController) {
        closeWindowed()
        let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 960, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Audience Output — Windowed"
        // Audience windows should never become macOS document tabs. Native
        // window fullscreen remains available through the green titlebar button.
        window.tabbingMode = .disallowed
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.backgroundColor = .black
        window.contentView = NSHostingView(rootView: AudienceOutputView(
            controller: controller, output: self, scope: "windowed"))
        window.delegate = self
        windowed = window
        isWindowedOpen = true
        installEscapeClearMonitor(controller: controller)
        window.makeKeyAndOrderFront(nil)
    }

    func closeWindowed() {
        guard let window = windowed else { return }
        window.delegate = nil
        window.close()
        windowed = nil
        isWindowedOpen = false
        uninstallEscapeClearMonitorIfIdle()
    }

    func closeFullscreen() {
        guard let window = fullscreen else { return }
        window.delegate = nil
        window.close()
        fullscreen = nil
        isFullscreenOpen = false
        uninstallEscapeClearMonitorIfIdle()
    }

    private func installEscapeClearMonitor(controller: ShowController) {
        guard escapeKeyMonitor == nil else { return }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak controller] event in
            guard let self, self.isOpen, event.keyCode == 53, !event.isARepeat else { return event }
            if NSApp.modalWindow != nil || NSApp.keyWindow?.firstResponder is NSTextView {
                return event
            }
            controller?.clearSlide()
            return nil
        }
    }

    private func uninstallEscapeClearMonitorIfIdle() {
        guard !isOpen, let monitor = escapeKeyMonitor else { return }
        NSEvent.removeMonitor(monitor)
        escapeKeyMonitor = nil
    }

    func close() {
        closeWindowed()
        closeFullscreen()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        closing.delegate = nil
        // Releasing our last strong NSWindow reference inside the delegate
        // callback can cause an objc_release crash; defer until after return.
        DispatchQueue.main.async { [weak self, weak closing] in
            guard let self, let closing else { return }
            if self.windowed === closing {
                self.windowed = nil
                self.isWindowedOpen = false
            } else if self.fullscreen === closing {
                self.fullscreen = nil
                self.isFullscreenOpen = false
            }
            self.uninstallEscapeClearMonitorIfIdle()
        }
    }
}

private struct AudienceOutputView: View {
    @ObservedObject var controller: ShowController
    @ObservedObject var output: OutputManager
    let scope: String

    private var ownsAudio: Bool {
        // One and only one output emits program audio; fullscreen wins when
        // both are open. The operator Program monitor is always silent.
        scope == "fullscreen" || !output.isFullscreenOpen
    }

    var body: some View {
        ZStack {
            Color.black
            ProgramCanvas(controller: controller, scaleMode: output.scaleMode,
                          constrainTo16x9: false, isAudienceOutput: ownsAudio,
                          outputScope: scope)
        }
        .ignoresSafeArea()
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            // Best-effort playhead correction for independently decoded video
            // surfaces. Physical HDMI frame lock requires a shared compositor.
            VideoPlaybackPool.shared.correctActiveOutputDrift()
        }
    }
}
