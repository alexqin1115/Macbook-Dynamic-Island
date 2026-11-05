import CoreGraphics
import Foundation

// MARK: - Geometry

public struct NotchMetrics: Equatable {
    public let width: CGFloat
    public let height: CGFloat
    public let centerX: CGFloat
    /// Top edge of the screen in AppKit coordinates (origin bottom-left).
    public let topY: CGFloat

    public init(width: CGFloat, height: CGFloat, centerX: CGFloat, topY: CGFloat) {
        self.width = width
        self.height = height
        self.centerX = centerX
        self.topY = topY
    }

    /// Nil when the screen has no notch.
    public static func detect(frame: CGRect, safeTop: CGFloat, leftWidth: CGFloat, rightWidth: CGFloat) -> NotchMetrics? {
        guard safeTop > 0, leftWidth > 0, rightWidth > 0 else { return nil }
        let width = frame.width - leftWidth - rightWidth
        guard width > 0 else { return nil }
        return NotchMetrics(width: width, height: safeTop, centerX: frame.minX + leftWidth + width / 2, topY: frame.maxY)
    }
}

public enum IslandMode: Equatable {
    case hidden, compact, expanded, alert, prompt
}

public enum IslandLayout {
    public static let wingWidth: CGFloat = 60
    public static let expandedSize = CGSize(width: 440, height: 212)
    public static let flare: CGFloat = 10
    public static let shadowPadding: CGFloat = 24

    /// Size of the black body, excluding the concave top flares.
    /// Face-ID-style prompt: the notch drops down into a taller, centered card.
    public static let promptSize = CGSize(width: 190, height: 112)
    public static let alertSize = CGSize(width: 400, height: 104)
    /// Height of one Live Activity row in the expanded panel, and the most extra height the panel can ever need.
    public static let extraRow: CGFloat = 46
    public static let maxExtra: CGFloat = 150
    /// How much shorter the expanded panel is when nothing is playing.
    public static let idleTrim: CGFloat = 130

    public static func bodySize(mode: IslandMode, notch: NotchMetrics, extra: CGFloat = 0) -> CGSize {
        switch mode {
        case .hidden: return CGSize(width: notch.width, height: notch.height)
        case .compact: return CGSize(width: notch.width + wingWidth * 2, height: notch.height)
        case .expanded: return CGSize(width: expandedSize.width, height: expandedSize.height + min(max(extra, -idleTrim), maxExtra))
        case .alert: return alertSize
        case .prompt: return promptSize
        }
    }

    public static func panelFrame(notch: NotchMetrics) -> CGRect {
        let w = expandedSize.width + (flare + shadowPadding) * 2
        let h = expandedSize.height + maxExtra + shadowPadding
        return CGRect(x: notch.centerX - w / 2, y: notch.topY - h, width: w, height: h)
    }

    /// Where the pointer must be to open the island: the notch plus a small margin.
    public static func hotZone(notch: NotchMetrics) -> CGRect {
        CGRect(x: notch.centerX - notch.width / 2 - 6, y: notch.topY - notch.height - 4,
               width: notch.width + 12, height: notch.height + 8)
    }

    /// Screen rect of the expanded body. The pointer leaving it closes the island.
    public static func expandedZone(notch: NotchMetrics, extra: CGFloat = 0) -> CGRect {
        let size = bodySize(mode: .expanded, notch: notch, extra: extra)
        return CGRect(x: notch.centerX - size.width / 2, y: notch.topY - size.height - 4, width: size.width, height: size.height + 8)
    }
}

// MARK: - Battery

public struct BatteryState: Equatable {
    public var percent: Int
    public var onAC: Bool
    public var charging: Bool

    public init(percent: Int, onAC: Bool, charging: Bool) {
        self.percent = percent
        self.onAC = onAC
        self.charging = charging
    }
}

public enum BatteryEvent: Equatable {
    case pluggedIn(percent: Int)
    case low(percent: Int)
}

public let lowBatteryThreshold = 20

