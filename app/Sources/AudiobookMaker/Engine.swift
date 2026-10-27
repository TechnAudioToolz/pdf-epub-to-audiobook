import Foundation

/// The Python tools (audiobook.py, say.py) that do the real work. The app only drives them.
struct Engine {
    let root: URL

    var python: URL { root.appendingPathComponent(".venv/bin/python") }
    var outputFolder: URL { root.appendingPathComponent("output") }

    func script(_ name: String) -> String { root.appendingPathComponent(name).path }

    /// A folder chosen in the app, else the folder the app was built in (app/build/ sits inside the project).
    static func locate() -> Engine? {
        let fm = FileManager.default
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
        return nil
    }

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: python.path) }

    /// Runs a tool and streams its output line by line on the main thread.
    @discardableResult
    func run(_ arguments: [String],
             onLine: @escaping (String) -> Void,
             onExit: @escaping (Int32) -> Void) -> Process {
        let process = Process()
        process.executableURL = python
        process.arguments = arguments
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")  // ffmpeg, espeak-ng
        process.environment = env

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

    /// "    done; elapsed 12.3 min, ~45 min left"
    static func minutesLeft(_ line: String) -> Int? {
        match(#"done; elapsed [\d.]+ min, ~(\d+) min left"#, line).flatMap { Int($0[1]) }
    }

    /// "Wrote /path/to/output/book.m4b  (3.2 h, 11 chapters, 101 MB)"
    static func wrote(_ line: String) -> URL? {
        match(#"^Wrote (.+\.m4b)\s"#, line).map { URL(fileURLWithPath: $0[1]) }
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
