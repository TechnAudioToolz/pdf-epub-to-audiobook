import AppKit
import Foundation
import PDFKit

enum BookState: Equatable {
    case waiting, checking, ready, rendering, done, skipped, failed(String)

    var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .checking: return "Checking"
        case .ready: return "Ready"
        case .rendering: return "Rendering"
        case .done: return "Done"
        case .skipped: return "Already made"
        case .failed: return "Failed"
        }
    }
}

/// A candidate cover from the engine: a page of the book, its own cover, or a generated one.
struct CoverChoice: Identifiable {
    let url: URL
    let label: String
    var id: URL { url }
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
    @Published var coverChoices: [CoverChoice] = []
    /// One continuous file without chapter markers (for books whose chapters aren't found well).
    @Published var oneFile = false
    /// "Make it again": replace the audiobook that's already in the output folder.
    @Published var remake = false
    /// Waiting its turn in the queue. Only queued books and jobs are made.
    @Published var queued = false
    @Published var loadingCoverChoices = false
    @Published var generatingCover = false

    init(url: URL) {
        self.url = url
    }

    var fileStem: String { url.deletingPathExtension().lastPathComponent }
    var displayTitle: String { title.isEmpty ? fileStem : title }
}

@MainActor
final class AppModel: ObservableObject {
    /// All 28 English Kokoro voices (the same set as voices.py), grouped for the picker.
    static let voiceGroups: [(title: String, prefix: String, names: [String])] = [
        ("American female", "af", ["alloy", "aoede", "bella", "heart", "jessica", "kore", "nicole", "nova", "river", "sarah", "sky"]),
        ("American male", "am", ["adam", "echo", "eric", "fenrir", "liam", "michael", "onyx", "puck", "santa"]),
        ("British female", "bf", ["alice", "emma", "isabella", "lily"]),
        ("British male", "bm", ["daniel", "fable", "george", "lewis"]),
    ]
    static let voices: [(id: String, label: String)] = voiceGroups.flatMap { group in
        group.names.map { ("\(group.prefix)_\($0)", $0.capitalized) }
    }
    static let bookTypes = ["pdf", "epub", "txt"]