/// Only real transitions produce an event; the first reading never does.
public func batteryEvent(previous: BatteryState?, current: BatteryState) -> BatteryEvent? {
    guard let previous else { return nil }
    if !previous.onAC && current.onAC { return .pluggedIn(percent: current.percent) }
    if !current.onAC && previous.percent > lowBatteryThreshold && current.percent <= lowBatteryThreshold {
        return .low(percent: current.percent)
    }
    return nil
}

// MARK: - Music

public func formatClock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
}

public enum MusicSource: String, Equatable {
    case music = "Music"
    case spotify = "Spotify"

    public var notificationName: String {
        switch self {
        case .music: return "com.apple.Music.playerInfo"
        case .spotify: return "com.spotify.client.PlaybackStateChanged"
        }
    }
}

public struct MusicState: Equatable {
    public let source: MusicSource
    public let title: String
    public let artist: String
    public let isPlaying: Bool
    /// Track length in seconds, when the player reports it.
    public let duration: Double?
    /// Playback position in seconds as of `updatedAt`.
    public var position: Double?
    public var updatedAt: Date

    public init(source: MusicSource, title: String, artist: String, isPlaying: Bool,
                duration: Double? = nil, position: Double? = nil, updatedAt: Date = Date()) {
        self.source = source
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
        self.duration = duration
        self.position = position
        self.updatedAt = updatedAt
    }

    public static func == (a: MusicState, b: MusicState) -> Bool {
        a.source == b.source && a.title == b.title && a.artist == b.artist && a.isPlaying == b.isPlaying
            && a.duration == b.duration && a.position == b.position
    }

    /// Seconds into the track at `now`, extrapolated while playing.
    public func elapsed(at now: Date) -> Double? {
        guard let position else { return nil }
        let value = position + (isPlaying ? max(0, now.timeIntervalSince(updatedAt)) : 0)
        return duration.map { min(value, $0) } ?? value
    }

    public func progress(at now: Date) -> Double? {
        guard let duration, duration > 0, let elapsed = elapsed(at: now) else { return nil }
        return min(max(elapsed / duration, 0), 1)
    }

    /// Parses Music/Spotify distributed notifications. Stopped playback returns nil.
    public static func parse(userInfo: [AnyHashable: Any], source: MusicSource) -> MusicState? {
        let state = userInfo["Player State"] as? String ?? ""
        guard state == "Playing" || state == "Paused" else { return nil }
        guard let title = userInfo["Name"] as? String, !title.isEmpty else { return nil }
        // Music reports "Total Time" (ms); Spotify reports "Duration" (ms) and "Playback Position" (s).
        let millis = (userInfo["Total Time"] as? NSNumber ?? userInfo["Duration"] as? NSNumber)?.doubleValue
        return MusicState(source: source, title: title, artist: userInfo["Artist"] as? String ?? "", isPlaying: state == "Playing",
                          duration: millis.map { $0 / 1000 }, position: (userInfo["Playback Position"] as? NSNumber)?.doubleValue)
    }

    /// Worth announcing only when a new track starts or playback resumes.
    public func shouldAnnounce(after previous: MusicState?) -> Bool {
        guard isPlaying else { return false }
        guard let previous else { return true }
        return previous.title != title || previous.artist != artist || !previous.isPlaying
    }
}

// MARK: - HUD symbols

public func volumeSymbol(level: Double, muted: Bool) -> String {
    if muted || level <= 0 { return "speaker.slash.fill" }
    switch level {
    case ..<0.34: return "speaker.wave.1.fill"
    case ..<0.67: return "speaker.wave.2.fill"
    default: return "speaker.wave.3.fill"
    }
}

public func brightnessSymbol(level: Double) -> String {
    level < 0.35 ? "sun.min.fill" : "sun.max.fill"
}

// MARK: - Focus

public struct FocusMode: Equatable {
    public let name: String
    public let symbol: String

    public init(name: String, symbol: String) {
        self.name = name
        self.symbol = symbol
    }
}

