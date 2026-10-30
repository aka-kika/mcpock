import Foundation

/// Notices when a config file changes, so a fix turns green without a click
/// (1.13). It only watches and calls back: it never writes, and it starts
/// nothing itself. Only the known agents' files and the scan-found files she
/// already allowed are watched.
///
/// A file and the folder it sits in, each with a `DispatchSource` on an
/// `O_EVTONLY` descriptor: an editor that saves by rename replaces the file, so
/// only the folder sees that, and an agent that writes in place changes only the
/// file. A file that isn't there yet is watched through its nearest existing
/// folder. FSEvents would have to be rooted at the home folder for
/// `~/.claude.json`, and hand over every change under it.
///
/// A folder's event says little (`~` changes all day), so what counts is
/// whether a watched file's inode, size or modified time moved.
final class ConfigWatcher: @unchecked Sendable {
    /// What identifies one state of a file; nil while it isn't there.
    struct Signature: Equatable {
        let inode: UInt64
        let size: Int64
        let modified: timespec

        static func == (a: Signature, b: Signature) -> Bool {
            a.inode == b.inode && a.size == b.size
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    static func signature(of path: String) -> Signature? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Signature(inode: info.st_ino, size: info.st_size, modified: info.st_mtimespec)
    }

    /// The paths whose signature differs between two looks. Pure.
    static func changed(from old: [String: Signature?], to new: [String: Signature?]) -> Set<String> {
        Set(new.keys.filter { (new[$0] ?? nil) != (old[$0] ?? nil) })
    }

    /// The folder to watch for `path`: its own, or the nearest parent that exists.
    static func nearestFolder(of path: String, exists: (String) -> Bool = ConfigWatcher.isFolder) -> String {
        var folder = (path as NSString).deletingLastPathComponent
        while !folder.isEmpty, folder != "/", !exists(folder) {
            folder = (folder as NSString).deletingLastPathComponent
        }
        return folder.isEmpty ? "/" : folder
    }

    static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private let queue = DispatchQueue(label: "mcpock.config-watcher", qos: .utility)
    private let settle: DispatchTimeInterval
    private let minimumGap: TimeInterval
    private let onChange: @Sendable () -> Void

    // Only touched on `queue`.
    private var paths: [String] = []
    private var signatures: [String: Signature?] = [:]
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: DispatchWorkItem?
    private var lastFired: Date?
    private var stopped = false

    /// `settle`: how long a file must stay quiet before it counts, so a read
    /// never lands in the middle of a write. `minimumGap`: at most one callback
    /// per this long, since some agents rewrite their file every few seconds.
    init(settle: DispatchTimeInterval = .milliseconds(1500), minimumGap: TimeInterval = 10,
         onChange: @escaping @Sendable () -> Void) {
        self.settle = settle
        self.minimumGap = minimumGap
        self.onChange = onChange
    }

    /// Watch these paths from now on; a call with the same list changes nothing.
    func watch(_ newPaths: [String]) {
        let sorted = Array(Set(newPaths)).sorted()
        queue.async { [self] in
            guard !stopped, sorted != paths else { return }
            paths = sorted
            signatures = Dictionary(uniqueKeysWithValues: sorted.map { ($0, Self.signature(of: $0)) })
            arm()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            pending?.cancel()
            pending = nil
            sources.values.forEach { $0.cancel() }
            sources = [:]
        }
    }

    /// One source per file that exists and per folder, dropping the ones no
    /// longer wanted. An old source on a replaced file is cancelled, so its
    /// descriptor doesn't hold the deleted file open.
    private func arm() {
        var wanted = Set(paths.map { Self.nearestFolder(of: $0) })
        wanted.formUnion(paths.filter { (signatures[$0] ?? nil) != nil })
        for (path, source) in sources where !wanted.contains(path) {
            source.cancel()
            sources[path] = nil
        }
        for path in wanted where sources[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib, .revoke], queue: queue)
            source.setEventHandler { [weak self] in self?.somethingMoved(path: path, source: source) }
            source.setCancelHandler { close(fd) }
            sources[path] = source
            source.resume()
        }
    }

    private func somethingMoved(path: String, source: DispatchSourceFileSystemObject) {
        // A replaced file: this descriptor points at the old one from here on.
        if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
            source.cancel()
            sources[path] = nil
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settled() }
        pending = work
        queue.asyncAfter(deadline: .now() + settle, execute: work)
    }

    private func settled() {
        pending = nil
        guard !stopped else { return }
        let now = Dictionary(uniqueKeysWithValues: paths.map { ($0, Self.signature(of: $0)) })
        let moved = Self.changed(from: signatures, to: now)
        signatures = now
        arm()
        guard !moved.isEmpty else { return }
        let wait = lastFired.map { minimumGap - Date().timeIntervalSince($0) } ?? 0
        if wait > 0 {
            let work = DispatchWorkItem { [weak self] in self?.fire() }
            pending = work
            queue.asyncAfter(deadline: .now() + wait, execute: work)
        } else {
            fire()
        }
    }

    private func fire() {
        pending = nil
        guard !stopped else { return }
        lastFired = Date()
        onChange()
    }
}
