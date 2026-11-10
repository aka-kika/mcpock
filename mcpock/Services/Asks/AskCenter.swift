import Foundation
import Observation

/// The asks agents leave with `mcpock_ask` (1.16, Kika's design, 10 Nov):
/// read from mcpock's own `asks` folder, shown on the server's card with Yes
/// and No, a dot on the menu bar icon and one notification per new ask. Only
/// her Yes runs the usual switch (sheet first, backup kept); an ask with no
/// answer ends after a day and nothing changes. What became of each ask goes
/// to the status file, so the agent can read it.
@MainActor
@Observable
final class AskCenter {
    /// Asks waiting for her answer, oldest first.
    private(set) var waiting: [AgentAsk] = []
    /// Answered and ended asks of the last week, newest first.
    private(set) var answered: [AskRecord] = []

    @ObservationIgnored let folder: URL
    @ObservationIgnored let historyFile: URL
    @ObservationIgnored private let now: () -> Date
    /// The status file and the icon follow.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Asks seen for the first time: one notification each.
    @ObservationIgnored var onNew: (([AgentAsk]) -> Void)?
    /// Asks answered or ended: their notifications go.
    @ObservationIgnored var onGone: (([String]) -> Void)?
    /// Ids already notified, kept across launches so a relaunch never
    /// notifies the same ask twice.
    @ObservationIgnored private var notified: Set<String> = []
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var timer: Timer?

    static let keptFor: TimeInterval = 7 * 24 * 3600
    static let keptAtMost = 50

    init(folder: URL = AskBox.directory(), historyFile: URL = MCPockStatus.defaultDirectory().appendingPathComponent("asks-answered.json"),
         now: @escaping () -> Date = Date.init) {
        self.folder = folder
        self.historyFile = historyFile
        self.now = now
    }

    var hasWaiting: Bool { !waiting.isEmpty }

    /// The asks for one server (the card's row), oldest first.
    func asks(for server: String) -> [AgentAsk] {
        let key = HealthMonitor.normalizedName(server)
        return waiting.filter { HealthMonitor.normalizedName($0.server) == key }
    }

    func ask(id: String) -> AgentAsk? {
        waiting.first { $0.id == id }
    }

    /// Waiting asks and the week's answers, for the status file.
    var records: [AskRecord] {
        waiting.map { AskRecord(id: $0.id, server: $0.server, tool: $0.tool, action: $0.action, agent: $0.agent,
                                asked: $0.asked, state: .waiting, answered: nil) } + answered
    }

    // MARK: Reading

    /// Loads the history, reads the folder and watches it from now on.
    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        _ = chmod(folder.path, 0o700)
        loadHistory()
        reload()
        watch()
        // Asks end after a day even when nothing else happens.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    /// Reads the folder: new asks are shown (and notified once), ended ones
    /// are recorded and their files removed, anything that is not a real ask
    /// is removed unread.
    func reload() {
        let read = AskBox.read(from: folder, now: now())
        for name in read.rejected { unlink(folder.appendingPathComponent(name).path) }
        var changed = !read.rejected.isEmpty
        for ask in read.expired {
            record(ask, state: .expired)
            changed = true
        }
        if read.asks != waiting {
            waiting = read.asks
            changed = true
        }
        let fresh = waiting.filter { !notified.contains($0.id) }
        if !fresh.isEmpty {
            notified.formUnion(fresh.map(\.id))
            onNew?(fresh)
        }
        // Only ids still waiting need remembering.
        let waitingIDs = Set(waiting.map(\.id))
        if !notified.isSubset(of: waitingIDs) || !fresh.isEmpty {
            notified.formIntersection(waitingIDs)
            saveHistory()
        }
        if changed { onChange?() }
    }

    // MARK: Answers

    /// She pressed No: nothing changes, the agent reads "no".
    func answerNo(_ id: String) {
        guard let ask = ask(id: id) else { return }
        record(ask, state: .no)
        waiting.removeAll { $0.id == id }
        onChange?()
    }

    /// Her Yes went through the usual switch and it was written (or there was
    /// nothing left to change).
    func completed(_ id: String) {
        guard let ask = ask(id: id) else { return }
        record(ask, state: .done)
        waiting.removeAll { $0.id == id }
        onChange?()
    }

    private func record(_ ask: AgentAsk, state: AskRecord.State) {
        unlink(folder.appendingPathComponent(ask.id + ".json").path)
        onGone?([ask.id])
        answered.removeAll { $0.id == ask.id }
        answered.insert(AskRecord(id: ask.id, server: ask.server, tool: ask.tool, action: ask.action, agent: ask.agent,
                                  asked: ask.asked, state: state, answered: now()), at: 0)
        prune()
        saveHistory()
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.keptFor)
        answered = Array(answered.filter { ($0.answered ?? $0.asked) >= cutoff }.prefix(Self.keptAtMost))
    }

    // MARK: History file

    private struct History: Codable {
        var answered: [AskRecord]
        var notified: [String]
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyFile),
              let history = try? MCPockStatus.decoder().decode(History.self, from: data) else { return }
        answered = history.answered
        notified = Set(history.notified)
        prune()
    }

    private func saveHistory() {
        let history = History(answered: answered, notified: notified.sorted())
        guard let data = try? MCPockStatus.encoder().encode(history) else { return }
        try? StatusWriter.writePrivate(data, to: historyFile)
    }

    // MARK: Watching

    private func watch() {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        timer?.invalidate()
        timer = nil
    }
}
