import AppKit
import SwiftUI

/// An audiobook you already have as MP3s (a folder, or files dropped together), to be joined into one M4B
/// with a chapter per file. Runs in the same queue as the books, after them (audio2m4b.py join).
final class AudioJob: ObservableObject, Identifiable {
    let id = UUID()
    let sources: [URL]
    @Published var title = ""
    @Published var author = ""
    @Published var cover: NSImage?
    @Published var coverURL: URL?          // an image the user chose, dropped or pasted
    @Published var coverNote = ""
    @Published var chapters: [String] = []
    @Published var summary = ""
    @Published var state: BookState = .waiting
    @Published var progress = 0.0
    @Published var detail = ""
    @Published var output: URL?

    init(sources: [URL]) {
        self.sources = sources
    }

    var sourceName: String {
        sources.count == 1 ? sources[0].lastPathComponent : "\(sources.count) audio files"
    }
    var displayTitle: String { title.isEmpty ? sourceName : title }
}

extension AppModel {
    static let audioTypes = ["mp3", "m4a", "m4b", "aac", "ogg", "opus", "flac", "wav", "wma"]

    var selectedJob: AudioJob? { jobs.first { $0.id == selection } }

    static func containsAudio(_ folder: URL) -> Bool {
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if audioTypes.contains(url.pathExtension.lowercased()) { return true }
        }
        return false
    }

    /// Each folder becomes one job; loose audio files dropped together become one job.
    func addAudio(_ urls: [URL]) {
        var groups: [[URL]] = []
        var loose: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                if Self.containsAudio(url) { groups.append([url]) }
            } else if Self.audioTypes.contains(url.pathExtension.lowercased()) {
                loose.append(url)
            }
        }
        if !loose.isEmpty {
            groups.append(loose.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        }
        for sources in groups where !jobs.contains(where: { $0.sources == sources }) {
            let job = AudioJob(sources: sources)
            jobs.append(job)
            checkJob(job)
            if selection == nil { selection = job.id }
        }
    }

    func removeJob(_ job: AudioJob) {
        guard job.state != .rendering else { return }
        jobs.removeAll { $0.id == job.id }
        if selection == job.id { selection = books.first?.id ?? jobs.first?.id }
    }

    private func jobArgs(_ job: AudioJob) -> [String] {
        var args = ["join"] + job.sources.map(\.path)
        if !job.title.isEmpty { args += ["--title", job.title] }
        if !job.author.isEmpty { args += ["--author", job.author] }
        if let cover = job.coverURL { args += ["--cover", cover.path] }
        return args
    }

    /// Lists the chapters (one per file), title, author and cover without encoding anything.
    func checkJob(_ job: AudioJob) {
        guard let engine, job.state != .rendering else { return }
        job.state = .checking
        job.chapters = []
        var titleLine = true
        engine.run([engine.script("audio2m4b.py")] + jobArgs(job) + ["--check"], onLine: { line in
            if titleLine, line.contains(" — ") {
                titleLine = false
                let parts = line.components(separatedBy: " — ")
                if job.title.isEmpty { job.title = parts[0] }
                if job.author.isEmpty, parts.count > 1, parts[1] != "unknown author" { job.author = parts[1] }
            } else if line.contains(" files, ") && line.hasSuffix("of audio") {
                job.summary = line
            } else if let m = EngineOutput.match(#"^\s+\d+\.\s(.+)\t(\S+)$"#, line) {
                job.chapters.append("\(m[1])  ·  \(m[2])")
            } else if line.hasPrefix("Cover: "), job.coverURL == nil {
                job.coverNote = line
            } else if line.hasPrefix("Cover image: "), job.coverURL == nil,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: String(line.dropFirst("Cover image: ".count)))) {
                job.cover = NSImage(data: data)
            }
        }, onExit: { status in
            if job.state == .checking {
                job.state = status == 0 ? .ready : .failed("Couldn't read these audio files")
            }
        })
    }

    func setJobCover(_ url: URL, for job: AudioJob, note: String? = nil) {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return }
        job.cover = image
        job.coverURL = url
        job.coverNote = note ?? "Your image: \(url.lastPathComponent)"
    }

    func renderJob(_ job: AudioJob) {
        guard let engine else { return }
        job.state = .rendering
        job.progress = 0
        job.detail = "Starting…"
        var lastError = ""
        var args = [engine.script("audio2m4b.py")] + jobArgs(job)
        if !outputPath.isEmpty || engine.isAppInstall, let folder = outputFolder {
            args += ["--output-dir", folder.path]
        }
        appendLog("=== \(job.displayTitle) (MP3 → M4B) ===")
        current = engine.run(args, onLine: { [weak self] line in
            self?.appendLog(line)
            if let p = EngineOutput.progress(line) {
                job.progress = Double(p.index) / Double(p.total + 1)  // the last step joins them
                job.detail = "Converting file \(p.index) of \(p.total)"
            } else if let minutes = EngineOutput.minutesLeft(line) {
                job.detail += " · about \(minutes) min left"
            } else if line.hasPrefix("Joining ") {
                job.detail = "Joining into one M4B…"
            } else if let url = EngineOutput.wrote(line) {
                job.output = url
                job.progress = 1
            } else if line.contains("Error") {
                lastError = line
            }
        }, onExit: { [weak self] status in
            if self?.stopRequested == true {
                job.state = .ready
                job.detail = "Stopped"
            } else if status == 0 {
                job.state = .done
                job.detail = job.output?.lastPathComponent ?? "Done"
            } else {
                job.state = .failed(lastError)
                job.detail = lastError.isEmpty ? "Something went wrong" : lastError
            }
            self?.isPaused = false
            self?.renderNext()
        })
    }
}

