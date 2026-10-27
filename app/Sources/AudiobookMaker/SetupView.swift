import SwiftUI

/// First launch: installs the tools and voice model into Application Support.
struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var installer = Installer()

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text("Set up Audiobook Maker").font(.title)

            if installer.running {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(max(installer.step - 1, 0)), total: Double(installer.steps))
                    Text("Step \(installer.step) of \(installer.steps): \(installer.stepName)")
                    Text(installer.log.last ?? "Starting…")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .frame(width: 440)
                Text("This usually takes 5–15 minutes, depending on your internet connection.")
                    .font(.caption).foregroundColor(.secondary)
                Button("Cancel") { installer.cancel() }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Downloads the voice engine once: about 1.5 GB", systemImage: "arrow.down.circle")
                    Label("After that everything runs on this Mac, offline", systemImage: "lock.shield")
                    Label("Your books are never uploaded anywhere", systemImage: "book.closed")
                }
                .frame(width: 440, alignment: .leading)

                if let failure = installer.failure {
                    Text(failure).foregroundColor(.red).multilineTextAlignment(.center).frame(width: 440)
                }
                Button(installer.failure == nil ? "Install" : "Try again") { install() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                Button("I already have the tools folder…") {
                    if let url = chooseFolder("Choose the folder that contains audiobook.py") {
                        model.chooseEngineFolder(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if UserDefaults.standard.bool(forKey: "autoInstall") { install() }  // testing only
        }
    }

    private func install() {
        installer.install(into: Engine.supportHome) {
            model.reloadEngine()
        }
    }
}
