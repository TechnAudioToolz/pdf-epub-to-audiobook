import AppKit
import Foundation

/// Remembers the books and MP3 jobs between launches, in ~/Library/Application Support/Audiobook Maker/queue.json.
/// Finished items stay finished; the queue's order comes back, but nothing starts until you press Start.
struct SavedQueue: Codable {
    struct Item: Codable {
        var paths: [String]            // a book's file, or an MP3 job's files in order
        var isJob = false
        var title = ""
        var author = ""
        var cover: String?             // an image the user chose
        var oneFile = false
        var finished: String?          // "done" or "skipped"
        var output: String?
        var queuePosition: Int?        // 0 = was being made when the app closed
    }
    var items: [Item]
}

extension AppModel {
    static var queueFile: URL {
        if let override = UserDefaults.standard.string(forKey: "queueFileOverride") {  // testing only
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audiobook Maker/queue.json")
    }

    private func savedState() -> SavedQueue {
        func position(_ id: UUID, rendering: Bool) -> Int? {
            rendering ? 0 : queuePosition(id)
        }
        func finished(_ state: BookState) -> String? {
            state == .done ? "done" : state == .skipped ? "skipped" : nil
        }
        let books = self.books.map { b in
            SavedQueue.Item(paths: [b.url.path], title: b.title, author: b.author, cover: b.coverURL?.path,
                            oneFile: b.oneFile, finished: finished(b.state), output: b.output?.path,
                            queuePosition: position(b.id, rendering: b.state == .rendering))
        }
        let jobs = self.jobs.map { j in
            SavedQueue.Item(paths: j.sources.map(\.path), isJob: true, title: j.title, author: j.author,
                            cover: j.coverURL?.path, finished: finished(j.state), output: j.output?.path,
                            queuePosition: position(j.id, rendering: j.state == .rendering))
        }
        return SavedQueue(items: books + jobs)
    }

    /// Writes queue.json if anything changed since the last save. Cheap enough to call every few seconds.
    func saveQueue() {
        guard persistQueue, let data = try? JSONEncoder().encode(savedState()), data != lastSavedQueue else { return }
        let file = Self.queueFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: file, options: .atomic)) != nil { lastSavedQueue = data }
    }

    /// At launch: brings back the list from last time, then keeps it saved.
    func restoreQueue() {
        guard persistQueue else { return }
        defer {
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.saveQueue() }
            }
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveQueue() }
            }
        }
        guard let data = try? Data(contentsOf: Self.queueFile),
              let saved = try? JSONDecoder().decode(SavedQueue.self, from: data) else { return }
        lastSavedQueue = data
        let fm = FileManager.default
        var missing = 0
        var order: [(Int, UUID)] = []
        for item in saved.items {
            let urls = item.paths.map { URL(fileURLWithPath: $0) }.filter { fm.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { missing += 1; continue }
            let finishedState: BookState? = item.finished == "done" ? .done : item.finished == "skipped" ? .skipped : nil
            if item.isJob {
                let job = AudioJob(sources: urls)
                job.title = item.title
                job.author = item.author
                if let finishedState { job.state = finishedState }
                job.output = item.output.map { URL(fileURLWithPath: $0) }
                jobs.append(job)
                if let cover = item.cover, fm.fileExists(atPath: cover) { setJobCover(URL(fileURLWithPath: cover), for: job) }
                if let p = item.queuePosition, finishedState == nil { job.queued = true; order.append((p, job.id)) }
                checkJob(job)
            } else {
                let book = Book(url: urls[0])
                book.title = item.title
                book.author = item.author
                book.oneFile = item.oneFile
                if let finishedState { book.state = finishedState }
                book.output = item.output.map { URL(fileURLWithPath: $0) }
                books.append(book)
                findCover(book)
                if let cover = item.cover, fm.fileExists(atPath: cover) { setCover(URL(fileURLWithPath: cover), for: book) }
                if let p = item.queuePosition, finishedState == nil { book.queued = true; order.append((p, book.id)) }
                check(book)
            }
        }
        queueOrder = order.sorted { $0.0 < $1.0 }.map(\.1)
        selection = books.first?.id ?? jobs.first?.id
        var notes: [String] = []
        if !queueOrder.isEmpty { notes.append("\(queueOrder.count) queued from last time: press ▶ to carry on") }
        if missing > 0 { notes.append("\(missing) item\(missing == 1 ? "" : "s") from last time couldn't be found and were left out") }
        lastMessage = notes.joined(separator: " · ")
    }
}
