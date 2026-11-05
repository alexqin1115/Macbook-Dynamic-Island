import AppKit
import IslandCore
import SwiftUI

struct SearchResult: Identifiable {
    enum Action {
        case open(URL)
        case copy(String)
    }

    let id: String
    let title: String
    let subtitle: String
    let icon: NSImage?
    let symbol: String?
    let action: Action
}

/// Spotlight-style search over the Spotlight index, plus a calculator and a web fallback.
@MainActor
final class SearchModel: ObservableObject {
    @Published var query = "" {
        didSet { schedule() }
    }
    @Published private(set) var results: [SearchResult] = []
    @Published var selected = 0

    private var metadata: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var debounce: Task<Void, Never>?

    func reset() {
        debounce?.cancel()
        stopQuery()
        query = ""
        results = []
        selected = 0
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = min(max(selected + delta, 0), results.count - 1)
    }

    /// Opens the highlighted result; returns whether anything happened.
    @discardableResult
    func activateSelected() -> Bool {
        guard results.indices.contains(selected) else { return false }
        switch results[selected].action {
        case .open(let url): NSWorkspace.shared.open(url)
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        return true
    }

    private func schedule() {
        debounce?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            stopQuery()
            results = []
            return
        }
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            self?.run(text)
        }
    }

    private func stopQuery() {
        metadata?.stop()
        metadata = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func run(_ text: String) {
        stopQuery()
        var head: [SearchResult] = []
        if let value = Calculator.evaluate(text) {
            head.append(SearchResult(id: "calc", title: "= \(value)", subtitle: "Calculator · Return to copy", icon: nil,
                                     symbol: "equal.square.fill", action: .copy(value)))
        }
        results = head + [webResult(text)]
        selected = 0

        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemDisplayName CONTAINS[cd] %@", text)
        q.searchScopes = [NSMetadataQueryLocalComputerScope]
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(q, text: text, head: head) }
        }
        metadata = q
        q.start()
    }

    private func webResult(_ text: String) -> SearchResult {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        return SearchResult(id: "web", title: "Search the web for “\(text)”", subtitle: "Opens your browser", icon: nil, symbol: "globe",
                            action: .open(URL(string: "https://www.google.com/search?q=\(encoded)")!))
    }

    private func finish(_ q: NSMetadataQuery, text: String, head: [SearchResult]) {
        q.disableUpdates()
        let lower = text.lowercased()
        var scored: [(Int, SearchResult)] = []
        for case let item as NSMetadataItem in q.results.prefix(400) {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let name = item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String ?? (path as NSString).lastPathComponent
            let isApp = (item.value(forAttribute: NSMetadataItemContentTypeKey) as? String) == "com.apple.application-bundle"
            let lname = name.lowercased()
            var score = isApp ? 100 : 0
            if lname == lower { score += 60 } else if lname.hasPrefix(lower) { score += 40 }
            else if lname.split(separator: " ").contains(where: { $0.hasPrefix(lower) }) { score += 20 }
            if !isApp && (path.contains("/Library/") || path.hasPrefix("/System") || path.contains("/.")) { score -= 50 }
            scored.append((score, SearchResult(id: path, title: name, subtitle: (path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                                               icon: nil, symbol: nil, action: .open(URL(fileURLWithPath: path)))))
        }
        let top = scored.sorted { $0.0 > $1.0 }.prefix(5 - head.count - 1).map { entry -> SearchResult in
            let r = entry.1
            return SearchResult(id: r.id, title: r.title, subtitle: r.subtitle, icon: NSWorkspace.shared.icon(forFile: r.id), symbol: nil, action: r.action)
        }
        results = head + top + [webResult(text)]
        selected = min(selected, max(results.count - 1, 0))
        stopQuery()
    }
}

struct SearchView: View {
    @ObservedObject var model: SearchModel
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps, files, or calculate", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { if model.activateSelected() { onClose() } }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onKeyPress(.escape) { onClose(); return .handled }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .glassCard(Capsule())

            VStack(spacing: 2) {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                    row(result, highlighted: index == model.selected)
                        .onTapGesture {
                            model.selected = index
                            if model.activateSelected() { onClose() }
                        }
                }
            }
            .animation(.snappy(duration: 0.2), value: model.results.map(\.id))
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { focused = true }
        }
    }

    private func row(_ result: SearchResult, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon = result.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: result.symbol ?? "doc").font(.system(size: 15)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(result.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(result.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(highlighted ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}
