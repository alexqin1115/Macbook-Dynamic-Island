import IslandCore
import SwiftUI

// MARK: - Motion

/// One set of proportions so every surface is concentric with the island's outer corner.
enum Metrics {
    static let expandedRadius: CGFloat = 36
    static let compactRadius: CGFloat = 12
    static let inset: CGFloat = 20
    /// Inner shapes inside the inset sit concentric with the outer corner.
    static var innerRadius: CGFloat { expandedRadius - inset }
    static let wingInset: CGFloat = 14
}

enum Motion {
    /// Slightly bouncy, like the iPhone island opening.
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let close = Animation.spring(response: 0.28, dampingFraction: 0.92)
    static let morph = Animation.spring(response: 0.42, dampingFraction: 0.8)
}

/// Content leaves and arrives out of focus, which is what makes the island feel liquid.
struct BlurFade: ViewModifier {
    let amount: Double

    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
    }
}

extension Color {
    static func named(_ name: String) -> Color {
        switch name {
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        case "pink": return .pink
        case "purple": return .purple
        case "yellow": return .yellow
        case "cyan": return .cyan
        case "indigo": return .indigo
        case "white": return .white
        default: return .blue
        }
    }
}

extension AnyTransition {
    static var islandContent: AnyTransition {
        .modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0))
    }
}

/// Staggered entrance: each element rises in a beat after the previous one.
struct Reveal: ViewModifier {
    let shown: Bool
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .animation(.easeOut(duration: 0.18).delay(0.14 + 0.03 * Double(index)), value: shown)
    }
}

extension View {
    func reveal(_ shown: Bool, _ index: Int) -> some View { modifier(Reveal(shown: shown, index: index)) }