/// The box under the books: drop MP3 folders here.
struct JobsBox: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("MP3 audiobooks → M4B", systemImage: "headphones").font(.headline)
                Spacer()
                Button { model.addAudio(chooseAudio()) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add a folder of MP3s, or MP3 files")
                    .accessibilityLabel("Add MP3 audiobooks")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if model.jobs.isEmpty {
                VStack(spacing: 6) {
                    Text("Drop a folder of MP3s here").font(.callout)
                    Text("Already have an audiobook as MP3 files? They become one M4B, one chapter per file.")
                        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.jobs) { job in
                        JobRow(job: job)
                            .tag(job.id)
                            .contextMenu {
                                Button("Remove from queue") { model.removeJob(job) }
                                if let out = job.output {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                                }
                            }
                    }
                }
                .onDeleteCommand { if let job = model.selectedJob { model.removeJob(job) } }
                .accessibilityLabel("MP3 audiobooks to join")
            }
        }
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { model.addAudio($0) }
            return true
        }
    }
}

struct JobRow: View {
    @ObservedObject var job: AudioJob

    var body: some View {
        HStack(spacing: 10) {
            CoverView(image: job.cover, width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayTitle).fontWeight(.medium).lineLimit(1)
                Text(job.author.isEmpty ? job.sourceName : job.author)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                if job.state == .rendering {
                    ProgressView(value: job.progress)
                    Text(job.detail).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
            StateBadge(state: job.state)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([job.displayTitle, job.author, job.state.label].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

struct JobDetail: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var job: AudioJob
    @State private var coverTargeted = false
    @State private var pasteFailed = false

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 4) {
                        Button { if let url = chooseImage() { model.setJobCover(url, for: job) } } label: {
                            CoverView(image: job.cover, width: 90)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(coverTargeted ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help("Click to choose a cover image, or drop one here")
                        .accessibilityLabel("Cover image. Choose another image, or drop one here.")
                        .onDrop(of: [.fileURL], isTargeted: $coverTargeted) { providers in
                            loadURLs(providers) { urls in
                                if let url = urls.first { model.setJobCover(url, for: job) }
                            }
                            return true
                        }
                        Text("Click or drop a cover").font(.caption2).foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Title", text: $job.title)
                        TextField("Author", text: $job.author)
                        Text(job.coverNote).font(.caption).foregroundColor(.secondary)
                        if !job.summary.isEmpty {
                            Text(job.summary).font(.caption).foregroundColor(.secondary)
                        }
                        HStack {
                            Button { if let url = chooseImage() { model.setJobCover(url, for: job) } } label: {
                                Label("Choose cover…", systemImage: "photo")
                            }
                            Button {
                                if let url = model.pastedImage() {
                                    model.setJobCover(url, for: job, note: "Cover: pasted image")
                                    pasteFailed = false
                                } else { pasteFailed = true }
                            } label: { Label("Paste cover", systemImage: "doc.on.clipboard") }
                                .help("Use an image you copied")
                        }
                        if pasteFailed {
                            Text("There's no image on the clipboard.").font(.caption).foregroundColor(.red)
                        }
                        if let out = job.output {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                        }
                    }
                }
            }

            Section {
                if job.state == .checking {
                    ProgressView().controlSize(.small)
                } else if job.chapters.isEmpty {
                    Text("No audio files found yet").foregroundColor(.secondary)
                } else {
                    ForEach(Array(job.chapters.prefix(60).enumerated()), id: \.offset) { i, title in
                        Text("\(i + 1). \(title)").lineLimit(1)
                    }
                    if job.chapters.count > 60 {
                        Text("+ \(job.chapters.count - 60) more").foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Chapters (\(job.chapters.count))")
            } footer: {
                Text("One chapter per file, in file-name order. Chapter names come from the files' title tags, or their names.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Open panel for MP3 folders or files.
@MainActor
func chooseAudio() -> [URL] {
    let panel = NSOpenPanel()
    panel.title = "Add MP3 audiobooks"
    panel.prompt = "Add"
    panel.message = "Choose a folder of MP3s (one audiobook), or MP3 files"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.audio, .folder]
    return panel.runModal() == .OK ? panel.urls : []
}
