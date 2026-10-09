import Foundation
import XCTest
@testable import mcpock

/// Test-only convenience sources for the built-in agents, for readable fixtures.
/// (Production code builds its labels in `AgentRegistry` and never uses these.)
extension ServerSource {
    static let code = ServerSource(label: "Code")
    static let desktop = ServerSource(label: "Desktop")
    static let cursor = ServerSource(label: "Cursor")
    static let grok = ServerSource(label: "Grok")
    static let goose = ServerSource(label: "Goose")
}

/// `removePersistentDomain(forName:)` empties a suite but leaves its `.plist`
/// behind in `~/Library/Preferences` (found 2026-09-25: ~800 of these piled
/// up from throwaway test suites), because cfprefsd writes the emptied
/// domain back to disk on its own schedule, out of process. Deleting the
/// file right in `tearDown` (even after `synchronize()`) often loses that
/// race: the actual write can land after the test — sometimes only once the
/// whole test host process is winding down, i.e. after this bundle's own
/// `testBundleDidFinish` sweep has already run and returned. So this catches
/// most of them, and `scripts/ci.sh` sweeps the same suite-name patterns
/// again right after `xcodebuild test` returns — by then the test host
/// process is fully gone and cfprefsd's writes have landed for sure. Together
/// the two have been leak-free across repeated full runs; neither alone was.
private final class SuiteCleanup: NSObject, XCTestObservation {
    static let shared = SuiteCleanup()
    private let lock = NSLock()
    private var suites: Set<String> = []
    private var registered = false

    func register(_ suite: String) {
        lock.lock()
        suites.insert(suite)
        if !registered {
            registered = true
            XCTestObservationCenter.shared.addTestObserver(self)
        }
        lock.unlock()
    }

    private func deleteFiles(for names: [String]) -> Bool {
        var anyLeft = false
        for suite in names {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: url)
            if FileManager.default.fileExists(atPath: url.path) { anyLeft = true }
        }
        return anyLeft
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let names: [String]
        lock.lock(); names = Array(suites); lock.unlock()
        guard !names.isEmpty else { return }
        for _ in 0..<12 {
            guard deleteFiles(for: names) else { return }
            usleep(100_000)
        }
    }
}

extension UserDefaults {
    /// Empties `suite`, tries to delete its `.plist` right away, and also
    /// registers it for the end-of-bundle sweep (see `SuiteCleanup`) since a
    /// same-turn delete alone doesn't reliably win the race with cfprefsd's
    /// own flush. Test-only: call this from `tearDown` on a suite name this
    /// test made up, never on `.standard`.
    func retireSuite(named suite: String) {
        SuiteCleanup.shared.register(suite)
        removePersistentDomain(forName: suite)
        synchronize()
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: url)
    }
}
