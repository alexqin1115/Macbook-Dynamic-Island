import AppKit
import Combine
import IslandCore
import ServiceManagement

enum Activity: Equatable {
    case charging(percent: Int)
    case lowBattery(percent: Int)
    case music
    case volume(level: Double, muted: Bool)
    case brightness(level: Double)
    case focus(FocusMode, on: Bool)
    case lowPower(on: Bool)
    case capsLock(on: Bool)
    case bluetooth(name: String, battery: Int?)
    case privacy(PrivacyState)
    case touchID
    case audioOutput(name: String, symbol: String)
    case live(LiveActivity)
    case liveDone(title: String)

    /// Identity of the kind of alert, so switching kinds cross-fades but updating one (volume 40 -> 41) does not.
    var kind: String {
        switch self {
        case .charging: return "charging"
        case .lowBattery: return "lowBattery"
        case .music: return "music"
        case .volume: return "volume"
        case .brightness: return "brightness"
        case .focus: return "focus"
        case .lowPower: return "lowPower"
        case .capsLock: return "capsLock"
        case .bluetooth: return "bluetooth"
        case .privacy: return "privacy"
        case .touchID: return "touchID"
        case .audioOutput: return "audioOutput"
        case .live: return "live"
        case .liveDone: return "liveDone"
        }
    }

    var wingWidth: CGFloat {
        switch self {
        case .volume, .brightness: return 72
        case .focus: return 108
        case .bluetooth, .touchID: return 84
        case .audioOutput: return 124
        case .live, .liveDone: return 108
        case .privacy: return 70
        default: return IslandLayout.wingWidth
        }
    }
}

@MainActor
final class IslandStore: ObservableObject {
    @Published var mode: IslandMode = .hidden
    @Published var activity: Activity?
    @Published var battery: BatteryState?
    @Published var music: MusicState?
    @Published var artwork: NSImage?
    /// Snapshot rendering skips the intro animation so a still image shows the final layout.
    var instantReveal = false
    @Published var focusReadable = true
    @Published var liveActivities: [LiveActivity] = []
    @Published var incoming: IncomingRequest?
    @Published var searching = false
    @Published var accessibilityTrusted = IncomingWatcher.trusted
    let search = SearchModel()

