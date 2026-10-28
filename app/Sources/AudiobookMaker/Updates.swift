import AppKit
import SwiftUI

/// Asks GitHub for the latest release and compares it with this copy of the app. This is the only time the
/// app itself goes online: when you click "Check for updates", or once a week if you turn that on.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(version: String, name: String, notes: String, page: URL)
        case failed(String)
    }

    @Published var status: Status = .idle
    @Published var checkWeekly = UserDefaults.standard.bool(forKey: "checkForUpdatesWeekly") {
        didSet { UserDefaults.standard.set(checkWeekly, forKey: "checkForUpdatesWeekly") }
    }
    var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }

    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private let latestRelease = URL(string: "https://api.github.com/repos/TechnAudioToolz/pdf-epub-to-audiobook/releases/latest")!

    /// "v0.2.0" > "0.1"? Compares number by number; missing numbers count as 0.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let parts = { (v: String) in v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(remote), b = parts(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func check() async {
        status = .checking
        var request = URLRequest(url: latestRelease, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AudiobookMaker/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                status = .failed("GitHub didn't answer as expected. Try again later.")
                return
            }
            lastCheck = Date()
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if Self.isNewer(tag, than: Self.currentVersion) {
                status = .available(version: version, name: json["name"] as? String ?? "Version \(version)",
                                    notes: json["body"] as? String ?? "", page: page)
            } else {
                status = .upToDate(version)
            }
        } catch {
            status = .failed("Couldn't reach GitHub (\(error.localizedDescription)). Are you online?")
        }
    }

    /// At launch: if weekly checks are on and it's been a week, check quietly and mention a new version.
    func checkIfDue(_ model: AppModel) {
        guard checkWeekly, (lastCheck.map { Date().timeIntervalSince($0) > 7 * 24 * 3600 } ?? true) else { return }
        Task {
            await check()
            if case .available(let version, _, _, _) = status {
                model.lastMessage = "Audiobook Maker \(version) is available: Settings → Updates"
            }
        }
    }
}

struct UpdateSettings: View {
    @ObservedObject var updates = UpdateChecker.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("This version", value: UpdateChecker.currentVersion)
                HStack {
                    Button {
                        Task { await updates.check() }
                    } label: { Label("Check for updates", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(updates.status == .checking)
                    if updates.status == .checking { ProgressView().controlSize(.small) }
                    Spacer()
                    if let last = updates.lastCheck {
                        Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                result
            }
            Section {
                Toggle("Check once a week when the app opens", isOn: $updates.checkWeekly)
                Text("Checking asks GitHub for the latest version. It's the only time the app itself goes online; "
                     + "your books and settings are never sent. Off unless you turn it on.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var result: some View {
        switch updates.status {
        case .upToDate(let latest):
            Label("You have the latest version (\(latest)).", systemImage: "checkmark.circle.fill").foregroundColor(.green)
        case .available(let version, let name, let notes, let page):
            VStack(alignment: .leading, spacing: 8) {
                Label("\(name) is available (you have \(UpdateChecker.currentVersion)).", systemImage: "arrow.down.circle.fill")
                    .foregroundColor(.accentColor)
                if !notes.isEmpty {
                    ScrollView {
                        Text((try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                             ?? AttributedString(notes))
                            .font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(maxHeight: 140)
                }
                Button {
                    NSWorkspace.shared.open(page)
                } label: { Label("Download version \(version)", systemImage: "arrow.down.to.line") }
                    .buttonStyle(.borderedProminent)
                Text("Opens the download page. Install it like the first time: open the DMG and drag the app to "
                     + "Applications, replacing this one. Your books, settings and voices stay.")
                    .font(.caption).foregroundColor(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
        default:
            EmptyView()
        }
    }
}
