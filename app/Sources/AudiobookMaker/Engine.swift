import Foundation

/// The Python tools (audiobook.py, say.py) that do the real work. The app only drives them.
struct Engine {
    let root: URL

    var python: URL { root.appendingPathComponent(".venv/bin/python") }
    var outputFolder: URL { root.appendingPathComponent("output") }

    /// Where the app installs its own copy of the tools on first launch.
    static var supportHome: URL {
        if let override = UserDefaults.standard.string(forKey: "engineHomeOverride") {  // testing only
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audiobook Maker/engine")
    }

    /// True for the copy the app installed itself (as opposed to a developer's project folder).
    var isAppInstall: Bool { root.standardizedFileURL == Engine.supportHome.standardizedFileURL }

    func script(_ name: String) -> String { root.appendingPathComponent(name).path }

    /// In order: a folder chosen in Settings; the project folder the app was built in (app/build/ sits
    /// inside it); the copy the app installed in Application Support. nil means first-launch setup.
    static func locate(ignoreProject: Bool = UserDefaults.standard.bool(forKey: "ignoreProject")) -> Engine? {
        let fm = FileManager.default
        if !ignoreProject {
            if let saved = UserDefaults.standard.string(forKey: "enginePath"),
               fm.fileExists(atPath: saved + "/audiobook.py") {
                return Engine(root: URL(fileURLWithPath: saved))
            }
            var dir = Bundle.main.bundleURL.deletingLastPathComponent()
            for _ in 0..<6 {
                if fm.fileExists(atPath: dir.appendingPathComponent("audiobook.py").path) {
                    return Engine(root: dir)
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        let home = supportHome
        if fm.fileExists(atPath: home.appendingPathComponent(".installed").path) {
            return Engine(root: home)
        }
        return nil
    }

    /// After an app update, copy its newer tool scripts over the installed ones. The user's
    /// pronunciation lists are never touched.
    func refreshScripts() {
        guard isAppInstall, let bundled = Bundle.main.url(forResource: "engine", withExtension: nil) else { return }
        let fm = FileManager.default
        for name in ["audiobook.py", "say.py", "voices.py", "audio2m4b.py"] {
            let src = bundled.appendingPathComponent(name), dst = root.appendingPathComponent(name)
            guard fm.contentsEqual(atPath: src.path, andPath: dst.path) == false else { continue }
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
    }

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: python.path) }

    /// Runs Python with networking switched off by macOS itself, so no library it loads can reach the
    /// internet (onnxruntime, for one, would otherwise report usage to Microsoft). Nothing the engine
    /// does needs the network once setup has downloaded the model and voices.
    func offlineCommand(_ arguments: [String]) -> (URL, [String]) {
        let sandbox = "/usr/bin/sandbox-exec"
        guard FileManager.default.isExecutableFile(atPath: sandbox) else { return (python, arguments) }
        return (URL(fileURLWithPath: sandbox),
                ["-p", "(version 1)(allow default)(deny network*)", python.path] + arguments)
    }

    /// Environment for the engine's Python.
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        // Setup already downloaded the model and every English voice, so the engine never needs the
        // internet: no update checks, no telemetry. It works the same with no connection at all.
        env["HF_HUB_OFFLINE"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["DO_NOT_TRACK"] = "1"
        // the app's own text recognition tool, for scanned PDFs
        if let ocr = Bundle.main.url(forResource: "ocr", withExtension: nil, subdirectory: "bin") {
            env["AUDIOBOOK_OCR"] = ocr.path
        }
        // the installed copy's own ffmpeg first, then Homebrew (developer setups)
        env["PATH"] = root.appendingPathComponent("bin").path + ":/opt/homebrew/bin:/usr/local/bin:"
            + (env["PATH"] ?? "/usr/bin:/bin")
        return env
    }

    /// Runs a tool and streams its output line by line on the main thread.
    @discardableResult
    func run(_ arguments: [String],
             onLine: @escaping (String) -> Void,
             onExit: @escaping (Int32) -> Void) -> Process {
        let process = Process()
        (process.executableURL, process.arguments) = offlineCommand(arguments)
        process.currentDirectoryURL = root
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in buffer.append(data) {
                DispatchQueue.main.async { onLine(line) }
            }
        }
        process.terminationHandler = { p in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            let lines = buffer.append(rest) + buffer.flush()
            DispatchQueue.main.async {
                lines.forEach(onLine)
                onExit(p.terminationStatus)
            }
        }
        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                onLine("Couldn't start the tools: \(error.localizedDescription)")
                onExit(-1)
            }
        }
        return process
    }
}

/// Splits streamed bytes into lines; ffmpeg progress uses carriage returns, so those split too.
final class LineBuffer {
    private var pending = ""
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending += String(decoding: data, as: UTF8.self)
        var parts = pending.components(separatedBy: CharacterSet(charactersIn: "\n\r"))
        pending = parts.removeLast()
        return parts.filter { !$0.isEmpty }
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let last = pending
        pending = ""
        return last.isEmpty ? [] : [last]
    }
}