public enum FocusParser {
    /// Mode identifier of the active Focus, or nil when none is active.
    public static func activeModeIdentifier(assertions: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: assertions) as? [String: Any],
              let data = root["data"] as? [[String: Any]] else { return nil }
        for store in data {
            guard let records = store["storeAssertionRecords"] as? [[String: Any]] else { continue }
            for record in records {
                if let details = record["assertionDetails"] as? [String: Any],
                   let id = details["assertionDetailsModeIdentifier"] as? String { return id }
            }
        }
        return nil
    }

    public static func modes(configurations: Data) -> [String: FocusMode] {
        guard let root = try? JSONSerialization.jsonObject(with: configurations) as? [String: Any],
              let data = root["data"] as? [[String: Any]] else { return [:] }
        var out: [String: FocusMode] = [:]
        for store in data {
            guard let configs = store["modeConfigurations"] as? [String: Any] else { continue }
            for (id, value) in configs {
                guard let mode = (value as? [String: Any])?["mode"] as? [String: Any],
                      let name = mode["name"] as? String else { continue }
                out[id] = FocusMode(name: name, symbol: mode["symbolImageName"] as? String ?? "moon.fill")
            }
        }
        return out
    }

    /// Names for the built-in modes, used when ModeConfigurations.json cannot be read.
    public static let builtIn: [String: FocusMode] = [
        "com.apple.donotdisturb.mode.default": FocusMode(name: "Do Not Disturb", symbol: "moon.fill"),
        "com.apple.sleep.sleep-mode": FocusMode(name: "Sleep", symbol: "bed.double.fill"),
        "com.apple.focus.personal-time": FocusMode(name: "Personal", symbol: "person.fill"),
        "com.apple.focus.work": FocusMode(name: "Work", symbol: "person.lanyardcard.fill"),
        "com.apple.focus.reduce-interruptions": FocusMode(name: "Reduce Interruptions", symbol: "moon.fill"),
        "com.apple.focus.driving": FocusMode(name: "Driving", symbol: "car.fill"),
        "com.apple.focus.fitness": FocusMode(name: "Fitness", symbol: "figure.run"),
        "com.apple.focus.gaming": FocusMode(name: "Gaming", symbol: "gamecontroller.fill"),
        "com.apple.focus.mindfulness": FocusMode(name: "Mindfulness", symbol: "apple.meditate"),
        "com.apple.focus.reading": FocusMode(name: "Reading", symbol: "book.fill"),
    ]

    public static func resolve(id: String, modes: [String: FocusMode]) -> FocusMode {
        modes[id] ?? builtIn[id] ?? FocusMode(name: "Focus", symbol: "moon.fill")
    }
}

// MARK: - HUD change detection

/// Sudden jumps always count; slow drift (auto-brightness) only counts right after a key press.
public func brightnessChangeIsUserDriven(previous: Double, current: Double, keyArmed: Bool) -> Bool {
    let delta = abs(current - previous)
    guard delta >= 0.004 else { return false }
    return keyArmed || delta >= 0.04
}

// MARK: - Privacy indicators

public struct PrivacyState: Equatable {
    public var camera: Bool
    public var mic: Bool

    public init(camera: Bool, mic: Bool) {
        self.camera = camera
        self.mic = mic
    }

    public var any: Bool { camera || mic }
}

/// Returns the state to announce when the camera or mic has just turned on; nil otherwise (first reading is silent).
public func privacyAnnouncement(previous: PrivacyState?, current: PrivacyState) -> PrivacyState? {
    guard let previous else { return nil }
    let turnedOn = (!previous.camera && current.camera) || (!previous.mic && current.mic)
    return turnedOn ? current : nil
}

// MARK: - Bluetooth

public enum BluetoothInfo {
    public static func symbol(forName name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("mouse") || n.contains("trackpad") { return "computermouse.fill" }
        if n.contains("homepod") || n.contains("speaker") { return "hifispeaker.fill" }
        return "headphones"
    }