    /// Liquid Glass on macOS 26+, a thin material before that.
    @ViewBuilder func glassCard<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            let base: Glass = tint.map { Glass.regular.tint($0.opacity(0.3)) } ?? Glass.regular
            self.glassEffect(interactive ? base.interactive() : base, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

// MARK: - Shape

struct NotchShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, bottomRadius) }
        set { flare = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.move(to: .zero)
        p.addQuadCurve(to: CGPoint(x: flare, y: flare), control: CGPoint(x: flare, y: 0))
        p.addLine(to: CGPoint(x: flare, y: h - bottomRadius))
        p.addQuadCurve(to: CGPoint(x: flare + bottomRadius, y: h), control: CGPoint(x: flare, y: h))
        p.addLine(to: CGPoint(x: w - flare - bottomRadius, y: h))
        p.addQuadCurve(to: CGPoint(x: w - flare, y: h - bottomRadius), control: CGPoint(x: w - flare, y: h))
        p.addLine(to: CGPoint(x: w - flare, y: flare))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - flare, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root

struct IslandRootView: View {
    @ObservedObject var store: IslandStore
    let notch: NotchMetrics

    private var bodySize: CGSize {
        var size = IslandLayout.bodySize(mode: store.mode, notch: notch, extra: store.expandedExtra)
        if store.mode == .compact, let a = store.activity { size.width = notch.width + a.wingWidth * 2 }
        return size
    }

    private var radius: CGFloat {
        switch store.mode {
        case .expanded: return Metrics.expandedRadius
        case .alert: return 32
        case .prompt: return 34
        default: return Metrics.compactRadius
        }
    }

    var body: some View {
        let size = bodySize
        // The notch itself grows: the ears only exist while it is open, so the idle shape is exactly the notch.
        let flare = store.mode == .hidden ? 0 : IslandLayout.flare
        ZStack(alignment: .top) {
            NotchShape(flare: flare, bottomRadius: radius)
                .fill(Color.black)
                .frame(width: size.width + flare * 2, height: size.height)
            Group {
                if store.mode == .expanded {
                    ExpandedView(store: store, notch: notch)
                        .transition(.asymmetric(insertion: .opacity, removal: .islandContent))
                } else if store.mode == .prompt {
                    TouchIDPromptView(notch: notch, success: store.authSucceeded)
                        .transition(.asymmetric(insertion: .opacity, removal: .islandContent))
                } else if store.mode == .alert {
                    AlertView(store: store, notch: notch)
                        .transition(.asymmetric(insertion: .opacity, removal: .islandContent))
                } else if store.mode == .compact {
                    CompactView(store: store, notch: notch)
                        .transition(.islandContent)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(store.mode == .expanded || store.mode == .alert || store.mode == .prompt ? Motion.open : Motion.close, value: store.mode)
        .animation(Motion.morph, value: store.activity)
        .animation(Motion.morph, value: store.expandedExtra)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
    }
}

// MARK: - Compact alerts

struct CompactView: View {
    @ObservedObject var store: IslandStore
    let notch: NotchMetrics

    var body: some View {
        HStack(spacing: 0) {
            leading
                .id(store.activity?.kind)
                .transition(.islandContent)
                .padding(.leading, Metrics.wingInset)
                .frame(width: wing, alignment: .leading)
            Spacer(minLength: notch.width)
            trailing
                .id(store.activity?.kind)
                .transition(.islandContent)
                .padding(.trailing, Metrics.wingInset)
                .frame(width: wing, alignment: .trailing)
        }
        .font(.system(size: 13, weight: .semibold))
    }

    private var wing: CGFloat { store.activity?.wingWidth ?? IslandLayout.wingWidth }

    @ViewBuilder private var leading: some View {
        switch store.activity {
        case .volume(let l, let m):
            Image(systemName: volumeSymbol(level: l, muted: m)).foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        case .brightness(let l):
            Image(systemName: brightnessSymbol(level: l)).foregroundStyle(.yellow)
                .contentTransition(.symbolEffect(.replace))
        case .focus(let mode, let on):
            Image(systemName: on ? mode.symbol : "moon.zzz.fill").foregroundStyle(on ? Color.indigo : .secondary)
                .symbolEffect(.bounce, value: on)
        case .lowPower(let on):
            Image(systemName: "battery.50").foregroundStyle(on ? Color.yellow : .secondary).symbolEffect(.bounce, value: on)
        case .touchID: PulsingIcon(symbol: "touchid", tint: .cyan)
        case .capsLock(let on):
            Image(systemName: on ? "capslock.fill" : "capslock").foregroundStyle(on ? Color.white : .secondary)
                .contentTransition(.symbolEffect(.replace)).symbolEffect(.bounce, value: on)
        case .bluetooth(let name, _):
            Image(systemName: BluetoothInfo.symbol(forName: name)).foregroundStyle(.blue).symbolEffect(.bounce, value: name)
        case .privacy(let p):
            HStack(spacing: 5) {
                if p.camera { Image(systemName: "video.fill").foregroundStyle(.green).transition(.scale.combined(with: .opacity)) }
                if p.mic { Image(systemName: "mic.fill").foregroundStyle(.orange).transition(.scale.combined(with: .opacity)) }
            }
        case .audioOutput(_, let symbol):
            Image(systemName: symbol).foregroundStyle(.white).symbolEffect(.bounce, value: symbol)
        case .live(let a): Image(systemName: a.symbol).foregroundStyle(Color.named(a.tint)).symbolEffect(.bounce, value: a.id)
        case .liveDone: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).symbolEffect(.bounce, value: store.activity)
        case .charging: Image(systemName: "bolt.fill").foregroundStyle(.green).symbolEffect(.pulse)
        case .lowBattery: Image(systemName: "battery.25").foregroundStyle(.red).symbolEffect(.pulse)
        case .music: Image(systemName: "music.note").foregroundStyle(.pink).symbolEffect(.bounce, value: store.music?.title)
        case nil: EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch store.activity {
        case .volume(let l, let m): LevelBar(level: m ? 0 : l, tint: .white)
        case .brightness(let l): LevelBar(level: l, tint: .yellow)
        case .focus(let mode, let on):
            label(on ? mode.name : "Off", on ? .indigo : .secondary, size: 11).lineLimit(1).minimumScaleFactor(0.7)
        case .lowPower(let on): label(on ? "Low Power" : "Off", on ? .yellow : .secondary, size: 11).lineLimit(1).minimumScaleFactor(0.7)
        case .touchID: label("Touch ID", .cyan, size: 11)
        case .capsLock(let on): label(on ? "On" : "Off", on ? .white : .secondary, size: 11)
        case .bluetooth(_, let battery):
            label(battery.map { "\($0)%" } ?? "Connected", .blue, size: 12).monospacedDigit().contentTransition(.numericText())
        case .privacy(let p): label(p.camera && p.mic ? "In Use" : (p.camera ? "Camera" : "Mic"), p.camera ? .green : .orange, size: 11)
        case .audioOutput(let name, _): label(name, .white, size: 11).lineLimit(1).minimumScaleFactor(0.7)
        case .live(let a):
            if let end = a.endsAt {
                Text(end, style: .timer).monospacedDigit().foregroundStyle(Color.named(a.tint)).font(.system(size: 13, weight: .semibold))
            } else if let progress = a.progress {
                LevelBar(level: progress, tint: Color.named(a.tint))
            } else {
                label(a.subtitle.isEmpty ? a.title : a.subtitle, Color.named(a.tint), size: 11).lineLimit(1).minimumScaleFactor(0.7)
            }
        case .liveDone(let title): label(title, .green, size: 11).lineLimit(1).minimumScaleFactor(0.7)
        case .charging(let p): label("\(p)%", .green, size: 13).contentTransition(.numericText())
        case .lowBattery(let p): label("\(p)%", .red, size: 13).contentTransition(.numericText())
        case .music: EqualizerBars(active: true)
        case nil: EmptyView()
        }
    }

    private func label(_ text: String, _ tint: Color, size: CGFloat) -> some View {
        Text(text).foregroundStyle(tint).font(.system(size: size, weight: .semibold))
    }
}

/// Mirrors the system Touch ID sheet: a dim red print brightens, its ridges break away in patches until only the outer
/// ring is left, then the ring turns blue while a checkmark draws inside it.
struct TouchIDPromptView: View {
    let notch: NotchMetrics
    let success: Bool
    @State private var appeared = false
    @State private var successStart: Date?
    private let size: CGFloat = 48
    private let red = (r: 0.98, g: 0.25, b: 0.36)
    private let blue = (r: 0.04, g: 0.52, b: 1.0)

    var body: some View {
        TimelineView(.animation) { context in
            let t = successStart.map { context.date.timeIntervalSince($0) } ?? 0
            let now = context.date.timeIntervalSinceReferenceDate
            let wait = 0.34 + 0.08 * sin(now * 2.2)                  // dim and slightly alive while waiting
            let bright = success ? wait + (1 - wait) * smooth(t / 0.39) : wait
            let dissolve = smooth((t - 0.72) / 1.04)
            let ringIn = smooth((t - 0.58) / 0.33)
            let tintMix = smooth((t - 1.72) / 0.55)
            let ring = mix(red, blue, tintMix)
            ZStack {
                DissolvingGlyph(size: size, progress: success ? dissolve : 0, tint: Color(red: red.r, green: red.g, blue: red.b))
                    .opacity(bright)
                if success {
                    Circle().stroke(ring, lineWidth: 2)
                        .frame(width: size * 1.02, height: size * 1.02)
                        .opacity(ringIn)
                    CheckShape().trim(from: 0, to: smooth((t - 1.72) / 0.55))
                        .stroke(ring, style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
                        .padding(size * 0.3)
                        .frame(width: size, height: size)
                }
            }
        }
        .scaleEffect(appeared ? 1 : 0.7)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.5, dampingFraction: 0.78).delay(0.1), value: appeared)
        .padding(.top, notch.height - 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { appeared = true }
        .onChange(of: success) { _, now in successStart = now ? Date() : nil }
    }

    private func mix(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double), _ t: Double) -> Color {
        Color(red: a.r + (b.r - a.r) * t, green: a.g + (b.g - a.g) * t, blue: a.b + (b.b - a.b) * t)
    }

    private func smooth(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }
}

/// The glyph seen through small discs that close one by one: centre and lower ridges go first, the rim last.
struct DissolvingGlyph: View {
    let size: CGFloat
    let progress: Double
    let tint: Color
    private static let grid = 14

    var body: some View {
        Image(systemName: "touchid")
            .font(.system(size: size, weight: .light))
            .foregroundStyle(tint)
            .mask(
                Canvas { ctx, canvas in
                    let n = Self.grid
                    let cell = canvas.width / CGFloat(n)
                    for row in 0..<n {
                        for col in 0..<n {
                            let rand = Double((row * 37 + col * 61 + row * col * 11) % 97) / 97
                            let dx = (Double(col) + 0.5) / Double(n) - 0.5
                            let dy = (Double(row) + 0.5) / Double(n) - 0.5
                            let dist = min(sqrt(dx * dx + dy * dy) / 0.5, 1)
                            let seed = 0.55 * rand + 0.45 * dist
                            let local = min(max((progress - seed * 0.65) / 0.35, 0), 1)
                            let r = cell * 0.85 * (1 - local * local * (3 - 2 * local))
                            guard r > 0.15 else { continue }
                            let c = CGPoint(x: (CGFloat(col) + 0.5) * cell, y: (CGFloat(row) + 0.5) * cell)
                            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(.white))
                        }
                    }
                }
                .frame(width: size * 1.1, height: size * 1.1)
            )
    }
}

struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY - rect.height * 0.12))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.1))
        return p
    }
}

