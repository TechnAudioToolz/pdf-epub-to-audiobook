import AppKit
import SwiftUI

/// The standard Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            VoiceSettings().tabItem { Label("Voice", systemImage: "speaker.wave.2") }
            ToolsSettings().tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
            UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            SupportSettings().tabItem { Label("Support", systemImage: "heart") }
            AboutView().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 460)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Finished audiobooks") {
                LabeledContent("Save to") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(model.outputFolder?.path ?? "Not set")
                            .lineLimit(1).truncationMode(.head)
                            .foregroundColor(.secondary)
                        HStack {
                            Button("Choose…") {
                                if let url = chooseFolder("Choose where finished audiobooks are saved") {
                                    model.outputPath = url.path
                                }
                            }
                            if !model.outputPath.isEmpty {
                                Button("Use project folder") { model.outputPath = "" }
                            }
                            Button("Show in Finder") {
                                if let folder = model.outputFolder {
                                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                    NSWorkspace.shared.open(folder)
                                }
                            }
                        }
                    }
                }
                Picker("File names", selection: $model.nameFromFile) {
                    Text("Same as the book file").tag(true)
                    Text("Author - Title").tag(false)
                }
            }
            Section("Reading and file") {
                ReadingOptions()
            }
            Section {
                Toggle("Notify me when each audiobook is finished", isOn: $model.notifyWhenDone)
            }
            Section {
                Picker("Make at once", selection: $model.booksAtOnce) {
                    ForEach(1...AppModel.maxBooksAtOnce, id: \.self) { n in
                        Text(n == 1 ? "One book" : "\(["", "", "Two", "Three", "Four"][n]) books").tag(n)
                    }
                }
            } footer: {
                Text("This Mac: \(AppModel.performanceCores) performance cores, \(AppModel.memoryGB) GB of memory, "
                     + "so up to \(AppModel.maxBooksAtOnce) at once. One book doesn't keep every core busy, so more at "
                     + "once can finish a queue sooner; each book takes a little longer, and the Mac works harder.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct VoiceSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Default for new books") {
                VoicePicker(voice: $model.voice)
                HStack {
                    Text("Speed")
                    Slider(value: $model.speed, in: 0.8...1.3, step: 0.05)
                    Text(String(format: "%.2f×", model.speed)).monospacedDigit().frame(width: 48)
   
                Text("Most audiobook players can also change the speed while you listen, so 1.0× is a safe choice.")
                    .font(.caption).foregroundColor(.secondary)
            }
                HStack {
                    Spacer()
                    Button {
                        model.listen("Hello. This is how your audiobooks will sound.", book: nil)
                    } label: { Label("Listen", systemImage: "speaker.wave.2") }
                }
            }
            Section("Pronunciations") {
                Text("Fixes for words the voice gets wrong. The main list applies to every book; "
                     + "each book can also have its own list.")
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    Button("Edit main list") {
                        if let root = model.engine?.root {
                            NSWorkspace.shared.open(root.appendingPathComponent("pronunciations.txt"))
                        }
                    }
                    Button("Open book lists folder") {
                        if let root = model.engine?.root {
                            let folder = root.appendingPathComponent("pronunciations")
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(folder)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ToolsSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Audiobook tools") {
                LabeledContent("Folder") {
                    Text(model.engine?.root.path ?? "Not found")
                        .lineLimit(1).truncationMode(.head).foregroundColor(.secondary)
                }
                LabeledContent("Status") {
                    if model.engine?.isInstalled == true {
                        Label("Installed", systemImage: "checkmark.circle").foregroundColor(.green)
                    } else if model.engine != nil {
                        Label("Run ./setup.sh in the folder", systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                    } else {
                        Label("Not found", systemImage: "xmark.circle").foregroundColor(.red)
                    }
                }
                HStack {
                    Spacer()
                    Button("Choose folder…") {
                        if let url = chooseFolder("Choose the folder that contains audiobook.py") {
                            model.chooseEngineFolder(url)
                        }
                    }
                    Button("Show in Finder") {
                        if let root = model.engine?.root { NSWorkspace.shared.open(root) }
                    }
                }
            }
            Section {
                Text("The app is a window onto these tools: they read the books and make the audio, "
                     + "entirely on this Mac. Nothing is uploaded.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SupportSettings: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "heart.circle").font(.system(size: 44)).foregroundColor(.pink)
            Text("Audiobook Maker is free").font(.title3)
            Text("It turns books into audiobooks so more people, including readers with dyslexia and anyone "
                 + "learning on the go, can learn by listening. If it's helped you, a donation keeps it going.")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
                .frame(maxWidth: 400)
            Button("Donate…") { openDonatePage() }
                .controlSize(.large)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1") · "
                 + "Voices by Kokoro (hexgrad)")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
