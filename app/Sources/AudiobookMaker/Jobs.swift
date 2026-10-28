import AppKit
import SwiftUI

/// An audiobook you already have as MP3s (a folder, or files dropped together), to be joined into one M4B
/// with a chapter per file. Runs in the same queue as the books, after them (audio2m4b.py join).
final class AudioJob: ObservableObject, Identifiable {
    let id = UUID()
    /// What to join, in order: the dropped folder at first, then (once checked) its files, which can be
    /// added to, reordered and removed in the job's panel.
    @Published var sources: [URL]
    @Published var title = ""
    @Published var author = ""
    @Published var cover: NSImage?
    @Published var coverURL: URL?          // an image the user chose, dropped or pasted
    @Published var coverNote = ""
    @Published var tracks: [Track] = []
    @Published var summary = ""
    @Published var state: BookState = .waiting
    @Published var progress = 0.0
    @Published var detail = ""
    @Published var output: URL?
    @Published var queued = false

    init(sources: [URL]) {
        self.sources = sources
    }

    var sourceName: String {
        sources.count == 1 ? sources[0].lastPathComponent : "\(sources.count) audio files"
    }
    var displayTitle: String { title.isEmpty ? sourceName : title }
}

/// One audio file of a job: its chapter name and length.
struct Track: Identifiable, Equatable {
    let url: URL
    var name: String
    var duration: String
    var id: URL { url }
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
        queueOrder.removeAll { $0 == job.id }
        jobs.removeAll { $0.id == job.id }
        if selection == job.id { selection = books.first?.id ?? jobs.first?.id }
    }

    private func jobArgs(_ job: AudioJob) -> [String] {
        var args = ["join"] + job.sources.map(\.path)  // in this order
        if !job.title.isEmpty { args += ["--title", job.title] }
        if !job.author.isEmpty { args += ["--author", job.author] }
        if let cover = job.coverURL { args += ["--cover", cover.path] }
        return args
    }

    /// Lists the chapters (one per file), title, author and cover without encoding anything.
    func checkJob(_ job: AudioJob) {
        guard let engine, job.state != .rendering else { return }
        job.state = .checking
        var tracks: [Track] = []
        var titleLine = true
        engine.run([engine.script("audio2m4b.py")] + jobArgs(job) + ["--check", "--show-paths"], onLine: { line in
            if titleLine, line.contains(" — ") {
                titleLine = false
                let parts = line.components(separatedBy: " — ")
                if job.title.isEmpty { job.title = parts[0] }
                if job.author.isEmpty, parts.count > 1, parts[1] != "unknown author" { job.author = parts[1] }
            } else if line.contains(" file") && line.hasSuffix("of audio") {
                job.summary = line
            } else if let m = EngineOutput.match(#"^\s+\d+\.\s(.+)\t(\S+)\t(.+)$"#, line) {
                tracks.append(Track(url: URL(fileURLWithPath: m[3]), name: m[1], duration: m[2]))
            } else if line.hasPrefix("Cover: "), job.coverURL == nil {
                job.coverNote = line
            } else if line.hasPrefix("Cover image: "), job.coverURL == nil,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: String(line.dropFirst("Cover image: ".count)))) {
                job.cover = NSImage(data: data)
            }
        }, onExit: { status in
            if status == 0, !tracks.isEmpty {
                job.tracks = tracks
                job.sources = tracks.map(\.url)  // from now on the job is this exact list of files
            }
            if job.state == .checking {
                job.state = status == 0 ? .ready : .failed("Couldn't read these audio files")
            }
        })
    }

    // MARK: editing a job's files

    /// Adds audio files (or every audio file in a folder, in name order) to the end of the job.
    func addFiles(_ urls: [URL], to job: AudioJob) {
        guard job.state != .rendering else { return }
        var new: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                var found: [URL] = []
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
                while let f = walker?.nextObject() as? URL {
                    if Self.audioTypes.contains(f.pathExtension.lowercased()) { found.append(f) }
                }
                new += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if Self.audioTypes.contains(url.pathExtension.lowercased()) {
                new.append(url)
            }
        }
        let known = Set(job.sources.map(\.standardizedFileURL))
        new = new.filter { !known.contains($0.standardizedFileURL) }
        guard !new.isEmpty else { return }
        job.sources += new
        job.tracks += new.map { Track(url: $0, name: $0.deletingPathExtension().lastPathComponent, duration: "…") }
        if job.state == .done { job.state = .ready }
        checkJob(job)
    }

    func moveTracks(_ job: AudioJob, from: IndexSet, to: Int) {
        guard job.state != .rendering else { return }
        job.tracks.move(fromOffsets: from, toOffset: to)
        job.sources = job.tracks.map(\.url)
        checkJob(job)
    }

    func removeTrack(_ track: Track, from job: AudioJob) {
        guard job.state != .rendering, job.tracks.count > 1 else { return }
        job.tracks.removeAll { $0 == track }
        job.sources = job.tracks.map(\.url)
        checkJob(job)
    }

    /// Back to name order ("Part 2" before "Part 10"; disc folders in order).
    func sortTracks(_ job: AudioJob) {
        guard job.state != .rendering else { return }
        job.tracks.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        job.sources = job.tracks.map(\.url)
        checkJob(job)
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
        job.queued = false
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
            if self?.preempted == job.id {
                job.state = .ready
                job.queued = true
                job.detail = "Paused for another book; carries on next"
                self?.requeueAfterJump(job.id)
            } else if self?.stopRequested == true {
                job.state = .ready
                job.queued = true
                self?.enqueue(job.id, at: 0)
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
                // the same look as the books area above
                VStack(spacing: 10) {
                    Image(systemName: "headphones").font(.system(size: 36)).foregroundColor(.secondary)
                        .accessibilityHidden(true)
                    Text("Drop audio files here").font(.title3)
                    Text("MP3s or a folder of them: they become one M4B, one chapter per file")
                        .foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button("Add audio…") { model.addAudio(chooseAudio()) }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.jobsInOrder) { job in
                        JobRow(job: job, position: model.queuePosition(job.id),
                               move: { model.moveInQueue(job.id, by: $0) },
                               isLastInQueue: model.queuePosition(job.id) == model.queueOrder.count,
                               paused: model.isPaused)
                            .tag(job.id)
                            .contentShape(Rectangle())
                            .onDrop(of: [.fileURL], isTargeted: nil) { providers in  // more files for this job
                                loadURLs(providers) { model.addFiles($0, to: job) }
                                return true
                            }
                            .simultaneousGesture(TapGesture().onEnded { model.selection = job.id })
                            .contextMenu {
                                QueueMenu(state: job.state, queued: job.queued, isJob: true,
                                          add: { model.addToQueue(job) }, remove: { model.takeOut(job.id) },
                                          now: { model.renderNow(job.id) }, removeFromList: { model.removeJob(job) })
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
    var position: Int? = nil
    var move: ((Int) -> Void)? = nil
    var isLastInQueue = false
    var paused = false

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
            if let position, let move { QueueArrows(position: position, isLast: isLastInQueue, move: move) }
            StateBadge(state: job.state, queued: job.queued, position: position, paused: paused)
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
    private var editable: Bool { job.state != .rendering }

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
                        TextField("Title", text: $job.title, prompt: Text("Book title"))
                            .textFieldStyle(.roundedBorder)
                        TextField("Author", text: $job.author, prompt: Text("Author"))
                            .textFieldStyle(.roundedBorder)
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
                QueueButton(state: job.state, queued: job.queued, position: model.queuePosition(job.id),
                            paused: model.isPaused, resume: { model.resume() },
                            after: model.queuedBefore(job.id),
                            add: { model.addToQueue(job) }, remove: { model.takeOut(job.id) },
                            now: { model.renderNow(job.id) })
            }

            Section {
                if job.tracks.isEmpty {
                    if job.state == .checking { ProgressView().controlSize(.small) }
                    else { Text("No audio files found yet").foregroundColor(.secondary) }
                }
                ForEach(Array(job.tracks.enumerated()), id: \.element.id) { i, track in
                    TrackRow(number: i + 1, track: track, editable: editable, isFirst: i == 0,
                             isLast: i == job.tracks.count - 1, canRemove: job.tracks.count > 1,
                             move: { model.moveTracks(job, from: IndexSet(integer: i), to: i + $0 + ($0 > 0 ? 1 : 0)) },
                             remove: { model.removeTrack(track, from: job) })
                }
                .onMove { model.moveTracks(job, from: $0, to: $1) }
                HStack {
                    Button { model.addFiles(chooseAudio(), to: job) } label: { Label("Add files…", systemImage: "plus") }
                    Button { model.sortTracks(job) } label: { Label("Sort by name", systemImage: "arrow.up.arrow.down") }
                    Spacer()
                    if job.state == .checking && !job.tracks.isEmpty { ProgressView().controlSize(.small) }
                }
                .disabled(!editable)
            } header: {
                Text("Files and chapters (\(job.tracks.count))")
            } footer: {
                Text("One chapter per file, in this order. Drop more audio files here or on the job in the list, "
                     + "drag files to reorder, or use the arrows.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { model.addFiles($0, to: job) }
            return true
        }
        .formStyle(.grouped)
    }
}

/// One file in a job: its full file name, then its chapter name and length, with move and remove buttons.
struct TrackRow: View {
    let number: Int
    let track: Track
    let editable: Bool
    let isFirst: Bool
    let isLast: Bool
    let canRemove: Bool
    let move: (Int) -> Void   // -1 up, +1 down
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).").monospacedDigit().foregroundColor(.secondary).frame(minWidth: 26, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.url.lastPathComponent).textSelection(.enabled)
                Text("\(track.name)  ·  \(track.duration)").font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
            if editable {
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(isFirst).help("Move up").accessibilityLabel("Move \(track.url.lastPathComponent) up")
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(isLast).help("Move down").accessibilityLabel("Move \(track.url.lastPathComponent) down")
                Button(action: remove) { Image(systemName: "minus.circle") }
                    .disabled(!canRemove).help("Remove from this audiobook")
                    .accessibilityLabel("Remove \(track.url.lastPathComponent)")
            }
        }
        .buttonStyle(.borderless)
        .help(track.url.path)
    }
}