struct PulsingIcon: View {
    let symbol: String
    let tint: Color
    @State private var pulse = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .scaleEffect(pulse ? 1.12 : 0.92)
            .opacity(pulse ? 1 : 0.65)
            .shadow(color: tint.opacity(pulse ? 0.7 : 0), radius: 6)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

struct LevelBar: View {
    let level: Double
    let tint: Color

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.25))
            Capsule().fill(tint).frame(width: 48 * min(max(level, 0), 1))
        }
        .frame(width: 48, height: 6)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: level)
    }
}

/// Four bars that dance while audio plays and rest flat when it does not.
struct EqualizerBars: View {
    var active: Bool
    private let speeds: [Double] = [4.1, 5.3, 3.7, 4.7]
    private let phases: [Double] = [0, 1.3, 2.1, 0.6]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(Color.pink)
                        .frame(width: 3, height: active ? 4 + 12 * abs(sin(t * speeds[i] + phases[i])) : 4)
                }
            }
            .frame(height: 16)
        }
    }
}

// MARK: - Expanded panel

struct ExpandedView: View {
    @ObservedObject var store: IslandStore
    let notch: NotchMetrics
    @State private var shown: Bool

    init(store: IslandStore, notch: NotchMetrics) {
        self.store = store
        self.notch = notch
        _shown = State(initialValue: store.instantReveal)
    }

