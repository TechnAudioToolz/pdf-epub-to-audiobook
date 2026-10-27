import AppKit
import Foundation

enum BookState: Equatable {
    case waiting, checking, ready, rendering, done, skipped, failed(String)

    var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .checking: return "Checking"
        case .ready: return "Ready"
        case .rendering: return "Rendering"
        case .done: return "Done"
        case .skipped: return "Already done"
        case .failed: return "Failed"
        }
    }
}

struct WordCount: Identifiable {
    let word: String
    let count: Int
    var id: String { word }
}

final class Book: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    @Published var title = ""
    @Published var author = ""
    @Published var cover: NSImage?
    @Published var coverURL: URL?          // an image the user dropped on the cover box
    @Published var coverNote = ""
    @Published var chapters: [String] = []
    @Published var summary = ""
    @Published var unknownWords: [WordCount] = []
    @Published var state: BookState = .waiting
    @Published var progress = 0.0
    @Published var detail = ""
    @Published var output: URL?

    init(url: URL) {
        self.url = url
    }

    var fileStem: String { url.deletingPathExtension().lastPathComponent }
    var displayTitle: String { title.isEmpty ? fileStem : title }
}

@MainActor
final class AppModel: ObservableObject {
    static let voices: [(id: String, label: String)] = [
        ("af_alloy", "Alloy · US female"), ("af_heart", "Heart · US female"), ("af_bella", "Bella · US female"),
        ("af_nicole", "Nicole · US female"), ("af_sarah", "Sarah · US female"), ("af_sky", "Sky · US female"),
        ("am_michael", "Michael · US male"), ("am_adam", "Adam · US male"), ("am_fenrir", "Fenrir · US male"),
        ("am_puck", "Puck · US male"), ("bf_emma", "Emma · UK female"), ("bf_isabella", "Isabella · UK female"),
        ("bm_george", "George · UK male"), ("bm_lewis", "Lewis · UK male"), ("bm_daniel", "Daniel · UK male"),
    ]
    static let bookTypes = ["pdf", "epub", "txt"]

    @Published var books: [Book] = []
    @Published var selection: Book.ID?
    @Published var voice = UserDefaults.standard.string(forKey: "voice") ?? "af_alloy" {
        didSet { UserDefaults.standard.set(voice, forKey: "voice") }
    }
    @Published var speed = 1.0
    @Published var isRunning = false
    @Published var engine = Engine.locate()
    @Published var lastMessage = ""

    private var current: Process?
    private var stopRequested = false

    var selectedBook: Book? { books.first { $0.id == selection } }

    // MARK: adding books

    func add(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                files += items.filter { Self.bookTypes.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if Self.bookTypes.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        for file in files where !books.contains(where: { $0.url == file }) {
            let book = Book(url: file)
            books.append(book)
            findCover(book)
            check(book)
        }
        if selection == nil { selection = books.first?.id }
    }

    func remove(_ book: Book) {
        guard book.state != .rendering else { return }
        books.removeAll { $0.id == book.id }
        if selection == book.id { selection = books.first?.id }
    }

    /// Same order as audiobook.py: covers/<book>.*, then an image next to the book.
    func findCover(_ book: Book) {
        let exts = ["jpg", "jpeg", "png", "webp"]
        var candidates: [URL] = []
        if let engine {
            candidates += exts.map { engine.root.appendingPathComponent("covers/\(book.fileStem).\($0)") }
        }
        let folder = book.url.deletingLastPathComponent()
        for name in [book.fileStem, "\(book.fileStem)-Cover", "\(book.fileStem) cover", "cover", "folder"] {
            candidates += exts.map { folder.appendingPathComponent("\(name).\($0)") }
        }
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            book.cover = NSImage(contentsOf: found)
            book.coverNote = "Found: \(found.lastPathComponent)"
        } else {
            book.coverNote = "Uses the book's first page. Drop an image to change it."
        }
    }

    func setCover(_ url: URL, for book: Book) {
        guard let image = NSImage(contentsOf: url) else { return }
        book.cover = image
        book.coverURL = url
        book.coverNote = "Your image: \(url.lastPathComponent)"
    }

    // MARK: talking to the engine

    private func commonArgs(_ book: Book) -> [String] {
        var args = [book.url.path, "--name-from-file", "--voice", voice, "--speed", String(format: "%.2f", speed)]
        if !book.title.isEmpty { args += ["--title", book.title] }
        if !book.author.isEmpty { args += ["--author", book.author] }
        if let cover = book.coverURL { args += ["--cover", cover.path] }
        return args
    }