    /// Battery percent for a connected device from `system_profiler SPBluetoothDataType -json`.
    /// Earbuds report left/right/case; the lowest earbud is the number that matters.
    public static func battery(profilerJSON: Data, deviceName: String) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: profilerJSON) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        func percent(_ v: Any?) -> Int? {
            guard let s = v as? String else { return nil }
            return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
        }
        for section in sections {
            for entry in section["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry where name == deviceName {
                    guard let props = value as? [String: Any] else { continue }
                    let buds = [percent(props["device_batteryLevelLeft"]), percent(props["device_batteryLevelRight"])].compactMap { $0 }
                    if let lowest = buds.min() { return lowest }
                    return percent(props["device_batteryLevelMain"])
                }
            }
        }
        return nil
    }
}

// MARK: - Authentication prompt

/// System windows that appear while macOS asks for Touch ID or a password.
public let authPromptOwners: Set<String> = ["coreautha", "LocalAuthenticationRemoteService", "SecurityAgent"]

public func isAuthPromptVisible(owners: [String]) -> Bool {
    owners.contains { authPromptOwners.contains($0) }
}

// MARK: - Audio output

public enum AudioOutputInfo {
    public static func symbol(forName name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods") || n.contains("beats") { return BluetoothInfo.symbol(forName: name) }
        if n.contains("macbook") || n.contains("built-in") { return "laptopcomputer" }
        if n.contains("hdmi") || n.contains("displayport") || n.contains("display") || n.contains("monitor") { return "display" }
        if n.contains("homepod") || n.contains("airplay") || n.contains("apple tv") { return "airplayaudio" }
        if n.contains("headphone") || n.contains("headset") { return "headphones" }
        return "hifispeaker.fill"
    }
}

// MARK: - Live Activities (third-party and timers, driven by notchisland:// links)

public struct LiveActivity: Equatable, Identifiable {
    public let id: String
    public var title: String
    public var subtitle: String
    public var symbol: String
    public var tint: String
    public var progress: Double?
    public var endsAt: Date?
    public var expiresAt: Date

    public init(id: String, title: String, subtitle: String = "", symbol: String = "sparkles", tint: String = "blue",
                progress: Double? = nil, endsAt: Date? = nil, expiresAt: Date) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.progress = progress
        self.endsAt = endsAt
        self.expiresAt = expiresAt
    }
}

public enum ActivityCommand: Equatable {
    case start(LiveActivity)
    case end(id: String)
}

public enum ActivityURL {
    public static let allowedTints: Set<String> = ["blue", "green", "orange", "red", "pink", "purple", "yellow", "cyan", "indigo", "white"]

    /// notchisland://activity?id=build&title=Build&subtitle=Running&symbol=hammer.fill&tint=orange&progress=0.4&ttl=600
    /// notchisland://timer?seconds=300&title=Tea        notchisland://end?id=build
    /// Everything is clamped, because any app or web page can open such a link.
    public static func parse(_ url: URL, now: Date = Date()) -> ActivityCommand? {
        guard url.scheme == "notchisland", let host = url.host?.lowercased(),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        func clean(_ text: String?, _ limit: Int) -> String { String((text ?? "").prefix(limit)) }
        let id = clean(value("id"), 40)
        switch host {
        case "end":
            return id.isEmpty ? nil : .end(id: id)
        case "timer":
            guard let seconds = value("seconds").flatMap(Double.init), seconds.isFinite else { return nil }
            let length = min(max(seconds, 1), 86_400)
            let end = now.addingTimeInterval(length)
            let title = clean(value("title"), 40)
            return .start(LiveActivity(id: id.isEmpty ? "timer" : id, title: title.isEmpty ? "Timer" : title, subtitle: "",
                                       symbol: "timer", tint: normalizedTint(value("tint"), fallback: "orange"),
                                       endsAt: end, expiresAt: end.addingTimeInterval(1)))
        case "activity":
            let title = clean(value("title"), 40)
            guard !title.isEmpty else { return nil }
            let ttl = min(max(value("ttl").flatMap(Double.init) ?? 3600, 5), 86_400)
            let symbol = value("symbol").flatMap { $0.range(of: "^[A-Za-z0-9.]{1,60}$", options: .regularExpression) != nil ? $0 : nil } ?? "sparkles"
            let progress = value("progress").flatMap(Double.init).flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
            return .start(LiveActivity(id: id.isEmpty ? "default" : id, title: title, subtitle: clean(value("subtitle"), 60), symbol: symbol,
                                       tint: normalizedTint(value("tint"), fallback: "blue"), progress: progress,
                                       expiresAt: now.addingTimeInterval(ttl)))
        default:
            return nil
        }
    }

