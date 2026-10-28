import AppKit
import SwiftUI
import Foundation

extension AppModel {
    // MARK: clear finished

    var hasFinished: Bool {
        books.contains { $0.state == .done || $0.state == .skipped } || jobs.contains { $0.state == .done }
    }

    /// Takes every finished book and MP3 job off the list. Their audiobooks stay in the output folder.
    func clearFinished() {
        let finished: (BookState) -> Bool = { $0 == .done || $0 == .skipped }
        let n = books.filter { finished($0.state) }.count + jobs.filter { finished($0.state) }.count
        books.removeAll { finished($0.state) }
        jobs.removeAll { finished($0.state) }
        if let s = selection, !books.contains(where: { $0.id == s }) && !jobs.contains(where: { $0.id == s }) {
            selection = books.first?.id ?? jobs.first?.id
        }
        lastMessage = "Cleared \(n) finished item\(n == 1 ? "" : "s") from the list (the audiobooks are still in the output folder)"
    }

    // MARK: example book

    /// Asks first (it goes online), then downloads a short public-domain classic and adds it to the list.
    func tryExampleBook() {
        let alert = NSAlert()
        alert.messageText = "Try an example book?"
        alert.informativeText = "This downloads “The Call of the Wild” by Jack London (public domain, about 0.5 MB) "
            + "from Standard Ebooks, a free library of classics, and adds it to your list. It's about 3½ hours "
            + "of audio. Nothing else is sent or downloaded."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audiobook Maker/Examples")
        let file = folder.appendingPathComponent("Jack London - The Call of the Wild.epub")
        if FileManager.default.fileExists(atPath: file.path) { return add([file]) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        lastMessage = "Downloading the example book…"
        let sources = [
            "https://standardebooks.org/ebooks/jack-london/the-call-of-the-wild/downloads/jack-london_the-call-of-the-wild.epub?source=download",
            "https://www.gutenberg.org/ebooks/215.epub3.images",  // Project Gutenberg, if the first is unreachable
        ].compactMap(URL.init(string:))
        Task {
            for source in sources {
                var request = URLRequest(url: source, timeoutInterval: 30)
                request.setValue("AudiobookMaker/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200, data.count > 10_000,
                   (try? data.write(to: file)) != nil {
                    lastMessage = "Added the example book: select it, then Add to queue"
                    add([file])
                    selection = books.first { $0.url == file }?.id
                    return
                }
            }
            lastMessage = "Couldn't download the example book. Are you online?"
        }
    }

    // MARK: time left for the whole queue

    /// "1 h 13 min" or "3 min" -> seconds.
    static func seconds(_ words: String) -> Double? {
        let h = EngineOutput.match(#"(\d+) h"#, words).flatMap { Double($0[1]) } ?? 0
        let m = EngineOutput.match(#"(\d+) min"#, words).flatMap { Double($0[1]) } ?? 0
        return h + m > 0 ? h * 3600 + m * 60 : nil
    }

    /// The current item's time left, plus estimates for everything queued: books from their length at about
    /// 5x faster than real time, MP3 jobs at about 100x. Nil when nothing is running.
    var queueTimeLeft: String? {
        guard isRunning else { return nil }
        let hours = { (summary: String) in EngineOutput.match(#"([\d.]+) h of audio"#, summary).flatMap { Double($0[1]) } ?? 0 }
        var total = currentSecondsLeft ?? 0
        for id in queueOrder {
            if let book = books.first(where: { $0.id == id }) { total += hours(book.summary) * 3600 / 5 / speed }
            if let job = jobs.first(where: { $0.id == id }) { total += hours(job.summary) * 3600 / 100 }
        }
        guard total > 60 else { return nil }
        let minutes = Int(total / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

// MARK: keep awake

/// The coffee cup in the toolbar: while it's on, the Mac doesn't go to sleep on its own, so long queues keep
/// going when you walk away. The screen can still turn off. Off again each time the app opens.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()
    private var activity: NSObjectProtocol?

    @Published var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            if isOn {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled], reason: "Audiobook Maker: keeping the Mac awake")
            } else if let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
        }
    }
}

struct KeepAwakeButton: View {
    @ObservedObject var keepAwake = KeepAwake.shared

    var body: some View {
        Toggle(isOn: $keepAwake.isOn) {
            Label(keepAwake.isOn ? "Keeping awake" : "Keep awake",
                  systemImage: keepAwake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
        }
        .help(keepAwake.isOn
              ? "The Mac won't sleep while Audiobook Maker is open. Click to let it sleep again."
              : "Keep the Mac awake while Audiobook Maker is open, so audiobooks keep being made when you walk away. "
                + "The screen can still turn off. (Closing a laptop's lid still puts it to sleep.)")
    }
}
