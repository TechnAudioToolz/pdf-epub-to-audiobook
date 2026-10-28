// Reads the text of a scanned PDF with the Mac's built-in text recognition (the Live Text engine in the
// Vision framework). Offline; nothing to install. audiobook.py calls it for PDFs whose pages are pictures.
//   ocr book.pdf out.json
// Writes {"pages": [{"width", "height", "lines": [{"text", "conf", "x0", "y0", "x1", "y1"}]}]}, in PDF points with
// the origin at the top left, and prints "OCR page n/N" as it goes.
// Build: swiftc -O -target arm64-apple-macos13.0 ocr.swift -o ocr   (app/build.sh does this)
import CoreGraphics
import Foundation
import Vision

let args = CommandLine.arguments
guard args.count == 3, let url = Optional(URL(fileURLWithPath: args[1])),
      let count = CGPDFDocument(url as CFURL)?.numberOfPages else {
    FileHandle.standardError.write("usage: ocr book.pdf out.json\n".data(using: .utf8)!)
    exit(2)
}

var pages = [[String: Any]](repeating: [:], count: count)
let lock = NSLock()
var done = 0

// Pages are independent, so read several at once. Each worker opens its own copy of the PDF.
DispatchQueue.concurrentPerform(iterations: count) { i in
    autoreleasepool {
        guard let page = CGPDFDocument(url as CFURL)?.page(at: i + 1) else { return }
        let box = page.getBoxRect(.mediaBox)
        let rotated = page.rotationAngle % 180 != 0
        let w = rotated ? box.height : box.width, h = rotated ? box.width : box.height
        let scale: CGFloat = 2.5  // about 180 dpi: plenty for book text, and quick
        let pw = Int(w * scale), ph = Int(h * scale)
        var lines: [[String: Any]] = []
        if let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
            ctx.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: pw, height: ph),
                                                     rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            if let image = ctx.makeImage() {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["en-US"]
                try? VNImageRequestHandler(cgImage: image).perform([request])
                for obs in request.results ?? [] {
                    guard let best = obs.topCandidates(1).first else { continue }
                    let b = obs.boundingBox  // 0...1, origin at the bottom left
                    lines.append(["text": best.string, "conf": best.confidence, "x0": b.minX * w, "x1": b.maxX * w,
                                  "y0": (1 - b.maxY) * h, "y1": (1 - b.minY) * h])
                }
            }
        }
        lock.lock()
        pages[i] = ["width": w, "height": h, "lines": lines]
        done += 1
        print("OCR page \(done)/\(count)")
        fflush(stdout)
        lock.unlock()
    }
}

let data = try! JSONSerialization.data(withJSONObject: ["pages": pages])
try! data.write(to: URL(fileURLWithPath: args[2]))