    /// Dry run: chapters, title and author, without making audio.
    func check(_ book: Book) {
        guard let engine, !isRunning || book.state != .rendering else { return }
        book.state = .checking
        book.chapters = []
        var titleLine = true
        engine.run([engine.script("audiobook.py")] + commonArgs(book) + ["--dry-run", "--no-notify"], onLine: { line in
            if titleLine, line.contains(" — ") {
                titleLine = false
                let parts = line.components(separatedBy: " — ")
                if book.title.isEmpty { book.title = parts[0] }
                if book.author.isEmpty, parts.count > 1, parts[1] != "unknown author" { book.author = parts[1] }
            } else if line.contains(" chapters, ") && line.contains(" words") {
                book.summary = line
            } else if let chapter = EngineOutput.chapter(line) {
                book.chapters.append(chapter)
            }
        }, onExit: { status in
            if book.state == .checking {
                book.state = status == 0 ? .ready : .failed("Couldn't read this file")
            }
        })
    }

    /// Words Kokoro has to guess, most frequent first.
    func checkWords(_ book: Book) {
        guard let engine else { return }
        book.unknownWords = []
        engine.run([engine.script("audiobook.py"), book.url.path, "--list-unknown", "--no-notify"], onLine: { line in
            let words = EngineOutput.unknownWords(line)
            if !words.isEmpty { book.unknownWords = words.map { WordCount(word: $0.0, count: $0.1) } }
        }, onExit: { _ in })
    }

    func listen(_ text: String, book: Book?) {
        guard let engine else { return }
        var args = [engine.script("say.py"), text, "--voice", voice, "--speed", String(format: "%.2f", speed)]
        if let book { args += ["--book", book.fileStem] }
        engine.run(args, onLine: { _ in }, onExit: { _ in })
    }

    /// Adds "word = say as" to this book's pronunciation rules.
    func savePronunciation(word: String, sayAs: String, book: Book) {
        guard let engine, !sayAs.isEmpty else { return }
        let folder = engine.root.appendingPathComponent("pronunciations")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(book.fileStem).txt")
        let line = "\(word) = \(sayAs)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? ("# Pronunciation rules for \(book.fileStem)\n" + line).write(to: file, atomically: true, encoding: .utf8)
        }
        book.unknownWords.removeAll { $0.word == word }
        lastMessage = "Saved: \(word) will be said as \(sayAs)"
    }

    // MARK: the queue

    func startQueue() {
        guard !isRunning else { return }
        isRunning = true
        stopRequested = false
        renderNext()
    }

    func stop() {
        stopRequested = true
        current?.terminate()
    }

    private func renderNext() {
        guard !stopRequested, let engine,
              let book = books.first(where: { [.waiting, .ready, .checking].contains($0.state) }) else {
            isRunning = false
            current = nil
            let done = books.filter { $0.state == .done }.count
            lastMessage = stopRequested ? "Stopped. Finished chapters are kept, so starting again resumes." : "Queue finished: \(done) done"
            return
        }
        book.state = .rendering
        book.progress = 0
        book.detail = "Starting…"
        var skipped = false
        var lastError = ""
        current = engine.run([engine.script("audiobook.py")] + commonArgs(book), onLine: { line in
            if let p = EngineOutput.progress(line) {
                book.progress = Double(p.cached ? p.index : p.index - 1) / Double(p.total)
                book.detail = "Chapter \(p.index) of \(p.total): \(p.title)"
            } else if let minutes = EngineOutput.minutesLeft(line) {
                book.detail += " · about \(minutes) min left"
            } else if let url = EngineOutput.wrote(line) {
                book.output = url
                book.progress = 1
            } else if line.hasPrefix("Skipped ") {
                skipped = true
            } else if line.contains("Error") {
                lastError = line
            }
        }, onExit: { [weak self] status in
            if self?.stopRequested == true {
                book.state = .ready
                book.detail = "Stopped"
            } else if skipped {
                book.state = .skipped
                book.detail = "Already in the output folder"
            } else if status == 0 {
                book.state = .done
                book.detail = book.output?.lastPathComponent ?? "Done"
            } else {
                book.state = .failed(lastError)
                book.detail = lastError.isEmpty ? "Something went wrong" : lastError
            }
            self?.renderNext()
        })
    }

    // MARK: misc

    func chooseEngineFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "enginePath")
        engine = Engine.locate()
    }

    var statusLine: String {
        let done = books.filter { $0.state == .done || $0.state == .skipped }.count
        let running = books.filter { $0.state == .rendering }.count
        let waiting = books.count - done - running
        return "\(books.count) books · \(done) done · \(running) rendering · \(waiting) waiting"
    }
}