/// The big "Add to queue" button at the top of a book's or job's panel, or what's happening to it.
struct QueueButton: View {
    let state: BookState
    let queued: Bool
    var position: Int? = nil
    var paused = false
    var resume: () -> Void = {}
    var after: String? = nil      // what's made just before it (or is being made now)
    let add: () -> Void
    let remove: () -> Void
    var now: () -> Void = {}

    private var queueText: String {
        guard let position else { return "In the queue" }
        if let after { return "#\(position) in the queue: made after “\(after)”" }
        return "#\(position) in the queue: next up"
    }

    var body: some View {
        HStack {
            switch state {
            case .rendering where paused:
                Label("Paused", systemImage: "pause.circle.fill")
                    .foregroundColor(.yellow)
                Spacer()
                Button("Resume", action: resume)
            case .rendering:
                Label("Rendering now", systemImage: "waveform").foregroundColor(.accentColor)
            case .done, .skipped:
                Label(state == .skipped ? "Already made earlier: it's in the output folder" : "Finished",
                      systemImage: "checkmark.circle.fill").foregroundColor(.green)
                Spacer()
                Button("Make it again", action: add)
                    .help("Make it again and replace the existing audiobook")
            default:
                if queued {
                    Label(queueText, systemImage: "clock").foregroundColor(.orange).lineLimit(2)
                    Spacer()
                    if position != 1 || after != nil {
                        Button("Render now", action: now)
                            .help("Jump the queue: whatever is being made pauses, and carries on after this")
                    }
                    Button("Take out", action: remove)
                } else {
                    Button(action: add) {
                        Label("Add to queue", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .help("Queue it; the queue starts by itself if it isn't running")
                    Button("Render now", action: now)
                        .controlSize(.large)
                        .help("Jump the queue: whatever is being made pauses, and carries on after this")
                }
            }
        }
    }
}

/// Right-click menu for a book or MP3 job. Built from the item's current state each time it opens.
struct QueueMenu: View {
    let state: BookState
    let queued: Bool
    var isJob = false
    let add: () -> Void
    let remove: () -> Void
    let now: () -> Void
    var checkAgain: (() -> Void)? = nil
    var clearAudio: (() -> Void)? = nil
    let removeFromList: () -> Void

    var body: some View {
        if state != .rendering {
            Button("Render now (jump the queue)", action: now)
            if queued {
                Button("Take out of queue", action: remove)
            } else {
                Button(state == .done || state == .skipped ? "Make it again" : "Add to queue", action: add)
            }
        }
        if let checkAgain, let clearAudio {
            Divider()
            Button("Check again from scratch", action: checkAgain).disabled(state == .rendering)
            Button("Clear saved audio too, and check again", action: clearAudio).disabled(state == .rendering)
        }
        Divider()
        Button("Remove from list", action: removeFromList).disabled(state == .rendering)
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
