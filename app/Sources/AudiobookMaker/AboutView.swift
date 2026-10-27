import SwiftUI

let projectURL = URL(string: "https://github.com/TechnAudioToolz/pdf-epub-to-audiobook")!

struct Credit: Identifiable {
    let name: String
    let role: String
    let license: String
    let url: String
    var id: String { name }
}

/// Every open-source project the app relies on. Keep in sync with the README's Acknowledgements.
let credits: [Credit] = [
    Credit(name: "Kokoro-82M, kokoro and misaki (hexgrad)", role: "The voices and speech synthesis",
           license: "Apache 2.0", url: "https://huggingface.co/hexgrad/Kokoro-82M"),
    Credit(name: "PyTorch", role: "Runs the voice model", license: "BSD-style", url: "https://pytorch.org"),
    Credit(name: "Hugging Face Hub", role: "Downloads the voice model", license: "Apache 2.0",
           url: "https://github.com/huggingface/huggingface_hub"),
    Credit(name: "PyMuPDF (Artifex)", role: "Reads PDFs", license: "AGPL-3.0", url: "https://github.com/pymupdf/PyMuPDF"),
    Credit(name: "EbookLib", role: "Reads EPUBs", license: "AGPL-3.0", url: "https://github.com/aerkalov/ebooklib"),
    Credit(name: "Beautiful Soup", role: "Reads the HTML inside EPUBs", license: "MIT",
           url: "https://www.crummy.com/software/BeautifulSoup/"),
    Credit(name: "spaCy (Explosion)", role: "Sentence and word analysis for pronunciation", license: "MIT",
           url: "https://spacy.io"),
    Credit(name: "eSpeak NG", role: "Pronounces unusual words", license: "GPL-3.0",
           url: "https://github.com/espeak-ng/espeak-ng"),
    Credit(name: "phonemizer", role: "Connects eSpeak NG to the voice", license: "GPL-3.0",
           url: "https://github.com/bootphon/phonemizer"),
    Credit(name: "espeakng-loader", role: "Packages eSpeak NG for Python", license: "See project",
           url: "https://github.com/thewh1teagle/espeakng-loader"),
    Credit(name: "FFmpeg", role: "Audio encoding, chapters and cover art", license: "LGPL/GPL", url: "https://ffmpeg.org"),
    Credit(name: "imageio-ffmpeg", role: "A self-contained FFmpeg", license: "BSD-2-Clause",
           url: "https://github.com/imageio/imageio-ffmpeg"),
    Credit(name: "faster-whisper (SYSTRAN) and Whisper (OpenAI)", role: "Hears chapter titles in existing audiobooks",
           license: "MIT", url: "https://github.com/SYSTRAN/faster-whisper"),
    Credit(name: "NumPy and soundfile", role: "Audio data handling", license: "BSD", url: "https://numpy.org"),
    Credit(name: "uv (Astral)", role: "Installs Python and the libraries on first launch", license: "MIT or Apache 2.0",
           url: "https://github.com/astral-sh/uv"),
    Credit(name: "Python", role: "Runs the tools", license: "PSF License", url: "https://www.python.org"),
]

/// The About window (app menu → About Audiobook Maker) and the About tab in Settings.
struct AboutView: View {
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader {
                HStack(spacing: 14) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 48)).foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audiobook Maker").font(.title2)
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")")
                            .foregroundColor(.secondary)
                    }
                }
            }
            Text("Turns PDFs, EPUBs and text files into audiobooks, entirely on your Mac, so more people, "
                 + "including readers with dyslexia and anyone learning on the go, can learn by listening.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Link(destination: projectURL) { Label("Project on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                Spacer()
                Button { openDonatePage() } label: { Label("Donate", systemImage: "heart") }
            }

            Text("Built on the work of others").font(.headline).padding(.top, 4)
            Text("This app mostly connects other people's excellent open-source projects. The real credit belongs to them.")
                .font(.caption).foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(credits) { c in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Link(c.name, destination: URL(string: c.url)!)
                                Spacer()
                                Text(c.license).font(.caption).foregroundColor(.secondary)
                            }
                            Text(c.role).font(.caption).foregroundColor(.secondary)
                        }
                        Divider()
                    }
                    Text("Written with the help of Claude (Anthropic).").font(.caption).foregroundColor(.secondary)
                }
                .padding(.trailing, 8)
            }
        }
        .padding(20)
    }
}
