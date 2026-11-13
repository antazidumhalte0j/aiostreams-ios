import Foundation
import Network
import UIKit

/**
 * The page's downloads, as the Android and desktop apps' queues keep them (upstream
 * `packages/android/downloads`): the page hands over files to fetch and texts to write, and the
 * queue reports `download-state` and `download-progress` back. Videos go through a background
 * URLSession, so they carry on while the app is closed and resume from where they stopped;
 * subtitles and art come beside them and never cost the video. The queue outlives the app.
 *
 * Ported from the 9pbpsvr6f9-alt/aiostreams-ios fork.
 */
@MainActor
final class DownloadQueue: NSObject {
    static let shared = DownloadQueue()

    struct SpecFile: Codable {
        let url: String
        let path: String
        let kind: String
        var headers: [String: String]?
    }

    struct SpecText: Codable {
        let path: String
        let text: String
    }

    struct Spec: Codable {
        let id: String
        let title: String
        let versionId: String
        let files: [SpecFile]
        var texts: [SpecText]?
    }

    enum State: String, Codable {
        case queued, downloading, paused, failed, done
    }

    struct Job: Codable {
        var spec: Spec
        var state: State = .queued
        var bytes: Int64 = 0
        var total: Int64?
        var error: String?
        /// Bytes of the job's earlier videos, where it has more than one.
        var finished: Int64 = 0
    }

    private struct Saved: Codable {
        var concurrent = 2
        var wifiOnly = true
        /// Downloads that may use a cellular network while `wifiOnly` holds the rest.
        var cellular: [String] = []
        var jobs: [Job] = []
    }

    /// Messages for the page.
    var send: (([String: Any]) -> Void)?
    /// iOS's handler for background transfer events that relaunched the app.
    var backgroundCompletion: (() -> Void)?

    nonisolated let folder: URL
    nonisolated let incoming: URL
    private let stateFile: URL
    private var saved = Saved()
    private var running: [String: URLSessionDownloadTask] = [:]
    private var extras: [String: Task<Void, Never>] = [:]
    /// Tasks cancelled on purpose (pause, a network change, removal), not failed.
    private var stopping: Set<String> = []
    /// A transfer's own failure (an HTTP error, a file that would not move), noted by the delegate
    /// before its completion arrives; locked, as the two callbacks reach the queue in either order.
    private nonisolated let failures = Failures()
    private var speeds: [String: (since: TimeInterval, from: Int64, value: Int64)] = [:]
    private var expensive = false
    private var restored = false
    private let monitor = NWPathMonitor()
    private var timer: Timer?
    private let small: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    static let sessionID = "io.github.aiostreams-ios.downloads"
    private static let maxConcurrent = 4

    private override init() {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        var folder = support.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Episodes can be many gigabytes: never in iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        self.folder = folder
        incoming = support.appendingPathComponent("Downloads-incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        stateFile = support.appendingPathComponent("downloads.json")
        super.init()
        if let data = try? Data(contentsOf: stateFile),
           let loaded = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = loaded
        }
        for i in saved.jobs.indices where saved.jobs[i].state == .downloading { saved.jobs[i].state = .queued }
        monitor.pathUpdateHandler = { [weak self] path in
            let costly = path.isExpensive || path.isConstrained
            Task { @MainActor in self?.networkChanged(expensive: costly) }
        }
        monitor.start(queue: DispatchQueue(label: "downloads.network"))
        // Transfers a previous launch started may still be running in the background.
        session.getAllTasks { tasks in
            let found = tasks.compactMap { task -> (String, Int, URLSessionDownloadTask)? in
                guard let download = task as? URLSessionDownloadTask,
                      let (id, index) = Self.parse(task.taskDescription) else { task.cancel(); return nil }
                return (id, index, download)
            }
            Task { @MainActor in self.reattach(found) }
        }
    }

    // MARK: - The page's messages

    /// False for a message that isn't about downloads.
    func handle(_ type: String, _ message: [String: Any]) -> Bool {
        switch type {
        case "download-add": add(message["jobs"])
        case "download-control":
            guard let id = message["id"] as? String else { return true }
            switch message["action"] as? String {
            case "pause": pause(id)
            case "resume": change(id, from: [.paused], to: .queued)
            case "retry": change(id, from: [.failed], to: .queued)
            default: break
            }
        case "download-remove":
            guard let id = message["id"] as? String else { return true }
            remove(id, files: JSON.flag(message["files"]) == true)
        case "download-list": changed()
        case "download-config":
            let concurrent = Int(JSON.number(message["concurrent"]) ?? 2)
            let wifiOnly = JSON.flag(message["wifiOnly"]) ?? true
            saved.concurrent = min(max(concurrent, 1), Self.maxConcurrent)
            if saved.wifiOnly != wifiOnly {
                saved.wifiOnly = wifiOnly
                restartMismatched()
            }
            changed()
        case "download-cellular":
            // Smart downloads' cellular allowance, by download id.
            saved.cellular = JSON.strings(message["ids"])
            restartMismatched()
            changed()
        default: return false
        }
        return true
    }

