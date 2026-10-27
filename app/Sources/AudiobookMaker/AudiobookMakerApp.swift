import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct AudiobookMakerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Audiobook Maker") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { handleLaunchArguments() }
                .onOpenURL { model.add([$0]) }  // files dropped on the app's Dock icon
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button("Support this project…") { openDonatePage() }
            }
        }
    }
}

extension AudiobookMakerApp {
    /// Optional launch arguments, for scripting and testing:
    ///   open -a "Audiobook Maker" --args --add book.pdf --add other.epub --start
    func handleLaunchArguments() {
        let args = CommandLine.arguments
        let files = zip(args, args.dropFirst()).filter { $0.0 == "--add" }.map { URL(fileURLWithPath: $0.1) }
        if !files.isEmpty { model.add(files) }
        if args.contains("--start") {
            // let the dry runs read the books first
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { model.startQueue() }
        }
    }
}

/// The donation page ships inside the app and opens in the default browser.
func openDonatePage() {
    if let page = Bundle.main.url(forResource: "donate", withExtension: "html") {
        NSWorkspace.shared.open(page)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var importing = false
    @State private var choosingEngine = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.engine == nil || model.engine?.isInstalled == false {
                engineBanner
            }
            HSplitView {
                queue
                    .frame(minWidth: 320, idealWidth: 380)
                detail
                    .frame(minWidth: 400)
            }
            statusBar
        }
        .toolbar {
            ToolbarItemGroup {
                Button { importing = true } label: { Label("Add books", systemImage: "plus") }
                    .help("Add PDF, EPUB or TXT files, or a folder of them")
                if model.isRunning {
                    Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                } else {
                    Button { model.startQueue() } label: { Label("Start queue", systemImage: "play.fill") }
                        .disabled(model.books.isEmpty || model.engine == nil)
                }
                Button {
                    if let folder = model.engine?.outputFolder {
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(folder)
                    }
                } label: { Label("Output folder", systemImage: "folder") }
                Button { openDonatePage() } label: { Label("Donate", systemImage: "heart") }
                    .help("Support this project")
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.pdf, .plainText, .folder, UTType(filenameExtension: "epub") ?? .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
        .fileImporter(isPresented: $choosingEngine, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.chooseEngineFolder(url) }
        }
    }

    private var engineBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(model.engine == nil
                 ? "Can't find the audiobook tools. Choose the project folder that contains audiobook.py."
                 : "The tools aren't installed yet. Run ./setup.sh in the project folder first.")
            Spacer()
            Button("Choose folder…") { choosingEngine = true }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.2))
    }

    private var queue: some View {
        VStack(spacing: 0) {
            if model.books.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "books.vertical").font(.system(size: 36)).foregroundColor(.secondary)
                    Text("Drop books here").font(.title3)
                    Text("PDF, EPUB or TXT files, or a folder of them").foregroundColor(.secondary)
                    Button("Add books…") { importing = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.books) { book in
                        BookRow(book: book)
                            .tag(book.id)
                            .contextMenu {
                                Button("Remove from queue") { model.remove(book) }
                                if let out = book.output {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                                }
                            }
                    }
                }
            }
        }
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { model.add($0) }
            return true
        }
    }

    @ViewBuilder private var detail: some View {
        if let book = model.selectedBook {
            BookDetail(book: book)
        } else {
            Text("Select a book to see its settings")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var statusBar: some View {
        HStack {
            Text(model.lastMessage.isEmpty ? model.statusLine : model.lastMessage)
            Spacer()
            if let engine = model.engine {
                Text("Output: \(engine.outputFolder.path)").lineLimit(1).truncationMode(.head)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Turns dropped Finder items into file URLs.
func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url {
                lock.lock(); urls.append(url); lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}