    var body: some View {
        VStack(spacing: 12) {
            header.reveal(shown, 0)
            if !store.liveActivities.isEmpty {
                LiveActivitiesView(activities: Array(store.liveActivities.prefix(2))).reveal(shown, 1)
            }
            if let music = store.music {
                NowPlayingView(music: music, artwork: store.artwork, shown: shown)
            }
            // The search box is added below what is already there; the island grows to make room for it.
            if store.searching {
                SearchView(model: store.search, onClose: store.endSearch)
                    .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.1)))
            }
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.bottom, Metrics.inset)
        .foregroundStyle(.white)
        .onAppear { shown = true }
        .contextMenu {
            Button(store.launchAtLogin ? "Don't Launch at Login" : "Launch at Login", action: store.toggleLaunchAtLogin)
            Button("Search…", action: store.beginSearch)
            if !store.focusReadable {
                Button("Enable Do Not Disturb Alerts…", action: store.openFocusAccessSettings)
            }
            if !store.accessibilityTrusted {
                Button("Enable Call & AirDrop Alerts…", action: store.openAccessibilitySettings)
            }
            Divider()
            Button("Quit NotchIsland") { NSApp.terminate(nil) }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            TimelineView(.periodic(from: .now, by: 20)) { context in
                VStack(alignment: .leading, spacing: 0) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 16, weight: .semibold))
                    Text(context.date, format: .dateTime.weekday(.wide).month().day())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: notch.width)
            Button { store.searching ? store.endSearch() : store.beginSearch() } label: {
                Image(systemName: store.searching ? "xmark.circle.fill" : "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressScale())
            .padding(.trailing, 6)
            if let b = store.battery {
                HStack(spacing: 5) {
                    Text("\(b.percent)%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .contentTransition(.numericText())
                    Image(systemName: b.charging ? "battery.100.bolt" : batterySymbol(b.percent))
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 15))
                        .foregroundStyle(b.onAC ? Color.green : (b.percent <= lowBatteryThreshold ? .red : .white))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .padding(.top, 6)
        .frame(height: notch.height + 8)
    }

    private func batterySymbol(_ p: Int) -> String {
        switch p {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

struct NowPlayingView: View {
    let music: MusicState
    let artwork: NSImage?
    let shown: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                art
                VStack(alignment: .leading, spacing: 3) {
                    Text(music.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(music.artist.isEmpty ? music.source.rawValue : music.artist)
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                .id(music.title + music.artist)
                .transition(.blurReplace)
                Spacer(minLength: 8)
                EqualizerBars(active: music.isPlaying).opacity(music.isPlaying ? 1 : 0.45)
            }
            .animation(.smooth(duration: 0.4), value: music.title)
            .reveal(shown, 1)
            progress.reveal(shown, 2)
            controls.reveal(shown, 3)
        }
    }

    private var art: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
                .fill(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "music.note").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
            if let artwork {
                Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
        // Paused artwork shrinks a little, like Apple's Now Playing.
        .scaleEffect(music.isPlaying ? 1 : 0.9)
        .animation(.spring(response: 0.45, dampingFraction: 0.65), value: music.isPlaying)
        .animation(.easeInOut(duration: 0.35), value: artwork)
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let now = context.date
            let fraction = music.progress(at: now) ?? 0
            HStack(spacing: 8) {
                Text(music.elapsed(at: now).map(formatClock) ?? "-:--").frame(width: 34, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        Capsule().fill(Color.white.opacity(0.9))
                            .frame(width: geo.size.width * fraction)
                            .animation(.linear(duration: 0.25), value: fraction)
                    }
                }
                .frame(height: 5)
                Text(music.duration.map { "-" + formatClock($0 - (music.elapsed(at: now) ?? 0)) } ?? "-:--")
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 40) {
            MediaButton(symbol: "backward.fill", size: 20, action: .previous, source: music.source)
            Button { MusicControl.playPause.send(to: music.source) } label: {
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .frame(width: 48, height: 48)
                    .glassCard(Circle(), tint: .white, interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(PressScale())
            .animation(.snappy, value: music.isPlaying)
            MediaButton(symbol: "forward.fill", size: 20, action: .next, source: music.source)
        }
    }
}

struct MediaButton: View {
    let symbol: String
    let size: CGFloat
    let action: MusicControl
    let source: MusicSource
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action.send(to: source)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size))
                .symbolEffect(.bounce, value: taps)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }
}

// MARK: - Live Activities in the expanded panel

struct LiveActivitiesView: View {
    let activities: [LiveActivity]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(activities) { a in
                HStack(spacing: 10) {
                    Image(systemName: a.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.named(a.tint))
                        .frame(width: 30, height: 30)
                        .background(Color.named(a.tint).opacity(0.18), in: Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text(a.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if !a.subtitle.isEmpty { Text(a.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 8)
                    if let end = a.endsAt {
                        Text(end, style: .timer).monospacedDigit().font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.named(a.tint))
                    } else if let progress = a.progress {
                        LevelBar(level: progress, tint: Color.named(a.tint))
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                .glassCard(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.blurReplace)
            }
        }
        .animation(Motion.morph, value: activities)
    }
}

// MARK: - Incoming call / AirDrop

struct AlertView: View {
    @ObservedObject var store: IslandStore
    let notch: NotchMetrics

    var body: some View {
        if let request = store.incoming {
            let isCall = request.kind == .call
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: isCall ? "phone.fill" : "airdrop")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isCall ? Color.green : .blue)
                    Text(isCall ? "Call" : "AirDrop").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: notch.width)
                }
                .padding(.horizontal, Metrics.inset)
                .frame(height: notch.height)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(request.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        Text(request.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    roundButton(isCall ? "phone.down.fill" : "xmark", .red) { store.respond(accept: false) }
                    roundButton(isCall ? "phone.fill" : "checkmark", .green) { store.respond(accept: true) }
                }
                .padding(.horizontal, Metrics.inset)
                .padding(.top, 6)
            }
            .foregroundStyle(.white)
        }
    }

    private func roundButton(_ symbol: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(tint, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
    }
}
