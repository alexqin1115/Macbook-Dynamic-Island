import AppKit
import Carbon.HIToolbox
import Combine
import IslandCore
import SwiftUI

final class IslandPanel: NSPanel {
    /// Only true while the search field needs the keyboard.
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
    // Borderless windows must be allowed to sit over the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Under the notch a key window reports a top safe-area inset; without this the island slides down ~35pt when search takes focus.
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var safeAreaRect: NSRect { bounds }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = IslandStore()
    private var panel: IslandPanel?
    private var notch: NotchMetrics?
    private var monitors: [Any] = []
    private var collapseTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var hotKey: HotKey?
    private var shrinkTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let url = URL(string: text) else { return }
        store.handle(url: url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        rebuildPanel()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanel() }
        }
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        // Mouse-move monitors need no Accessibility permission (only key events do).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        }) { monitors.append(m) }
        if ProcessInfo.processInfo.environment["NOTCH_AUTO_EXPAND"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.store.setExpanded(true) }
        }
        if let text = ProcessInfo.processInfo.environment["NOTCH_LATE_SEARCH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.store.setExpanded(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.store.beginSearch()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.store.search.query = text }
            }
        }
        if let text = ProcessInfo.processInfo.environment["NOTCH_AUTO_SEARCH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.store.beginSearch()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.store.search.query = text }
            }
        }
        store.$mode.sink { [weak self] mode in
            self?.panel?.ignoresMouseEvents = mode != .expanded && mode != .alert && mode != .prompt
        }.store(in: &cancellables)
        // Keep the window only as tall as the island so its transparent part never blocks clicks.
        store.$mode.combineLatest(store.$searching, store.$liveActivities, store.$music)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.fitPanel() } }
            .store(in: &cancellables)
        store.search.$results.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.fitPanel() } }
            .store(in: &cancellables)
        store.$searching.sink { [weak self] searching in
            guard let panel = self?.panel else { return }
            panel.allowKey = searching
            // A non-activating panel can take the keyboard without activating the app; activating it makes
            // the system menu bar redraw over the top of the island.
            if searching {
                DispatchQueue.main.async { panel.makeKey() }
            } else if panel.isKeyWindow {
                panel.resignKey()
            }
        }.store(in: &cancellables)
        // Clicking away from the search field ends the search.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? IslandPanel === self.panel, self.store.searching else { return }
                self.store.endSearch()
            }
        }
        // Ctrl+Option+Space opens search from anywhere.
        hotKey = HotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey, id: 1) { [weak self] in
            MainActor.assumeIsolated { self?.store.beginSearch() }
        }
    }

    private func rebuildPanel() {
        panel?.orderOut(nil)
        panel = nil
        notch = nil
        store.setExpanded(false)
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let metrics = NotchMetrics.detect(frame: screen.frame, safeTop: screen.safeAreaInsets.top,
                                                leftWidth: screen.auxiliaryTopLeftArea?.width ?? 0,
                                                rightWidth: screen.auxiliaryTopRightArea?.width ?? 0) else { return }
        notch = metrics
        let panel = IslandPanel(contentRect: IslandLayout.panelFrame(notch: metrics),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        let host = FirstMouseHostingView(rootView: IslandRootView(store: store, notch: metrics))
        // While the window grows, keep already-rendered content pinned to the top instead of centred.
        host.layerContentsPlacement = .top
        panel.contentView = host
        panel.setFrame(IslandLayout.panelFrame(notch: metrics), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        fitPanel()
    }

    private func fitPanel() {
        guard let panel, let notch else { return }
        let body = IslandLayout.bodySize(mode: store.mode, notch: notch, extra: store.expandedExtra)
        // While expanded the window keeps its tallest size: resizing it mid-animation makes the content slide
        // down and back for a few frames. mouseMoved() lets clicks through the empty part instead.
        let tallest = IslandLayout.expandedSize.height + IslandLayout.maxExtra
        let height = (store.mode == .expanded ? tallest : max(body.height, notch.height)) + IslandLayout.shadowPadding
        var frame = IslandLayout.panelFrame(notch: notch)
        frame.origin.y = notch.topY - height
        frame.size.height = height
        shrinkTask?.cancel()
        if height >= panel.frame.height {
            panel.setFrame(frame, display: true)
        } else {
            // Let the collapse animation finish before the window shrinks around it.
            shrinkTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled, let self, let panel = self.panel else { return }
                panel.setFrame(frame, display: true)
            }
        }
    }

    private func mouseMoved() {
        guard let notch, ProcessInfo.processInfo.environment["NOTCH_AUTO_EXPAND"] == nil, ProcessInfo.processInfo.environment["NOTCH_AUTO_SEARCH"] == nil, ProcessInfo.processInfo.environment["NOTCH_LATE_SEARCH"] == nil else { return }
        let point = NSEvent.mouseLocation
        if store.mode == .expanded {
            panel?.ignoresMouseEvents = !IslandLayout.expandedZone(notch: notch, extra: store.expandedExtra).contains(point)
        }
        if store.mode == .alert || store.mode == .prompt { return }
        if store.mode == .expanded {
            if store.searching { return }
            if IslandLayout.expandedZone(notch: notch, extra: store.expandedExtra).contains(point) {
                collapseTask?.cancel()
                collapseTask = nil
            } else if collapseTask == nil {
                collapseTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    guard !Task.isCancelled else { return }
                    self?.store.setExpanded(false)
                    self?.collapseTask = nil
                }
            }
        } else if IslandLayout.hotZone(notch: notch).contains(point) {
            store.setExpanded(true)
        }
    }
}