    private static func normalizedTint(_ raw: String?, fallback: String) -> String {
        let t = raw?.lowercased() ?? fallback
        return allowedTints.contains(t) ? t : fallback
    }
}

// MARK: - Incoming call / AirDrop banners

public enum IncomingKind: Equatable {
    case call, airDrop
}

public struct IncomingRequest: Equatable {
    public let kind: IncomingKind
    public let title: String
    public let subtitle: String
    public let acceptLabel: String
    public let declineLabel: String

    public init(kind: IncomingKind, title: String, subtitle: String, acceptLabel: String, declineLabel: String) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.acceptLabel = acceptLabel
        self.declineLabel = declineLabel
    }
}

/// Decides whether a notification banner (its text and button labels) is a call or an AirDrop request.
public func classifyBanner(texts: [String], buttons: [String]) -> IncomingRequest? {
    let lowerButtons = buttons.map { $0.lowercased() }
    func button(containing words: [String]) -> String? {
        zip(buttons, lowerButtons).first { _, l in words.contains { l.contains($0) } }?.0
    }
    guard let accept = button(containing: ["accept", "answer"]), let decline = button(containing: ["decline", "reject"]) else { return nil }
    let joined = texts.joined(separator: " ").lowercased()
    let visible = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    if joined.contains("airdrop") {
        let title = visible.first { !$0.lowercased().hasPrefix("airdrop") } ?? "AirDrop"
        return IncomingRequest(kind: .airDrop, title: title, subtitle: "AirDrop", acceptLabel: accept, declineLabel: decline)
    }
    if joined.contains("call") || joined.contains("facetime") {
        let title = visible.first ?? "Incoming Call"
        let subtitle = visible.dropFirst().first ?? "Incoming Call"
        return IncomingRequest(kind: .call, title: title, subtitle: subtitle, acceptLabel: accept, declineLabel: decline)
    }
    return nil
}

// MARK: - Calculator (for Spotlight-style search)

public enum Calculator {
    /// Evaluates + - * / % ( ) and decimals; returns nil for anything else or for a lone number.
    public static func evaluate(_ text: String) -> String? {
        let chars = Array(text.filter { !$0.isWhitespace })
        guard !chars.isEmpty, chars.allSatisfy({ "0123456789.+-*/x×÷%()".contains($0) }),
              chars.contains(where: { "+-*/x×÷%".contains($0) }) else { return nil }
        var parser = Parser(chars: chars)
        guard let value = parser.expression(), parser.atEnd, value.isFinite else { return nil }
        if value == value.rounded() && abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.8g", value)
    }

    private struct Parser {
        let chars: [Character]
        var index = 0
        var atEnd: Bool { index >= chars.count }

        init(chars: [Character]) { self.chars = chars }

        mutating func expression() -> Double? {
            guard var left = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                index += 1
                guard let right = term() else { return nil }
                left = c == "+" ? left + right : left - right
            }
            return left
        }

        mutating func term() -> Double? {
            guard var left = factor() else { return nil }
            while let c = peek(), "*/x×÷%".contains(c) {
                index += 1
                guard let right = factor() else { return nil }
                switch c {
                case "*", "x", "×": left *= right
                case "%": left = right == 0 ? .nan : left.truncatingRemainder(dividingBy: right)
                default: left = right == 0 ? .nan : left / right
                }
            }
            return left
        }

        mutating func factor() -> Double? {
            if peek() == "-" { index += 1; return factor().map { -$0 } }
            if peek() == "(" {
                index += 1
                guard let inner = expression(), peek() == ")" else { return nil }
                index += 1
                return inner
            }
            var text = ""
            while let c = peek(), c.isNumber || c == "." { text.append(c); index += 1 }
            return Double(text)
        }

        func peek() -> Character? { index < chars.count ? chars[index] : nil }
    }
}
