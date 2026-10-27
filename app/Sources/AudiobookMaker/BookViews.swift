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
    }
}

struct BookDetail: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var book: Book
    @State private var coverTargeted = false
    @State private var fixes: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 4) {
                        CoverView(image: book.cover, width: 90)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(coverTargeted ? Color.accentColor : .clear, lineWidth: 2))
                            .onDrop(of: [.fileURL], isTargeted: $coverTargeted) { providers in
                                loadURLs(providers) { urls in
                                    if let url = urls.first { model.setCover(url, for: book) }
                                }
                                return true
                            }
                        Text("Drop a cover").font(.caption2).foregroundColor(.secondary)
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
                    Picker("Voice", selection: $model.voice) {
                        ForEach(AppModel.voices, id: \.id) { v in Text(v.label).tag(v.id) }
                    }
                    Button { model.listen("This is how \(book.displayTitle) will sound.", book: book) } label: {
                        Label("Listen", systemImage: "speaker.wave.2")
                    }
                }
                HStack {
                    Text("Speed")
                    Slider(value: $model.speed, in: 0.8...1.3, step: 0.05)
                    Text(String(format: "%.2f×", model.speed)).monospacedDigit().frame(width: 48)
                }
            }

            Section("Chapters (\(book.chapters.count))") {
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
                            TextField("Say as…", text: Binding(
                                get: { fixes[item.word, default: ""] },
                                set: { fixes[item.word] = $0 }))
                                .frame(width: 120)
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