/// `NotchIsland --snapshot DIR` renders each state to PNG without showing a window.
@MainActor
func renderSnapshots(to dir: String) {
    let notch = NotchMetrics(width: 200, height: 37, centerX: 0, topY: 0)
    let store = IslandStore()
    store.instantReveal = true
    store.battery = BatteryState(percent: 85, onAC: true, charging: true)
    store.music = MusicState(source: .spotify, title: "Midnight City", artist: "M83", isPlaying: true, duration: 243, position: 95)
    let states: [(String, IslandMode, Activity?)] = [
        ("expanded", .expanded, nil),
        ("charging", .compact, .charging(percent: 85)),
        ("music", .compact, .music),
        ("volume", .compact, .volume(level: 0.6, muted: false)),
        ("brightness", .compact, .brightness(level: 0.75)),
        ("touchid", .prompt, .touchID),
        ("caps", .compact, .capsLock(on: true)),
        ("bluetooth", .compact, .bluetooth(name: "Sam’s AirPods Pro", battery: 80)),
        ("privacy", .compact, .privacy(PrivacyState(camera: true, mic: true))),
        ("audio", .compact, .audioOutput(name: "Sam’s AirPods Pro", symbol: "airpodspro")),
        ("live", .compact, .live(LiveActivity(id: "t", title: "Tea", symbol: "timer", tint: "orange", endsAt: Date().addingTimeInterval(272), expiresAt: Date().addingTimeInterval(272)))),
        ("done", .compact, .liveDone(title: "Tea")),
        ("focus", .compact, .focus(FocusMode(name: "Do Not Disturb", symbol: "moon.fill"), on: true)),
    ]
    let sampleRows = [LiveActivity(id: "b", title: "Build", subtitle: "Running tests", symbol: "hammer.fill", tint: "orange", progress: 0.6, expiresAt: .distantFuture),
                      LiveActivity(id: "t", title: "Tea", symbol: "timer", tint: "green", endsAt: Date().addingTimeInterval(272), expiresAt: .distantFuture)]
    for (name, mode, activity) in states {
        store.liveActivities = name == "expanded" ? sampleRows : []
        store.mode = mode
        store.activity = activity
        let view = IslandRootView(store: store, notch: notch)
            .frame(width: 540, height: 380, alignment: .top)
            .background(Color(white: 0.75))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}

@MainActor
func renderAlertSnapshot(to dir: String) {
    let notch = NotchMetrics(width: 200, height: 37, centerX: 0, topY: 0)
    let store = IslandStore()
    store.instantReveal = true
    store.incoming = IncomingRequest(kind: .call, title: "Mom", subtitle: "iPhone call", acceptLabel: "Answer", declineLabel: "Decline")
    store.mode = .alert
    for (name, kind) in [("alert_call", IncomingKind.call), ("alert_airdrop", .airDrop)] {
        store.incoming = kind == .call
            ? IncomingRequest(kind: .call, title: "Mom", subtitle: "iPhone call", acceptLabel: "Answer", declineLabel: "Decline")
            : IncomingRequest(kind: .airDrop, title: "Sam’s iPhone", subtitle: "wants to share a photo", acceptLabel: "Accept", declineLabel: "Decline")
        let view = IslandRootView(store: store, notch: notch).frame(width: 540, height: 380, alignment: .top).background(Color(white: 0.75))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count {
    MainActor.assumeIsolated { renderSnapshots(to: arguments[i + 1]); renderAlertSnapshot(to: arguments[i + 1]) }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
