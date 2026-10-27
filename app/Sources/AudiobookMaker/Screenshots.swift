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
        func restore() {
            UserDefaults.standard.set(savedVoice, forKey: "voice")
            UserDefaults.standard.set(savedOutput, forKey: "outputPath")
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
            ("The Holographic Universe", "Michael Talbot", NSColor(calibratedRed: 0.20, green: 0.32, blue: 0.55, alpha: 1),
             .rendering, 0.38, "Chapter 4 of 10: I Sing the Body Holographic · about 48 min left"),
            ("Between Death and Life", "Dolores Cannon", NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.62, alpha: 1),
             .done, 1, "Dolores Cannon - Between Death and Life.m4b"),
            ("Money and the Law of Attraction", "Esther and Jerry Hicks", NSColor(calibratedRed: 0.13, green: 0.47, blue: 0.38, alpha: 1),
             .ready, 0, ""),
            ("Why You're Dumb, Sick and Broke", "Randy Gage", NSColor(calibratedRed: 0.62, green: 0.36, blue: 0.20, alpha: 1),
             .waiting, 0, ""),
        ]
        model.books = demo.map { title, author, color, state, progress, detail in
            let book = Book(url: URL(fileURLWithPath: "/Books/\(title).pdf"))
            book.title = title
            book.author = author
            book.cover = cover(title: title, author: author, color: color)
            book.state = state
            book.progress = progress
            book.detail = detail
            return book
        }
        let talbot = model.books[0]
        talbot.summary = "10 chapters, 118,240 words, ~12.7 h of audio"
        talbot.coverNote = "Found: The Holographic Universe.jpg"
        talbot.chapters = ["Introduction", "The Brain as Hologram", "The Cosmos as Hologram",
                           "The Holographic Model and Psychology", "I Sing the Body Holographic",
                           "A Pocketful of Miracles", "Seeing Holographically", "Time Out of Mind",
                           "Traveling in the Superhologram", "Return to the Dreamtime"]
        talbot.unknownWords = [WordCount(word: "Pribram", count: 64), WordCount(word: "superhologram", count: 12),
                               WordCount(word: "Grof", count: 38), WordCount(word: "Ullman", count: 9)]
        model.selection = talbot.id
        model.voice = "bm_george"
        model.outputPath = "/Users/you/Audiobooks"  // a neutral path for the status bar
        model.lastMessage = ""
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