    /// A finished download's video or subtitle, which playback may open.
    func localFile(_ text: String) -> URL? {
        guard DownloadPlaces.isInside(folder, text) else { return nil }
        let path = text.hasPrefix("file://") ? (URL(string: text)?.path ?? "") : text
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - The queue

    private func add(_ value: Any?) {
        guard let raw = value, JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let specs = try? JSONDecoder().decode([Spec].self, from: data) else { return }
        for spec in specs where !saved.jobs.contains(where: { $0.spec.id == spec.id }) {
            do {
                try check(spec)
                saved.jobs.append(Job(spec: spec))
            } catch {
                AppLog.warn("downloads", "download \(spec.id): \(error.localizedDescription)")
                send?(["type": "error", "message": "Can't download \(spec.title): \(error.localizedDescription)"])
            }
        }
        changed()
    }

    private func check(_ spec: Spec) throws {
        let idOK = !spec.id.isEmpty && spec.id.count <= 64
            && spec.id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        guard idOK else { throw DownloadPlaces.Refused(message: "bad id") }
        for file in spec.files {
            guard let scheme = URL(string: file.url)?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                throw DownloadPlaces.Refused(message: "only http(s) addresses")
            }
            _ = try DownloadPlaces.place(folder, file.path)
        }
        for text in spec.texts ?? [] { _ = try DownloadPlaces.place(folder, text.path) }
    }

    private func index(_ id: String) -> Int? { saved.jobs.firstIndex { $0.spec.id == id } }

    private func change(_ id: String, from: Set<State>, to state: State) {
        guard let i = index(id), from.contains(saved.jobs[i].state) else { return }
        saved.jobs[i].state = state
        saved.jobs[i].error = nil
        changed()
    }

    private func pause(_ id: String) {
        guard let i = index(id), saved.jobs[i].state != .done else { return }
        stop(id, keepingResume: true)
        saved.jobs[i].state = .paused
        changed()
    }

    private func remove(_ id: String, files: Bool) {
        guard let i = index(id) else { return }
        let job = saved.jobs.remove(at: i)
        stop(id, keepingResume: false)
        try? FileManager.default.removeItem(at: resumeFile(id))
        saved.cellular.removeAll { $0 == id }
        if files { deleteFiles(of: job) }
        changed()
    }

    /// Whether the job may download on the network there is now.
    private func mayRun(_ id: String) -> Bool {
        !saved.wifiOnly || !expensive || saved.cellular.contains(id)
    }

    /// Whether the job's requests may use a cellular or other costly network.
    private func mayUseCellular(_ id: String) -> Bool {
        !saved.wifiOnly || saved.cellular.contains(id)
    }

    private func networkChanged(expensive costly: Bool) {
        guard costly != expensive else { return }
        expensive = costly
        changed()
    }

    /// Running transfers whose requests were made under other network rules start again.
    private func restartMismatched() {
        for (id, task) in running {
            let allowed = mayUseCellular(id)
            if task.originalRequest?.allowsExpensiveNetworkAccess != allowed, let i = index(id) {
                stop(id, keepingResume: true)
                saved.jobs[i].state = .queued
            }
        }
    }

    /// Starts what may run, holds what may not, saves the queue and tells the page.
    private func changed() {
        if restored {
            for (id, _) in running where !mayRun(id) {
                stop(id, keepingResume: true)
                if let i = index(id) { saved.jobs[i].state = .queued }
            }
            var free = saved.concurrent - running.count
            for job in saved.jobs where free > 0 && job.state == .queued && running[job.spec.id] == nil && mayRun(job.spec.id) {
                start(job.spec.id)
                free -= 1
            }
        }
        save()
        send?(stateMessage())
        updateTimer()
    }

    private func start(_ id: String) {
        guard let i = index(id) else { return }
        saved.jobs[i].state = .downloading
        saved.jobs[i].error = nil
        let spec = saved.jobs[i].spec
        writeTexts(spec)
        if extras[id] == nil {
            let files = spec.files.filter { $0.kind != "video" }
            let folder = self.folder
            let small = self.small
            extras[id] = Task.detached(priority: .utility) {
                await Self.fetchExtras(files, into: folder, session: small, id: id)
            }
        }
        startVideo(id, index: 0)
    }

