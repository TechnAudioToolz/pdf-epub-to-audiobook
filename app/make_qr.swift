// Makes the donation QR codes with Apple's built-in generator (no online service) and reads each one
// back to check it. Writes Resources/qr-venmo.png and Resources/qr-cashapp.png, and embeds them in
// Resources/donate.html (as data: URLs) so the page is one self-contained file.
//   swift make_qr.swift
import AppKit
import CoreImage

let codes = [
    ("qr-venmo.png", "https://venmo.com/u/kevburns"),
    ("qr-cashapp.png", "https://cash.app/$kevburnsmusic"),
]

for (file, link) in codes {
    let filter = CIFilter(name: "CIQRCodeGenerator")!
    filter.setValue(Data(link.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    // 12x scale with no smoothing keeps the modules sharp
    let qr = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    let rep = NSBitmapImageRep(ciImage: qr)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "Resources/\(file)"))

    // read it back
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                              options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
    let found = detector.features(in: CIImage(data: png)!).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    print(found == [link] ? "OK  \(file) -> \(link)" : "MISMATCH \(file): \(found)")
}

// Embed into donate.html: <img id="qr-venmo" src="..."> gets the image itself.
var html = try! String(contentsOfFile: "Resources/donate.html", encoding: .utf8)
for (file, _) in codes {
    let id = file.replacingOccurrences(of: ".png", with: "")
    let b64 = try! Data(contentsOf: URL(fileURLWithPath: "Resources/\(file)")).base64EncodedString()
    let re = try! NSRegularExpression(pattern: "(<img id=\"\(id)\" src=\")[^\"]*(\")")
    html = re.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html),
                                       withTemplate: "$1data:image/png;base64,\(b64)$2")
}
try! html.write(toFile: "Resources/donate.html", atomically: true, encoding: .utf8)
print("Embedded both codes in Resources/donate.html")
