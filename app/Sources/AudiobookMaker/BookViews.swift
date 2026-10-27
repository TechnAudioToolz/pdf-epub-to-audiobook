import AppKit
import SwiftUI

struct CoverView: View {
    let image: NSImage?
    var width: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "book.closed").foregroundColor(.secondary)
                }
            }
        }
        .frame(width: width, height: width * 1.45)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct BookRow: View {
    @ObservedObject var book: Book

    var body: some View {
        HStack(spacing: 10) {
            CoverView(image: book.cover, width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.displayTitle).fontWeight(.medium).lineLimit(1)
                Text(book.author.isEmpty ? book.url.lastPathComponent : book.author)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                if book.state == .rendering {
                    ProgressView(value: book.progress)
                    Text(book.detail).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
            StateBadge(state: book.state)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [book.displayTitle]
        if !book.author.isEmpty { parts.append(book.author) }
        parts.append(book.state.label)
        if book.state == .rendering {
            parts.append("\(Int(book.progress * 100)) percent")
            if !book.detail.isEmpty { parts.append(book.detail) }
        }
        return parts.joined(separator: ", ")
    }
}

struct StateBadge: View {
    let state: BookState

    var color: Color {
        switch state {
        case .done, .skipped: return .green
        case .failed: return .red
        case .rendering: return .accentColor
        default: return .secondary
        }
    }

    var body: some View {
        Text(state.label)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
            .accessibilityLabel("Status: \(state.label)")
    }
}

struct BookDetail: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var book: Book
    @State private var coverTargeted = false
    @State private var choosingCover = false
    @State private var fixes: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 4) {
                        Button { choosingCover = true } label: {
                            CoverView(image: book.cover, width: 90)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(coverTargeted ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help("Click to choose a cover: a page of the book, a generated one, or an image file. Or drop an image here.")
                        .accessibilityLabel(book.cover == nil ? "No cover. Choose a cover, or drop an image here."
                                                              : "Cover image. Choose another cover, or drop an image here.")
                        .sheet(isPresented: $choosingCover) {
                            CoverPicker(book: book).environmentObject(model)
                        }
                            .onDrop(of: [.fileURL], isTargeted: $coverTargeted) { providers in
                                loadURLs(providers) { urls in
                                    if let url = urls.first { model.setCover(url, for: book) }
                                }
                                return true
                            }
                        Text("Click or drop a cover").font(.caption2).foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Title", text: $book.title)
                        TextField("Author", text: $book.author)
                        Text(book.coverNote).font(.caption).foregroundColor(.secondary)
                        if !book.summary.isEmpty {
                            Text(book.summary).font(.caption).foregroundColor(.secondary)
                        }
                        if let out = book.output {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                        }
                    }
                }
            }

            Section("Voice") {
                HStack {
                    VoicePicker(voice: $model.voice)
                    Button { model.listen("This is how \(book.displayTitle) will sound.", book: book) } label: {
                        Label("Listen", systemImage: "speaker.wave.2")
                    }
                }
                HStack {
                    Text("Speed")
                    Slider(value: $model.speed, in: 0.8...1.3, step: 0.05)
                    Text(String(format: "%.2f×", model.speed)).monospacedDigit().frame(width: 48)
                }
                Text("Most audiobook players can also change the speed while you listen, so 1.0× is a safe choice.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Reading and file") {
                ReadingOptions()
            }

            Section("Chapters (\(book.chapters.count))") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("One file, no chapter markers", isOn: $book.oneFile)
                        .toggleStyle(.checkbox)
                    Text("For books whose chapters below look wrong: the whole book is read straight through, "
                         + (model.outputFormat == "mp3" ? "as a single MP3." : "as one M4B without chapter markers."))
                        .font(.caption).foregroundColor(.secondary)
                }
                if book.state == .checking {
                    ProgressView().controlSize(.small)
                } else if book.chapters.isEmpty {
                    Text("No chapters found yet").foregroundColor(.secondary)
                } else {
                    ForEach(Array(book.chapters.prefix(40).enumerated()), id: \.offset) { i, title in
                        Text("\(i + 1). \(title)").lineLimit(1)
                    }
                    if book.chapters.count > 40 {
                        Text("+ \(book.chapters.count - 40) more").foregroundColor(.secondary)
                    }
                }
            }

            Section {
                if book.unknownWords.isEmpty {
                    Button("Find words the voice will guess") { model.checkWords(book) }
                } else {
                    ForEach(book.unknownWords.prefix(25)) { item in
                        HStack {
                            Text(item.word)
                            Text("\(item.count)×").foregroundColor(.secondary).monospacedDigit()
                            Spacer()
                            Button { model.listen(item.word, book: book) } label: { Image(systemName: "speaker.wave.2") }
                                .help("Listen")
                                .accessibilityLabel("Listen to \(item.word)")
                            TextField("", text: Binding(
                                get: { fixes[item.word, default: ""] },
                                set: { fixes[item.word] = $0 }), prompt: Text("Say as…"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 140)
                                .accessibilityLabel("Say \(item.word) as")
                            Button("Save") { model.savePronunciation(word: item.word, sayAs: fixes[item.word, default: ""], book: book) }
                                .disabled(fixes[item.word, default: ""].isEmpty)
                        }
                    }
                }
            } header: {
                Text("Words to check")
            } footer: {
                Text("Type a sound-alike spelling, like Ee-nock, then Save. It applies to this book only.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Pick a cover: one of the book's first pages, its own cover, a generated one, or any image file.
struct CoverPicker: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var book: Book
    @Environment(\.dismiss) private var dismiss
    @State private var pasteFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a cover").font(.title2)
            Text("Pick one of the book's first pages, generate a cover from the title, paste an image, or choose an image file.")
                .foregroundColor(.secondary)
            if book.coverChoices.isEmpty && book.loadingCoverChoices {
                ProgressView("Getting the pages…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if book.coverChoices.isEmpty && !book.generatingCover {
                Text("No pages to show for this book. Generate a cover, paste an image, or choose a file.")
                    .foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14)], spacing: 14) {
                        ForEach(book.coverChoices) { choice in
                            Button {
                                model.setCover(choice.url, for: book, note: "Cover: \(choice.label.lowercased())")
                                dismiss()
                            } label: {
                                VStack(spacing: 4) {
                                    Image(nsImage: (try? Data(contentsOf: choice.url)).flatMap(NSImage.init(data:)) ?? NSImage())
                                        .resizable().aspectRatio(contentMode: .fit)
                                        .frame(height: 170)
                                        .shadow(radius: 1)
                                    Text(choice.label).font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Use \(choice.label) as the cover")
                        }
                        if book.generatingCover {
                            ProgressView().frame(height: 170)
                        }
                    }
                    .padding(4)
                }
            }
            if pasteFailed {
                Text("There's no image on the clipboard. Copy an image first (in a browser: right-click → Copy Image).")
                    .font(.caption).foregroundColor(.red)
            }
            HStack {
                Button {
                    model.generateCover(book)
                } label: { Label("Generate cover", systemImage: "wand.and.stars") }
                    .disabled(book.generatingCover || book.coverChoices.contains { $0.label == "Generated" })
                    .help("Make a plain cover from the title and author")
                Button {
                    if model.pasteCover(for: book) { dismiss() } else { pasteFailed = true }
                } label: { Label("Paste image", systemImage: "doc.on.clipboard") }
                    .keyboardShortcut("v")
                    .help("Use an image you copied (⌘V)")
                Button("Choose an image file…") {
                    if let url = chooseImage() {
                        model.setCover(url, for: book)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 660, height: 560)
        .onAppear { model.loadCoverChoices(book) }
    }
}

/// "Read" and "Save as" menus, shared by the book panel and Settings.
struct ReadingOptions: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Also read")
                Spacer()
                Button("All") { model.keep = Set(AppModel.keepChoices.map(\.id)) }
                    .disabled(model.keep.count == AppModel.keepChoices.count)
                Button("None") { model.keep = [] }
                    .disabled(model.keep.isEmpty)
            }
            ForEach(AppModel.keepChoices, id: \.id) { choice in
                Toggle(choice.label, isOn: Binding(
                    get: { model.keep.contains(choice.id) },
                    set: { on in if on { model.keep.insert(choice.id) } else { model.keep.remove(choice.id) } }))
                    .toggleStyle(.checkbox)
            }
            Text(model.keep.isEmpty ? "Unchecked: just the book is read, the way a narrator would."
                                    : "Checked items are read aloud where they appear.")
                .font(.caption).foregroundColor(.secondary)
        }
        Picker("Save as", selection: $model.outputFormat) {
            Text("One M4B audiobook with chapters").tag("m4b")
            Text("MP3 files, one per chapter").tag("mp3")
        }
        Text(model.outputFormat == "mp3"
             ? "MP3s play almost anywhere: a folder with one numbered file per chapter."
             : "M4B is the audiobook format: one file with chapters, for Apple Books, BookPlayer and most audiobook apps.")
            .font(.caption).foregroundColor(.secondary)
    }
}

/// Voice menu with all 28 English voices under American/British, female/male headings.
struct VoicePicker: View {
    @Binding var voice: String

    var body: some View {
        Picker("Voice", selection: $voice) {
            ForEach(AppModel.voiceGroups, id: \.prefix) { group in
                Section(group.title) {
                    ForEach(group.names, id: \.self) { name in
                        Text(name.capitalized).tag("\(group.prefix)_\(name)")
                    }
                }
            }
        }
    }
}

/// The engine's output, live: each chapter, timings and errors, plus one updating progress line.
struct LogView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if model.log.isEmpty {
                        Text("Start the queue to see each chapter here, with how far along it is and the time left.")
                            .foregroundColor(.secondary)
                    }
                    ForEach(Array(model.log.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .textSelection(.enabled)
                            .id(i)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .safeAreaInset(edge: .bottom) {
                if !model.liveStatus.isEmpty {
                    Text(model.liveStatus)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.bar)
                        .accessibilityLabel("Progress: \(model.liveStatus)")
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.log.count) { count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
        .accessibilityLabel("Engine log")
    }
}