    private func writeTexts(_ spec: Spec) {
        for text in spec.texts ?? [] {
            guard let file = try? DownloadPlaces.place(folder, text.path),
                  !FileManager.default.fileExists(atPath: file.path) else { continue }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Subtitles and art, beside the video; one missing never costs the download.
    private nonisolated static func fetchExtras(_ files: [SpecFile], into folder: URL, session: URLSession, id: String) async {
        for file in files {
            guard !Task.isCancelled, let url = URL(string: file.url),
                  let target = try? DownloadPlaces.place(folder, file.path),
                  !FileManager.default.fileExists(atPath: target.path) else { continue }
            var request = URLRequest(url: url)
            for (name, value) in file.headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw DownloadPlaces.Refused(message: "HTTP \(http.statusCode)")
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            } catch {
                AppLog.warn("downloads", "download \(id): skipped \(file.path): \(error.localizedDescription)")
            }
        }
    }

    private func videos(_ id: String) -> [SpecFile] {
        index(id).map { saved.jobs[$0].spec.files.filter { $0.kind == "video" } } ?? []
    }

    private func startVideo(_ id: String, index position: Int) {
        let files = videos(id)
        guard position < files.count else { return finishJob(id) }
        let file = files[position]
        guard let target = try? DownloadPlaces.place(folder, file.path) else { return fail(id, "bad file name") }
        if FileManager.default.fileExists(atPath: target.path) { return startVideo(id, index: position + 1) }
        guard let url = URL(string: file.url) else { return fail(id, "bad address") }
        var request = URLRequest(url: url)
        for (name, value) in file.headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        let cellular = mayUseCellular(id)
        request.allowsExpensiveNetworkAccess = cellular
        request.allowsCellularAccess = cellular
        request.allowsConstrainedNetworkAccess = cellular
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeFile(id)) {
            try? FileManager.default.removeItem(at: resumeFile(id))
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: request)
        }
        task.taskDescription = "\(id)#\(position)"
        running[id] = task
        task.resume()
    }

    /// Cancels a running transfer on purpose, keeping what it fetched to resume from.
    private func stop(_ id: String, keepingResume: Bool) {
        extras.removeValue(forKey: id)?.cancel()
        guard let task = running.removeValue(forKey: id) else { return }
        stopping.insert(id)
        speeds[id] = nil
        if keepingResume {
            let file = resumeFile(id)
            task.cancel(byProducingResumeData: { data in try? data?.write(to: file, options: .atomic) })
        } else {
            task.cancel()
        }
    }

    private func reattach(_ found: [(String, Int, URLSessionDownloadTask)]) {
        for (id, _, task) in found {
            if let i = index(id), saved.jobs[i].state == .queued, running[id] == nil {
                saved.jobs[i].state = .downloading
                running[id] = task
                writeTexts(saved.jobs[i].spec)
            } else {
                task.cancel()
            }
        }
        restored = true
        changed()
    }

    private func videoArrived(_ id: String, position: Int, staged: URL) {
        guard let i = index(id), saved.jobs[i].state == .downloading,
              let file = videos(id).dropFirst(position).first,
              let target = try? DownloadPlaces.place(folder, file.path) else {
            try? FileManager.default.removeItem(at: staged)
            return
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: staged, to: target)
            let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            saved.jobs[i].finished += size
        } catch {
            try? FileManager.default.removeItem(at: staged)
            fail(id, error.localizedDescription)
            return
        }
        running[id] = nil
        startVideo(id, index: position + 1)
    }

    private func finishJob(_ id: String) {
        running[id] = nil
        let pending = extras.removeValue(forKey: id)
        Task { @MainActor in
            await pending?.value
            guard let i = self.index(id), self.saved.jobs[i].state == .downloading else { return }
            self.saved.jobs[i].state = .done
            self.saved.jobs[i].bytes = max(self.saved.jobs[i].bytes, self.saved.jobs[i].finished)
            self.saved.jobs[i].total = self.saved.jobs[i].bytes
            self.saved.cellular.removeAll { $0 == id }
            self.speeds[id] = nil
            AppLog.info("downloads", "download \(id) done")
            self.changed()
        }
    }

    private func fail(_ id: String, _ message: String) {
        running[id] = nil
        extras.removeValue(forKey: id)?.cancel()
        speeds[id] = nil
        guard let i = index(id) else { return changed() }
        AppLog.warn("downloads", "download failed id=\(id): \(message)")
        saved.jobs[i].state = .failed
        saved.jobs[i].error = message
        changed()
    }

    private func progress(_ id: String, written: Int64, expected: Int64) {
        guard let i = index(id), saved.jobs[i].state == .downloading else { return }
        saved.jobs[i].bytes = saved.jobs[i].finished + written
        if expected > 0 { saved.jobs[i].total = saved.jobs[i].finished + expected }
    }

    // MARK: - Reports

    private func stateMessage() -> [String: Any] {
        let jobs: [[String: Any]] = saved.jobs.map { job in
            var entry: [String: Any] = [
                "id": job.spec.id,
                "state": job.state.rawValue,
                "bytes": job.bytes,
                "total": job.total.map { $0 as Any } ?? NSNull(),
                "error": JSON.orNull(job.error),
            ]
            if job.state == .done {
                let placed = job.spec.files.compactMap { file -> (String, URL)? in
                    guard file.kind != "image", let url = try? DownloadPlaces.place(folder, file.path) else { return nil }
                    return (file.kind, url)
                }
                entry["video"] = JSON.orNull(placed.first { $0.0 == "video" }?.1.path)
                entry["subtitles"] = placed.filter { $0.0 == "subtitle" }.map { $0.1.path }
            }
            return entry
        }
        // The page writes "Saved to" before it: "Saved to this iPhone".
        return ["type": "download-state", "folder": "this \(UIDevice.current.model)", "jobs": jobs]
    }

    private func updateTimer() {
        let busy = saved.jobs.contains { $0.state == .downloading }
        if busy, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reportProgress() }
            }
        } else if !busy {
            timer?.invalidate()
            timer = nil
        }
    }

    private func reportProgress() {
        let now = ProcessInfo.processInfo.systemUptime
        for job in saved.jobs where job.state == .downloading {
            let id = job.spec.id
            var speed = speeds[id] ?? (since: now, from: job.bytes, value: 0)
            // Measured over a few seconds, so the number holds still enough to read.
            if now - speed.since >= 2 {
                speed.value = max(0, Int64(Double(job.bytes - speed.from) / (now - speed.since)))
                speed.since = now
                speed.from = job.bytes
            }
            speeds[id] = speed
            send?(["type": "download-progress", "id": id, "bytes": job.bytes,
                   "total": job.total.map { $0 as Any } ?? NSNull(), "speed": speed.value])
        }
    }

    // MARK: - Files

    private func resumeFile(_ id: String) -> URL { incoming.appendingPathComponent("\(id).resume") }

    private func save() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: stateFile, options: .atomic)
    }

    /// Leaves files another download still uses, such as a show's poster.
    private func deleteFiles(of job: Job) {
        let others = Set(saved.jobs.flatMap { paths(of: $0) }.map(\.path))
        for file in paths(of: job) where !others.contains(file.path) {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: DownloadPlaces.part(of: file))
            // Empty folders up to the downloads folder go too.
            var dir = file.deletingLastPathComponent()
            while dir.path.hasPrefix(folder.path + "/"),
                  (try? FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: dir)
                dir = dir.deletingLastPathComponent()
            }
        }
    }

    private func paths(of job: Job) -> [URL] {
        (job.spec.files.map(\.path) + (job.spec.texts ?? []).map(\.path))
            .compactMap { try? DownloadPlaces.place(folder, $0) }
    }

    nonisolated static func parse(_ description: String?) -> (String, Int)? {
        guard let parts = description?.split(separator: "#"), parts.count == 2,
              let position = Int(parts[1]) else { return nil }
        return (String(parts[0]), position)
    }
}