    /// Extra panel height beyond the base layout: Live Activity rows, or room for search results.
    var expandedExtra: CGFloat {
        if searching { return 64 }
        let rows = CGFloat(min(liveActivities.count, 2)) * IslandLayout.extraRow
        return music == nil ? rows - IslandLayout.idleTrim : rows
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var batteryTimer: Timer?
    private var activityTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var volumeWatcher: VolumeWatcher?
    private var brightnessTimer: Timer?
    private var focusTimer: Timer?
    private var lastBrightness: Double?
    private var brightnessArmedUntil = Date.distantPast
    private var focusModes: [String: FocusMode] = [:]
    private var lastFocusID: String??
    private var keyMonitor: Any?
    private var lastCaps = KeyboardState.capsLockOn
    private var lastPrivacy: PrivacyState?
    private var privacyTimer: Timer?
    private var capsTimer: Timer?
    private var authTimer: Timer?
    private var authShowing = false
    /// Last time the user cancelled by hand (click, Esc, Return); a prompt that closes without it was a Touch ID match.
    private var lastManualInput = Date.distantPast
    @Published var authSucceeded = false
    private var successTask: Task<Void, Never>?
    private var bluetoothWatcher: BluetoothWatcher?
    private var incomingWatcher = IncomingWatcher()
    private var incomingTimer: Timer?
    private var liveTimer: Timer?

    func start() {
        let manual: (NSEvent) -> Void = { [weak self] e in
            if e.type == .leftMouseDown || [53, 36, 76].contains(e.keyCode) {
                MainActor.assumeIsolated { self?.lastManualInput = Date() }
            }
        }
        _ = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown], handler: manual)
        _ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { e in manual(e); return e })
        battery = SystemReader.battery()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollBattery() }
        }
        batteryTimer?.tolerance = 2
        startHUDs()
        let center = DistributedNotificationCenter.default()
        for source in [MusicSource.music, .spotify] {
            observers.append(center.addObserver(forName: .init(source.notificationName), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                MainActor.assumeIsolated { self?.receiveMusic(info, source: source) }
            })
        }
    }

    private func startHUDs() {
        volumeWatcher = VolumeWatcher(onChange: { [weak self] level, muted in
            self?.show(.volume(level: level, muted: muted), seconds: 1.6)
        }, onDeviceChange: { [weak self] name in
            self?.show(.audioOutput(name: name, symbol: AudioOutputInfo.symbol(forName: name)), seconds: 2.5)
        })
        incomingTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollIncoming() }
        }
        incomingTimer?.tolerance = 0.3
        if BrightnessReader.available {
            lastBrightness = BrightnessReader.read()
            brightnessTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollBrightness() }
            }
            brightnessTimer?.tolerance = 0.1
            // Brightness keys are system-defined events (subtype 8, key 2/3); seeing one means the change is the user's.
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
                guard event.subtype.rawValue == 8 else { return }
                let key = (event.data1 & 0xFFFF0000) >> 16
                guard key == 2 || key == 3 else { return }
                MainActor.assumeIsolated { self?.brightnessArmedUntil = Date().addingTimeInterval(2) }
            }
        }
        focusModes = FocusReader.modes()
        let first = FocusReader.active()
        focusReadable = first.readable
        if first.readable {
            beginFocusPolling(initial: first.id)
        } else {
            // Without Full Disk Access the file is unreadable; keep checking so granting access works without a relaunch.
            focusTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = FocusReader.active()
                    guard now.readable else { return }
                    self.focusModes = FocusReader.modes()
                    self.focusReadable = true
                    self.beginFocusPolling(initial: now.id)
                }
            }
        }
        capsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollCaps() }
        }
        capsTimer?.tolerance = 0.1
        authTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAuth() }
        }
        authTimer?.tolerance = 0.2
        lastPrivacy = PrivacyReader.state()
        privacyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPrivacy() }
        }
        privacyTimer?.tolerance = 0.5
        bluetoothWatcher = BluetoothWatcher { [weak self] name in self?.bluetoothConnected(name) }
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.show(.lowPower(on: ProcessInfo.processInfo.isLowPowerModeEnabled), seconds: 3) }
        })
    }

    /// Stays up for as long as the system prompt is on screen, then folds away.
    private func pollAuth() {
        let visible = AuthPromptReader.visible()
        guard visible != authShowing else { return }
        authShowing = visible
        if visible {
            guard mode != .expanded else { return }
            activityTask?.cancel()
            successTask?.cancel()
            authSucceeded = false
            activity = .touchID
            mode = .prompt
        } else if activity == .touchID {
            activityTask?.cancel()
            if mode == .prompt, Date().timeIntervalSince(lastManualInput) > 1.2 {
                // Closed on its own: the fingerprint matched. Show a checkmark before folding away.
                authSucceeded = true
                successTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_300_000_000)
                    guard !Task.isCancelled, let self, self.authSucceeded else { return }
                    self.mode = .hidden
                    self.activity = nil
                    self.authSucceeded = false
                }
            } else {
                mode = .hidden
                activity = nil
            }
        }
    }

    // MARK: Calls and AirDrop

    private func pollIncoming() {
        let trusted = IncomingWatcher.trusted
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        guard trusted else { return }
        if let request = incomingWatcher.scan() {
            guard incoming != request else { return }
            incoming = request
            activityTask?.cancel()
            activity = nil
            if searching { searching = false; search.reset() }
            mode = .alert
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        } else if incoming != nil {
            incoming = nil
            if mode == .alert { mode = .hidden }
        }
    }

    func respond(accept: Bool) {
        guard let request = incoming else { return }
        incomingWatcher.press(accept ? request.acceptLabel : request.declineLabel)
        incoming = nil
        mode = .hidden
    }

    func openAccessibilitySettings() {
        IncomingWatcher.promptForTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Search

    func beginSearch() {
        guard incoming == nil else { return }
        setExpanded(true)
        search.reset()
        searching = true
    }

    func endSearch() {
        guard searching else { return }
        setExpanded(false)
    }

    // MARK: Live Activities

    func handle(url: URL) {
        guard let command = ActivityURL.parse(url) else { return }
        switch command {
        case .start(let activity):
            if let index = liveActivities.firstIndex(where: { $0.id == activity.id }) {
                liveActivities[index] = activity
            } else {
                liveActivities.append(activity)
                if liveActivities.count > 6 { liveActivities.removeFirst() }
            }
            show(.live(activity), seconds: 4)
            if liveTimer == nil {
                liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tickLive() }
                }
            }
        case .end(let id):
            guard let index = liveActivities.firstIndex(where: { $0.id == id }) else { return }
            let ended = liveActivities.remove(at: index)
            show(.liveDone(title: ended.title), seconds: 3)
        }
    }

    private func tickLive() {
        let now = Date()
        let expired = liveActivities.filter { $0.expiresAt <= now }
        guard !expired.isEmpty else {
            if liveActivities.isEmpty { liveTimer?.invalidate(); liveTimer = nil }
            return
        }
        liveActivities.removeAll { $0.expiresAt <= now }
        if let finished = expired.first(where: { $0.endsAt != nil }) {
            NSSound(named: "Glass")?.play()
            show(.liveDone(title: finished.title), seconds: 5)
        }
        if liveActivities.isEmpty { liveTimer?.invalidate(); liveTimer = nil }
    }

    private func pollCaps() {
        let now = KeyboardState.capsLockOn
        guard now != lastCaps else { return }
        lastCaps = now
        show(.capsLock(on: now), seconds: 1.6)
    }

    private func pollPrivacy() {
        let now = PrivacyReader.state()
        defer { lastPrivacy = now }
        if let announce = privacyAnnouncement(previous: lastPrivacy, current: now) {
            show(.privacy(announce), seconds: 3)
        }
    }

    private func bluetoothConnected(_ name: String) {
        show(.bluetooth(name: name, battery: nil), seconds: 3.5)
        BluetoothWatcher.batteryPercent(for: name) { [weak self] percent in
            guard let self, let percent, case .bluetooth(let current, _) = self.activity, current == name else { return }
            self.show(.bluetooth(name: name, battery: percent), seconds: 3.5)
        }
    }

    private func pollBrightness() {
        guard let current = BrightnessReader.read() else { return }
        defer { lastBrightness = current }
        guard let previous = lastBrightness else { return }
        if brightnessChangeIsUserDriven(previous: previous, current: current, keyArmed: Date() < brightnessArmedUntil) {
            show(.brightness(level: current), seconds: 1.6)
        }
    }


    private func beginFocusPolling(initial: String?) {
        focusTimer?.invalidate()
        lastFocusID = .some(initial)
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFocus() }
        }
        focusTimer?.tolerance = 0.25
    }

    func openFocusAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func pollFocus() {
        let now = FocusReader.active()
        guard now.readable, let previous = lastFocusID, previous != now.id else { return }
        lastFocusID = .some(now.id)
        if focusModes.isEmpty { focusModes = FocusReader.modes() }
        if let id = now.id {
            show(.focus(FocusParser.resolve(id: id, modes: focusModes), on: true), seconds: 3)
        } else if let id = previous {
            show(.focus(FocusParser.resolve(id: id, modes: focusModes), on: false), seconds: 2.5)
        }
    }

    func setExpanded(_ expanded: Bool) {
        if expanded {
            guard incoming == nil else { return }
            if mode != .expanded { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            activityTask?.cancel()
            activity = nil
            mode = .expanded
        } else {
            if searching { searching = false; search.reset() }
            mode = .hidden
        }
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("NotchIsland: login item change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func pollBattery() {
        guard let current = SystemReader.battery() else { return }
        let event = batteryEvent(previous: battery, current: current)
        if current != battery { battery = current }
        switch event {
        case .pluggedIn(let p): show(.charging(percent: p), seconds: 3)
        case .low(let p): show(.lowBattery(percent: p), seconds: 5)
        case nil: break
        }
    }

    private func receiveMusic(_ info: [AnyHashable: Any], source: MusicSource) {
        var next = MusicState.parse(userInfo: info, source: source)
        if next == nil && music?.source != source { return }
        let announce = next?.shouldAnnounce(after: music) ?? false
        let trackChanged = next?.title != music?.title || next?.artist != music?.artist
        if var n = next, n.position == nil, let old = music, !trackChanged {
            // Music does not send a position; carry the extrapolated one across a pause/resume.
            n.position = old.elapsed(at: Date())
            next = n
        }
        music = next
        if trackChanged { artwork = nil }
        if let next {
            PlayerQuery.position(of: source) { [weak self] pos in
                guard let self, let pos, var current = self.music, current.title == next.title else { return }
                current.position = pos
                current.updatedAt = Date()
                self.music = current
            }
            if trackChanged {
                PlayerQuery.artwork(of: source) { [weak self] image in
                    guard let self, self.music?.title == next.title else { return }
                    self.artwork = image
                }
            }
        }
        if announce { show(.music, seconds: 4) }
    }

    /// Wings cover menu bar icons, so they only appear briefly, and never over the open island.
    private func show(_ activity: Activity, seconds: Double) {
        guard mode != .expanded, mode != .alert, mode != .prompt else { return }
        self.activity = activity
        mode = .compact
        activityTask?.cancel()
        activityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.mode == .compact else { return }
            self.mode = .hidden
            self.activity = nil
        }
    }
}