/// Picks the useful facts out of audiobook.py's printed output.
enum EngineOutput {
    static func match(_ pattern: String, _ line: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: line).map { String(line[$0]) } ?? ""
        }
    }

    /// "  12. Chapter Seven - Hypnotherapy ...      16,358 words"
    static func chapter(_ line: String) -> String? {
        match(#"^\s+\d+\.\s(.+?)\s+[\d,]+ words$"#, line)?[1]
    }

    /// "[3/12] Chapter Three (12,345 chars)" or "[3/12] Chapter Three: cached"
    static func progress(_ line: String) -> (index: Int, total: Int, title: String, cached: Bool)? {
        guard let m = match(#"^\[(\d+)/(\d+)\]\s(.+)$"#, line), let i = Int(m[1]), let n = Int(m[2]) else { return nil }
        let cached = m[3].hasSuffix(": cached")
        let title = m[3].replacingOccurrences(of: #"\s*(\([\d,]+ chars\)|: cached)$"#, with: "", options: .regularExpression)
        return (i, n, title, cached)
    }

    /// "  [p 12/340] 42% of chapter · 18% of book · about 6 h 10 min left for the book"  (--verbose, every ~10 seconds)
    static func report(_ line: String) -> (text: String, bookPercent: Int?, timeLeft: String?)? {
        guard let m = match(#"^\s+\[p \d+/\d+\]\s*(.*)$"#, line) else { return nil }
        let pct = match(#"(\d+)% of book"#, m[1]).flatMap { Int($0[1]) }
        return (m[1], pct, match(#"about (.+) left"#, m[1])?[1])
    }

    /// "    done; elapsed 12.3 min, ~45 min left"
    static func minutesLeft(_ line: String) -> Int? {
        match(#"done; elapsed [\d.]+ min, ~(\d+) min left"#, line).flatMap { Int($0[1]) }
    }

    /// "Wrote /path/to/output/book.m4b  (3.2 h, 11 chapters, 101 MB)", or a folder of MP3s
    static func wrote(_ line: String) -> URL? {
        match(#"^Wrote (.+?)  \("#, line).map { URL(fileURLWithPath: $0[1]) }
    }

    /// The engine's reason for giving up on a book, in plain words.
    static func problem(_ line: String) -> String? {
        if line.contains("no text layer") || line.contains("No readable text") {
            return "This PDF is a scan (its pages are pictures), and the text recognition couldn't read it. "
                + "Turn on verbose mode (⌘L) for details."
        }
        if line.hasPrefix("Unsupported file type") { return "This kind of file isn't supported. Use a PDF, EPUB or TXT." }
        if line.contains("Error:") || line.hasPrefix("Traceback") { return line }
        return nil
    }

    /// "  Mathers (22), Logoidal (14), ..."  from --list-unknown
    static func unknownWords(_ line: String) -> [(String, Int)] {
        guard line.hasPrefix("  "), line.contains("), ") || line.hasSuffix(")") else { return [] }
        return line.split(separator: ",").compactMap { part in
            guard let m = match(#"^\s*(.+?) \((\d+)\)$"#, String(part)), let n = Int(m[2]) else { return nil }
            return (m[1], n)
        }
    }
}

/// Runs the bundled install_engine.sh and reports its "STEP n/6 <what>" lines.
@MainActor
final class Installer: ObservableObject {
    @Published var running = false
    @Published var step = 0
    @Published var steps = 6
    @Published var stepName = ""
    @Published var failure: String?
    @Published var log: [String] = []
    private var process: Process?

    func install(into home: URL, finished: @escaping () -> Void) {
        guard let engineDir = Bundle.main.url(forResource: "engine", withExtension: nil),
              let uv = Bundle.main.url(forResource: "uv", withExtension: nil, subdirectory: "bin") else {
            failure = "This copy of the app is missing its installer files."
            return
        }
        running = true
        failure = nil
        step = 0
        log = []
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [engineDir.appendingPathComponent("install_engine.sh").path, home.path]
        var env = ProcessInfo.processInfo.environment
        env["UV"] = uv.path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let lines = buffer.append(data)
            DispatchQueue.main.async { lines.forEach(self.handle) }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = buffer.append(pipe.fileHandleForReading.readDataToEndOfFile()) + buffer.flush()
            DispatchQueue.main.async {
                rest.forEach(self.handle)
                self.running = false
                if proc.terminationStatus == 0 && self.failure == nil {
                    finished()
                } else if self.failure == nil {
                    self.failure = "Setup stopped (code \(proc.terminationStatus)). Check your internet connection and try again."
                }
            }
        }
        do { try p.run(); process = p } catch {
            running = false
            failure = "Couldn't start setup: \(error.localizedDescription)"
        }
    }

    func cancel() { process?.terminate() }

    private func handle(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        if let m = EngineOutput.match(#"^STEP (\d+)/(\d+) (.+)$"#, line), let n = Int(m[1]), let total = Int(m[2]) {
            step = n
            steps = total
            stepName = m[3]
        } else if line.hasPrefix("FAILED") {
            failure = "Setup failed while \(line.dropFirst(14)). Check your internet connection and try again."
        }
    }
}

/// Keeps `say.py --serve` running so Listen doesn't reload the voice model every time
/// (about 1 second per Listen instead of 5-10). It exits when the app quits.
@MainActor
final class SpeechServer {
    private var process: Process?
    private var input: FileHandle?
    private var root: URL?

    /// Start loading in the background, ahead of the first Listen.
    func warmUp(_ engine: Engine) {
        if let process, process.isRunning, root == engine.root { return }
        process?.terminate()
        let p = Process()
        (p.executableURL, p.arguments) = engine.offlineCommand([engine.script("say.py"), "--serve"])
        p.currentDirectoryURL = engine.root
        p.environment = engine.environment
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.qualityOfService = .userInitiated
        do {
            try p.run()
            process = p
            input = stdin.fileHandleForWriting
            root = engine.root
        } catch {
            process = nil
        }
    }

    /// Requests sent while it's still loading are answered as soon as it's ready.
    func say(_ text: String, voice: String, speed: Double, book: String?, engine: Engine) {
        warmUp(engine)
        var request: [String: Any] = ["text": text, "voice": voice, "speed": speed]
        if let book { request["book"] = book }
        guard let input, let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        input.write(data + Data("\n".utf8))
    }
}
