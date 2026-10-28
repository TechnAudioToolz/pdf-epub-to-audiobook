import AppKit
import SwiftUI

/// Screenshot mode for the README: fills the app with demo books and draws each screen
/// into a PNG. It renders the app's own windows, so no screen recording permission is needed.
///   open "Audiobook Maker.app" --args -screenshots /path/to/folder
@MainActor
enum Screenshots {
    static func run(_ model: AppModel, into folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // the demo changes these saved settings; put them back afterwards
        let savedVoice = UserDefaults.standard.string(forKey: "voice")
        let savedOutput = UserDefaults.standard.string(forKey: "outputPath")
        let savedShowLog = model.showLog
        func restore() {
            UserDefaults.standard.set(savedVoice, forKey: "voice")
            UserDefaults.standard.set(savedOutput, forKey: "outputPath")
            UserDefaults.standard.set(savedShowLog, forKey: "showLog")
        }
        loadDemo(model)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title == "Audiobook Maker" }) {
            window.setContentSize(NSSize(width: 1120, height: 720))
            for (name, look) in [("main-light", NSAppearance.Name.aqua), ("main-dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: look)  // app-wide, so SwiftUI redraws in that mode
                window.display()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                save(window.contentView!.superview!, to: folder.appendingPathComponent("\(name).png"))
            }
            NSApp.appearance = NSAppearance(named: .aqua)
        }

        let book = model.books[0]
        await render(BookDetail(book: book).environmentObject(model), size: CGSize(width: 520, height: 1180),
                     title: book.displayTitle, to: folder.appendingPathComponent("book-panel.png"))
        if let job = model.jobs.first {
            await render(JobDetail(job: job).environmentObject(model), size: CGSize(width: 520, height: 640),
                         title: job.displayTitle, to: folder.appendingPathComponent("mp3-job.png"))
        }
        await render(GeneralSettings().environmentObject(model), size: CGSize(width: 560, height: 300),
                     title: "Settings: General", to: folder.appendingPathComponent("settings-general.png"))
        await render(VoiceSettings().environmentObject(model), size: CGSize(width: 560, height: 360),
                     title: "Settings: Voice", to: folder.appendingPathComponent("settings-voice.png"))
        await render(SetupView().environmentObject(model), size: CGSize(width: 640, height: 460),
                     title: "Audiobook Maker", to: folder.appendingPathComponent("first-launch.png"))
        await render(AboutView(), size: CGSize(width: 520, height: 600),
                     title: "About Audiobook Maker", to: folder.appendingPathComponent("about.png"))
        restore()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// Draws a view in an invisible window of its own, title bar included.
    private static func render<V: View>(_ view: V, size: CGSize, title: String, to url: URL) async {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false  // we own it; letting close() free it too crashes the app
        window.title = title
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
        window.setContentSize(size)
        window.alphaValue = 0  // never flashes on screen
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 800_000_000)
        save(window.contentView!.superview!, to: url)
        window.close()
    }

    private static func save(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: demo content (generated covers)

    private static func loadDemo(_ model: AppModel) {
        let demo: [(String, String, NSColor, BookState, Double, String)] = [
            ("The Call of the Wild", "Jack London", NSColor(calibratedRed: 0.36, green: 0.40, blue: 0.22, alpha: 1),
             .rendering, 0.52, "Chapter 4 of 7: Who Has Won to Mastership · about 21 min left"),
            ("Autobiography of Benjamin Franklin", "Benjamin Franklin", NSColor(calibratedRed: 0.24, green: 0.45, blue: 0.22, alpha: 1),
             .done, 1, "Autobiography of Benjamin Franklin.m4b"),
            ("The Works of Edgar Allan Poe, Volume 2", "Edgar Allan Poe", NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.19, alpha: 1),
             .ready, 0, ""),
            ("Life on the Mississippi", "Mark Twain", NSColor(calibratedRed: 0.42, green: 0.28, blue: 0.18, alpha: 1),
             .waiting, 0, ""),
        ]
        model.books = demo.map { title, author, color, state, progress, detail in
            let book = Book(url: URL(fileURLWithPath: "/Books/\(title).epub"))
            book.title = title
            book.author = author
            book.cover = cover(title: title, author: author, color: color)
            book.state = state
            book.progress = progress
            book.detail = detail
            return book
        }
        let london = model.books[0]
        london.summary = "7 chapters, 31,960 words, ~3.4 h of audio"
        london.coverNote = "Found: The Call of the Wild.jpg"
        london.chapters = ["Into the Primitive", "The Law of Club and Fang", "The Dominant Primordial Beast",
                           "Who Has Won to Mastership", "The Toil of Trace and Trail", "For the Love of a Man",
                           "The Sounding of the Call"]
        london.unknownWords = [WordCount(word: "Sol-leks", count: 18), WordCount(word: "Dyea", count: 4),
                               WordCount(word: "Skaguay", count: 3), WordCount(word: "Perrault", count: 31)]
        let job = AudioJob(sources: [URL(fileURLWithPath: "/Audiobooks/Meditations")])
        job.title = "Meditations"
        job.author = "Marcus Aurelius"
        job.cover = cover(title: "Meditations", author: "Marcus Aurelius",
                          color: NSColor(calibratedRed: 0.55, green: 0.20, blue: 0.24, alpha: 1))
        job.state = .ready
        job.summary = "12 files, 5.4 h of audio"
        job.tracks = (1...12).map { Track(url: URL(fileURLWithPath: "/Audiobooks/Meditations/Meditations - Book \($0).mp3"),
                                          name: "Book \($0)", duration: "00:27:00") }
        model.jobs = [job]
        for book in [model.books[3], model.books[2]] {  // Mississippi next, then Poe
            book.queued = true
            model.enqueue(book.id)
        }
        model.currentItem = london.id
        model.selection = london.id
        model.voice = "bm_george"
        model.outputPath = "/Users/you/Audiobooks"  // a neutral path for the status bar
        model.lastMessage = ""
        model.showLog = false
    }

    private static func cover(title: String, author: String, color: NSColor) -> NSImage {
        let size = NSSize(width: 300, height: 435)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let frame = NSBezierPath(rect: NSRect(x: 18, y: 18, width: size.width - 36, height: size.height - 36))
        frame.lineWidth = 2
        frame.stroke()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Georgia-Bold", size: 34) ?? .boldSystemFont(ofSize: 34),
                                                         .foregroundColor: NSColor.white, .paragraphStyle: style]
        let authorAttrs: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Georgia", size: 20) ?? .systemFont(ofSize: 20),
                                                          .foregroundColor: NSColor.white.withAlphaComponent(0.85),
                                                          .paragraphStyle: style]
        (title as NSString).draw(in: NSRect(x: 34, y: 170, width: size.width - 68, height: 200), withAttributes: titleAttrs)
        (author as NSString).draw(in: NSRect(x: 34, y: 60, width: size.width - 68, height: 40), withAttributes: authorAttrs)
        image.unlockFocus()
        return image
    }
}