extension DownloadQueue: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let (id, _) = Self.parse(downloadTask.taskDescription) else { return }
        Task { @MainActor in self.progress(id, written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let (id, position) = Self.parse(downloadTask.taskDescription) else { return }
        // The file goes when this returns, so it moves out of the way here, before the hop to the queue.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failures.set(downloadTask.taskIdentifier, "HTTP \(http.statusCode)")
            return
        }
        let staged = incoming.appendingPathComponent("\(id)-\(position).download")
        try? FileManager.default.removeItem(at: staged)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            failures.set(downloadTask.taskIdentifier, error.localizedDescription)
            return
        }
        Task { @MainActor in self.videoArrived(id, position: position, staged: staged) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let (id, _) = Self.parse(task.taskDescription) else { return }
        // Taken now, on the delegate's queue, which already ran didFinishDownloadingTo for this task.
        let failure = failures.take(task.taskIdentifier)
        let resume = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let message = error?.localizedDescription
        Task { @MainActor in
            if self.stopping.remove(id) != nil { return }
            if let resume { try? resume.write(to: self.resumeFile(id), options: .atomic) }
            if let failure {
                self.fail(id, failure)
            } else if let message {
                self.fail(id, message)
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

/// Failures by task, shared between the delegate's queue and the queue's actor.
final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var byTask: [Int: String] = [:]

    func set(_ task: Int, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        byTask[task] = message
    }

    func take(_ task: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return byTask.removeValue(forKey: task)
    }
}