    @Published var books: [Book] = []
    @Published var jobs: [AudioJob] = []
    @Published var selection: Book.ID?
    @Published var voice = UserDefaults.standard.string(forKey: "voice") ?? "af_alloy" {
        didSet { UserDefaults.standard.set(voice, forKey: "voice") }
    }
    @Published var speed = UserDefaults.standard.object(forKey: "speed") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(speed, forKey: "speed") }
    }
    /// Empty means the project's output/ folder.
    @Published var outputPath = UserDefaults.standard.string(forKey: "outputPath") ?? "" {
        didSet { UserDefaults.standard.set(outputPath, forKey: "outputPath") }
    }
    @Published var nameFromFile = UserDefaults.standard.object(forKey: "nameFromFile") as? Bool ?? true {
        didSet { UserDefaults.standard.set(nameFromFile, forKey: "nameFromFile") }
    }
    @Published var notifyWhenDone = UserDefaults.standard.object(forKey: "notifyWhenDone") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyWhenDone, forKey: "notifyWhenDone") }
    }
    /// What audiobook.py skips by default, with the checkbox labels (its --keep names, same order as KEEP_CHOICES).
    static let keepChoices: [(id: String, label: String)] = [
        ("page-numbers", "Page numbers"),
        ("headers", "Running headers and footers"),
        ("footnotes", "Footnotes"),
        ("tables", "Tables and chart labels"),
        ("captions", "Figure and table captions"),
        ("citations", "Citations, like (Smith, 2020) and [3]"),
        ("links", "Web and email addresses"),
        ("extras", "Front and back matter: copyright, contents, references, index, about the author"),
    ]
    /// The checked "Also read" boxes. Empty: read just the book.
    @Published var keep = Set(UserDefaults.standard.stringArray(forKey: "keep") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(keep).sorted(), forKey: "keep")
            for book in books where book.state != .rendering { check(book) }  // chapter list changes
        }
    }
    /// "m4b" (one file with chapters) or "mp3" (a folder with one file per chapter).
    @Published var outputFormat = UserDefaults.standard.string(forKey: "outputFormat") ?? "m4b" {
        didSet { UserDefaults.standard.set(outputFormat, forKey: "outputFormat") }
    }
    @Published var isRunning = false
    @Published var isPaused = false
    /// The queue, in the order things will be made (books and MP3 jobs alike). Items leave it when they start.
    @Published var queueOrder: [UUID] = []
    /// The item being made right now, and one we stopped so another could jump ahead of it.
    var currentItem: UUID?
    var preempted: UUID?
    /// The engine's own output while rendering (the Log panel), newest last.
    @Published var log: [String] = []
    /// The latest progress report ("Chapter 7 of 38 · 42% of chapter · 18% of book · about 6 h left"),
    /// shown as one line at the bottom of the Log that updates in place.
    @Published var liveStatus = ""
    /// While a book is being checked: "Checking The Circuit of Force: page 120 of 244 (49%)".
    @Published var checkStatus = ""
    @Published var showLog = false  // the Log starts closed each time; ⌘L opens it
    @Published var engine = Engine.locate()
    @Published var lastMessage = ""

    var current: Process?
    private let speech = SpeechServer()
    var stopRequested = false

    var selectedBook: Book? { books.first { $0.id == selection } }

    /// A folder chosen in Settings; otherwise ~/Audiobooks for the app's own install, or the
    /// project's output/ folder for a developer setup.
    var outputFolder: URL? {
        if !outputPath.isEmpty { return URL(fileURLWithPath: outputPath) }
        guard let engine else { return nil }
        return engine.isAppInstall
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Audiobooks")
            : engine.outputFolder
    }

    // MARK: adding books

    func add(_ urls: [URL]) {
        var files: [URL] = [], audio: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                let bookFiles = items.filter { Self.bookTypes.contains($0.pathExtension.lowercased()) }
                if bookFiles.isEmpty && Self.containsAudio(url) {
                    audio.append(url)  // a folder of MP3s dropped on the books: it's an MP3 job
                }
                files += bookFiles
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if Self.bookTypes.contains(url.pathExtension.lowercased()) {
                files.append(url)
            } else if Self.audioTypes.contains(url.pathExtension.lowercased()) {
                audio.append(url)
            }
        }
        if !audio.isEmpty { addAudio(audio) }
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
        queueOrder.removeAll { $0 == book.id }
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
        // cover.jpg / folder.jpg belong to a folder, so they only count when the folder holds just this book
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let booksHere = items.filter { Self.bookTypes.contains($0.pathExtension.lowercased()) }.count
        let names = [book.fileStem, "\(book.fileStem)-Cover", "\(book.fileStem) cover"] + (booksHere <= 1 ? ["cover", "folder"] : [])
        for name in names {
            candidates += exts.map { folder.appendingPathComponent("\(name).\($0)") }
        }
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            book.cover = NSImage(contentsOf: found)
            book.coverNote = "Found: \(found.lastPathComponent)"
        } else {
            // something to look at straight away: the PDF's first page, until the check picks the best cover
            if book.url.pathExtension.lowercased() == "pdf", let page = PDFDocument(url: book.url)?.page(at: 0) {
                book.cover = page.thumbnail(of: NSSize(width: 300, height: 435), for: .mediaBox)
            }
            book.coverNote = "Looking for the cover…"
        }
    }

    /// Moves the engine's saved data for this book (cleaned text, scanned-page text, cover previews) to the
    /// Trash and checks it again from scratch. Finished chapters' audio is kept unless `audio` is true.
    func checkFromScratch(_ book: Book, audio: Bool = false) {
        guard let engine, book.state != .rendering else { return }
        let work = engine.root.appendingPathComponent("work/\(book.fileStem)")
        let items = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        for item in items where audio || !item.lastPathComponent.hasPrefix("audio_") {
            try? FileManager.default.trashItem(at: item, resultingItemURL: nil)
        }
        book.coverURL = nil
        book.title = ""
        book.author = ""
        book.unknownWords = []
        if book.state != .done { book.state = .waiting }
        findCover(book)
        check(book)
        lastMessage = audio ? "Cleared everything saved for \(book.fileStem), including its audio (in the Trash)"
                            : "Checking \(book.fileStem) again from scratch"
    }

    func setCover(_ url: URL, for book: Book, note: String? = nil) {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return }
        book.cover = image
        book.coverURL = url
        book.coverNote = note ?? "Your image: \(url.lastPathComponent)"
    }

    /// The book's first six pages (or an EPUB's own cover), for the cover picker.
    func loadCoverChoices(_ book: Book) {
        book.coverChoices = []
        book.loadingCoverChoices = true
        runCoverTool(book, ["--cover-choices", "6"]) { book.loadingCoverChoices = false }
    }

    /// Adds a cover generated from the title and author to the picker.
    func generateCover(_ book: Book) {
        book.coverChoices.removeAll { $0.label == "Generated" }
        book.generatingCover = true
        runCoverTool(book, ["--generate-cover"]) { book.generatingCover = false }
    }

    private func runCoverTool(_ book: Book, _ extra: [String], done: @escaping () -> Void) {
        guard let engine else { return done() }
        var args = [engine.script("audiobook.py"), book.url.path, "--no-notify"] + extra
        if !book.title.isEmpty { args += ["--title", book.title] }
        if !book.author.isEmpty { args += ["--author", book.author] }
        engine.run(args, onLine: { line in
            guard line.hasPrefix("Cover choice: ") else { return }
            let parts = line.dropFirst("Cover choice: ".count).components(separatedBy: "\t")
            if parts.count == 2 { book.coverChoices.append(CoverChoice(url: URL(fileURLWithPath: parts[0]), label: parts[1])) }
        }, onExit: { _ in done() })
    }

    /// Uses an image from the clipboard (copied from a browser, Preview, a screenshot…) as the cover.
    /// It's saved next to the book's other working files, so the render can read it. False if there's no image.
    @discardableResult
    func pasteCover(for book: Book) -> Bool {
        guard let file = pastedImage() else { return false }
        setCover(file, for: book, note: "Cover: pasted image")
        return true
    }

    /// Saves the image on the clipboard into the engine's work folder (so the engine can read it). Nil if there's none.
    func pastedImage() -> URL? {
        guard let engine, let image = NSImage(pasteboard: NSPasteboard.general),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return nil }
        let folder = engine.root.appendingPathComponent("work/pasted-covers")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("pasted-\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
        return (try? jpeg.write(to: file)) != nil ? file : nil
    }

    // MARK: talking to the engine

    private func commonArgs(_ book: Book) -> [String] {
        var args = [book.url.path, "--voice", voice, "--speed", String(format: "%.2f", speed)]
        if nameFromFile { args.append("--name-from-file") }
        if !keep.isEmpty {
            args += ["--keep", Self.keepChoices.map(\.id).filter(keep.contains).joined(separator: ",")]
        }
        args += ["--format", outputFormat]
        if !notifyWhenDone { args.append("--no-notify") }
        if !outputPath.isEmpty || engine?.isAppInstall == true, let folder = outputFolder {
            args += ["--output-dir", folder.path]
        }
        if !book.title.isEmpty { args += ["--title", book.title] }
        if !book.author.isEmpty { args += ["--author", book.author] }
        if let cover = book.coverURL { args += ["--cover", cover.path] }
        if book.oneFile { args.append("--no-chapters") }
        if book.remake { args.append("--force") }
        return args
    }

    /// Dry run: chapters, title and author, without making audio.
    func check(_ book: Book) {
        guard let engine, !isRunning || book.state != .rendering else { return }
        book.state = .checking
        book.chapters = []
        var titleLine = true
        var problem = ""
        engine.run([engine.script("audiobook.py")] + commonArgs(book) + ["--dry-run", "--no-notify", "--verbose"],
                   onLine: { [weak self] line in
            if let reason = EngineOutput.problem(line) { problem = reason }
            if let m = EngineOutput.match(#"^(OCR|Reading) page (\d+)/(\d+)"#, line), let n = Double(m[2]), let total = Double(m[3]) {
                let what = m[1] == "OCR" ? "reading scanned page" : "page"
                self?.checkStatus = "Checking \(book.displayTitle): \(what) \(m[2]) of \(m[3]) (\(Int(n / total * 100))%)"
                if m[1] == "OCR" { book.summary = "Scanned book: reading page \(m[2]) of \(m[3]) (once; it's saved)…" }
            }
            if titleLine, line.contains(" — ") {
                titleLine = false
                let parts = line.components(separatedBy: " — ")
                if book.title.isEmpty { book.title = parts[0] }
                if book.author.isEmpty, parts.count > 1, parts[1] != "unknown author" { book.author = parts[1] }
            } else if line.contains(" chapters, ") && line.contains(" words") {
                book.summary = line
            } else if line.hasPrefix("Cover: "), book.coverURL == nil {
                // where the engine's cover came from: a found image, a page of the book, or generated
                let note = String(line.dropFirst("Cover: ".count))
                book.coverNote = "Cover: " + note.replacingOccurrences(of: " (no cover art in the book)", with: "")
            } else if line.hasPrefix("Cover image: "), book.coverURL == nil,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: String(line.dropFirst("Cover image: ".count)))) {
                book.cover = NSImage(data: data)
            } else if let chapter = EngineOutput.chapter(line) {
                book.chapters.append(chapter)
            }
        }, onExit: { [weak self] status in
            if self?.checkStatus.hasPrefix("Checking \(book.displayTitle)") == true { self?.checkStatus = "" }
            if book.state == .checking {
                book.state = status == 0 ? .ready : .failed(problem.isEmpty ? "Couldn't read this file." : problem)
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
        speech.say(text, voice: voice, speed: speed, book: book?.fileStem, engine: engine)
    }

    /// Load the voice in the background so the first Listen is quick.
    func warmUpSpeech() {
        if let engine, engine.isInstalled { speech.warmUp(engine) }
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

    /// The toolbar's Start: queues everything that isn't made yet (if nothing is queued), then runs the queue.
    func startQueue() {
        let waiting: (BookState) -> Bool = { [.waiting, .ready, .checking].contains($0) }
        if queueOrder.isEmpty {
            books.filter { waiting($0.state) }.forEach { $0.queued = true; enqueue($0.id) }
            jobs.filter { waiting($0.state) }.forEach { $0.queued = true; enqueue($0.id) }
        }
        runQueue()
    }

    /// Puts an item in the queue: at the end, at the front, or at a given place.
    func enqueue(_ id: UUID, at index: Int? = nil) {
        queueOrder.removeAll { $0 == id }
        queueOrder.insert(id, at: min(index ?? queueOrder.count, queueOrder.count))
    }

    /// Moves a queued item up (-1) or down (+1) one place in the queue.
    func moveInQueue(_ id: UUID, by step: Int) {
        guard let i = queueOrder.firstIndex(of: id), queueOrder.indices.contains(i + step) else { return }
        queueOrder.swapAt(i, i + step)
    }

    /// A list in the order things will happen: what's being made, then the queue in order, then the rest.
    func inQueueOrder<T: AnyObject>(_ items: [T], id: (T) -> UUID, rendering: (T) -> Bool) -> [T] {
        let making = items.filter(rendering)
        let queued = items.filter { !rendering($0) && queuePosition(id($0)) != nil }
            .sorted { queuePosition(id($0))! < queuePosition(id($1))! }
        let rest = items.filter { !rendering($0) && queuePosition(id($0)) == nil }
        return making + queued + rest
    }

    var booksInOrder: [Book] { inQueueOrder(books, id: { $0.id }, rendering: { $0.state == .rendering }) }
    var jobsInOrder: [AudioJob] { inQueueOrder(jobs, id: { $0.id }, rendering: { $0.state == .rendering }) }

    /// 1 for the next item to be made, 2 for the one after, and so on.
    func queuePosition(_ id: UUID) -> Int? { queueOrder.firstIndex(of: id).map { $0 + 1 } }

    /// The title of whatever comes just before this item in the queue (or is being made now).
    func queuedBefore(_ id: UUID) -> String? {
        guard let i = queueOrder.firstIndex(of: id) else { return nil }
        let before = i == 0 ? currentItem : queueOrder[i - 1]
        return books.first { $0.id == before }?.displayTitle ?? jobs.first { $0.id == before }?.displayTitle
    }

    private func makeReady(_ state: inout BookState) {
        if state == .done || state == .skipped { state = .ready }
        if case .failed = state { state = .ready }
    }

    func addToQueue(_ book: Book) {
        if book.state == .done || book.state == .skipped { book.remake = true }
        makeReady(&book.state)
        book.queued = true
        enqueue(book.id)
        runQueue()
    }

    func addToQueue(_ job: AudioJob) {
        makeReady(&job.state)
        job.queued = true
        enqueue(job.id)
        runQueue()
    }

    func takeOut(_ id: UUID) {
        queueOrder.removeAll { $0 == id }
        books.first { $0.id == id }?.queued = false
        jobs.first { $0.id == id }?.queued = false
    }

    /// Jump the queue: this item is made next. If something else is being made, it stops (its finished
    /// chapters are kept), this one starts, and the stopped one carries on straight after.
    func renderNow(_ id: UUID) {
        guard id != currentItem else { return }
        if let book = books.first(where: { $0.id == id }) { makeReady(&book.state); book.queued = true }
        if let job = jobs.first(where: { $0.id == id }) { makeReady(&job.state); job.queued = true }
        enqueue(id, at: 0)
        if isRunning, let running = currentItem, current?.isRunning == true {
            preempted = running
            if isPaused { resume() }
            current?.terminate()  // its exit handler puts it back in the queue right after this one
        } else {
            runQueue()
        }
    }

    /// The exit handlers' share of a jump: put the stopped item back, second in line.
    func requeueAfterJump(_ id: UUID) {
        preempted = nil
        enqueue(id, at: 1)
    }

    /// Starts working through the queue, unless it already is (then new items are picked up in turn).
    func runQueue() {
        guard !isRunning else { return }
        lastMessage = ""
        isRunning = true
        stopRequested = false
        renderNext()
    }

    func stop() {
        stopRequested = true
        if isPaused { resume() }  // a stopped process can't act on terminate until it runs again
        current?.terminate()
    }

    /// Freezes the render where it is (the engine process is suspended, so it uses no CPU) until Resume.
    func pause() {
        guard let process = current, process.isRunning, !isPaused else { return }
        kill(process.processIdentifier, SIGSTOP)
        isPaused = true
        if let book = books.first(where: { $0.state == .rendering }) { book.detail = "Paused · " + book.detail }
        if let job = jobs.first(where: { $0.state == .rendering }) { job.detail = "Paused · " + job.detail }
        appendLog("— Paused —")
    }

    func resume() {
        guard let process = current, isPaused else { return }
        kill(process.processIdentifier, SIGCONT)
        isPaused = false
        if let book = books.first(where: { $0.state == .rendering }) {
            book.detail = book.detail.replacingOccurrences(of: "Paused · ", with: "")
        }
        if let job = jobs.first(where: { $0.state == .rendering }) {
            job.detail = job.detail.replacingOccurrences(of: "Paused · ", with: "")
        }
        appendLog("— Resumed —")
    }

    func appendLog(_ line: String) {
        log.append(line)
        if log.count > 3000 { log.removeFirst(log.count - 3000) }
    }

    func renderNext() {
        let next: (BookState) -> Bool = { [.waiting, .ready, .checking].contains($0) }
        currentItem = nil
        // the first item in the queue that can be made; anything removed from the list drops out
        queueOrder.removeAll { id in !books.contains { $0.id == id && $0.queued } && !jobs.contains { $0.id == id && $0.queued } }
        let id = queueOrder.first { id in
            books.contains { $0.id == id && next($0.state) } || jobs.contains { $0.id == id && next($0.state) }
        }
        if !stopRequested, let id, let job = jobs.first(where: { $0.id == id }) {
            queueOrder.removeAll { $0 == id }
            currentItem = id
            return renderJob(job)
        }
        guard !stopRequested, let engine, let id, let book = books.first(where: { $0.id == id }) else {
            isRunning = false
            current = nil
            let done = books.filter { $0.state == .done }.count + jobs.filter { $0.state == .done }.count
            lastMessage = stopRequested ? "Stopped. Finished chapters are kept, so starting again resumes." : "Queue finished: \(done) done"
            return
        }
        book.state = .rendering
        book.queued = false
        queueOrder.removeAll { $0 == book.id }
        currentItem = book.id
        book.progress = 0
        book.detail = "Starting…"
        var skipped = false
        var lastError = ""
        var chapter = ""
        appendLog("=== \(book.displayTitle) ===")
        current = engine.run([engine.script("audiobook.py")] + commonArgs(book) + ["--verbose"], onLine: { [weak self] line in
            if let m = EngineOutput.match(#"^(OCR|Reading) page (\d+)/(\d+)"#, line) {
                // reading the book before the voice starts: the updating line, not the Log
                self?.liveStatus = "Reading \(book.displayTitle): page \(m[2]) of \(m[3])"
                book.detail = "Reading the book: page \(m[2]) of \(m[3])"
                return
            }
            if let report = EngineOutput.report(line) {
                // progress every ~10 seconds: one updating line, not a log entry
                if let pct = report.bookPercent { book.progress = Double(pct) / 100 }
                self?.liveStatus = "\(chapter) · \(report.text)"
                if let left = report.timeLeft { book.detail = "\(chapter) · about \(left) left" }
                return
            }
            self?.appendLog(line)
            if let p = EngineOutput.progress(line) {
                chapter = "Chapter \(p.index) of \(p.total)"
                book.progress = Double(p.cached ? p.index : p.index - 1) / Double(p.total)
                book.detail = "Chapter \(p.index) of \(p.total): \(p.title)"
            } else if let minutes = EngineOutput.minutesLeft(line) {
                book.detail += " · about \(minutes) min left"
            } else if let url = EngineOutput.wrote(line) {
                book.output = url
                book.progress = 1
            } else if line.hasPrefix("Skipped ") {
                skipped = true
                // "Skipped book.pdf: already exists: Book.m4b (use --force to redo)"
                if let name = EngineOutput.match(#"already exists: (.+?) \(use --force"#, line)?[1],
                   let folder = self?.outputFolder {
                    book.output = folder.appendingPathComponent(name)
                }
            } else if let reason = EngineOutput.problem(line) {
                lastError = reason
            } else if line.contains("Error") {
                lastError = line
            }
        }, onExit: { [weak self] status in
            if self?.preempted == book.id {
                book.state = .ready
                book.queued = true
                book.detail = "Paused for another book; carries on next"
                self?.requeueAfterJump(book.id)
            } else if self?.stopRequested == true {
                book.state = .ready
                book.queued = true  // still in the queue: Start picks it up where it stopped
                self?.enqueue(book.id, at: 0)
                book.detail = "Stopped"
            } else if skipped {
                book.state = .skipped
                book.detail = "Made earlier: \(book.output?.lastPathComponent ?? "it's in the output folder")"
            } else if status == 0 {
                book.remake = false
                book.state = .done
                book.detail = book.output?.lastPathComponent ?? "Done"
            } else {
                book.state = .failed(lastError)
                book.detail = lastError.isEmpty ? "Something went wrong" : lastError
            }
            self?.isPaused = false
            self?.liveStatus = ""
            self?.renderNext()
        })
    }

    // MARK: misc

    func chooseEngineFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "enginePath")
        engine = Engine.locate()
    }

    /// Called after first-launch setup finishes, and at launch to pick up updated scripts.
    func reloadEngine() {
        engine = Engine.locate()
        engine?.refreshScripts()
        warmUpSpeech()
    }

    var statusLine: String {
        let states = books.map(\.state) + jobs.map(\.state)
        let done = states.filter { $0 == .done || $0 == .skipped }.count
        let running = states.filter { $0 == .rendering }.count
        let plural = { (n: Int, word: String) in "\(n) \(word)\(n == 1 ? "" : "s")" }
        let items = jobs.isEmpty ? plural(books.count, "book") : "\(plural(books.count, "book")), \(plural(jobs.count, "MP3 job"))"
        let queued = queueOrder.count
        return "\(items) · \(done) done · \(running) rendering · \(queued) queued"
    }
}
