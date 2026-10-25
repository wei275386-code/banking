import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import CryptoKit
import PaymentImageCore

struct ExtractedRow: Codable {
    let id: String; let requested_second: Double; let actual_second: Double
    let crop: [Int]; let image: String; let image_sha256: String; let text: String
    let date_context: String?; let year_context: String?; let weekday: String?
    let recognition: OCRResult; let completeness: String
    let platform: String; let parsed: CardFields?
}
struct VideoOutput: Codable {
    let source: String; let duration: Double; let sample_interval: Double
    let rows: [ExtractedRow]; let errors: [String]; let recall_status: String
}

func writePNG(_ image: CGImage, _ url: URL) throws -> String {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw NSError(domain: "Video", code: 1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "Video", code: 2) }
    return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

func rowBounds(_ image: CGImage) -> [(Int, Int)] {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    guard let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var bands = [(Int, Int)](); var start: Int?
    let xmin = w * 8 / 100, xmax = w * 92 / 100
    for y in (h * 22 / 100)..<(h - 8) {
        var grey = 0, count = 0
        for x in stride(from: xmin, to: xmax, by: 3) {
            let i = (y * w + x) * 4
            let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
            if max(r, g, b) - min(r, g, b) < 6 && min(r, g, b) > 190 && max(r, g, b) < 247 { grey += 1 }
            count += 1
        }
        if Double(grey) / Double(count) > 0.78 { if start == nil { start = y } }
        else if let s = start { bands.append((s, y - 1)); start = nil }
    }
    let lines = bands.filter { $0.1 - $0.0 <= 3 }.map { ($0.0 + $0.1) / 2 }
    return zip(lines, lines.dropFirst()).filter { $0.1 - $0.0 > h * 5 / 100 && $0.1 - $0.0 < h * 24 / 100 }.map { ($0.0, $0.1) }
}

func orderBounds(_ image: CGImage) -> [(Int, Int)] {
    let w = image.width, h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    guard let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var groups = [(Int, Int)]()
    for y in (h * 16 / 100)..<(h - 4) {
        var grey = 0, count = 0
        for x in stride(from: w * 7 / 100, to: w * 93 / 100, by: 4) {
            let i = (y * w + x) * 4; let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
            if max(r,g,b) - min(r,g,b) < 5 && min(r,g,b) > 232 && max(r,g,b) < 251 { grey += 1 }; count += 1
        }
        if Double(grey) / Double(count) > 0.85 {
            if let last = groups.last, y - last.1 < 45 { groups[groups.count - 1].1 = y }
            else { groups.append((y,y)) }
        }
    }
    return zip(groups, groups.dropFirst()).compactMap { a, b in
        let top = a.1 - 20, bottom = b.0 + 20
        guard top >= h * 16 / 100, bottom < h - 4, bottom - top >= h * 12 / 100, bottom - top <= h * 55 / 100 else { return nil }
        // A sticky navigation boundary can imitate a card separator when a
        // card is leaving the viewport. Require the card's rounded corners at
        // both ends before OCR, using left/right versus centre white edges.
        func edge(_ x: Int, fromTop: Bool) -> Int? {
            for distance in 0..<65 {
                let y = fromTop ? top + distance : bottom - 1 - distance
                let i = (y * w + x) * 4
                if bytes[i] > 251 && bytes[i+1] > 251 && bytes[i+2] > 251 { return distance }
            }
            return nil
        }
        let margin = w * 25 / 1000
        for fromTop in [true, false] {
            guard let middle = edge(w / 2, fromTop: fromTop),
                  let left = edge(margin, fromTop: fromTop),
                  let right = edge(w - w * 34 / 1000 - 1, fromTop: fromTop),
                  left - middle >= 6, right - middle >= 6 else { return nil }
        }
        return (top,bottom)
    }
}

func firstMatch(_ pattern: String, _ text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range, in: text) else { return nil }
    return String(text[range])
}

@main struct VideoRecords {
    /// Exercises linked frameworks and extraction primitives using memory-only fixtures.
    /// Never accepts user material paths or creates an output directory.
    static func selfTest() throws -> [String: Any] {
        guard let canvas = CGContext(data: nil, width: 240, height: 800, bitsPerComponent: 8,
                                     bytesPerRow: 240 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "VideoSelfTest", code: 1)
        }
        canvas.setFillColor(CGColor(gray: 1, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: 240, height: 800))
        guard let blank = canvas.makeImage() else { throw NSError(domain: "VideoSelfTest", code: 2) }
        canvas.setFillColor(CGColor(gray: 220.0 / 255, alpha: 1))
        for y in [300, 400, 500] { canvas.fill(CGRect(x: 0, y: y, width: 240, height: 1)) }
        guard let bands = canvas.makeImage() else { throw NSError(domain: "VideoSelfTest", code: 3) }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "VideoSelfTest", code: 4)
        }
        CGImageDestinationAddImage(destination, bands, nil)
        guard CGImageDestinationFinalize(destination),
              let decoded = CGImageSourceCreateWithData(png as Data as CFData, nil),
              let roundTrip = CGImageSourceCreateImageAtIndex(decoded, 0, nil) else {
            throw NSError(domain: "VideoSelfTest", code: 5)
        }
        let recognition = try LocalTextReader.recognize(blank)
        let card = CardFields.parse([
            TextLine(text: "￥21.98", visionBox: TextBox(x: 0.7, y: 0.5, width: 0.2, height: 0.1)),
            TextLine(text: "已完成", visionBox: TextBox(x: 0.7, y: 0.8, width: 0.2, height: 0.1)),
            TextLine(text: "下单：2026-01-02 12:34", visionBox: TextBox(x: 0.1, y: 0.2, width: 0.7, height: 0.1))
        ])
        let composition = AVMutableComposition()
        let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let checks: [(String, Bool)] = [
            ("coregraphics_imageio", roundTrip.width == 240 && roundTrip.height == 800),
            ("row_bounds", rowBounds(roundTrip).count == 2),
            ("order_bounds_empty", orderBounds(blank).isEmpty),
            ("text_patterns", firstMatch("[0-9]{2}:[0-9]{2}", "synthetic 12:34") == "12:34"),
            ("card_fields", card.amountCents == 2198 && card.status == "已完成" && card.orderedMinute == "2026-01-02 12:34" && card.reviewReasons.isEmpty),
            ("cryptokit", SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("vision", recognition.imageWidth == 240 && recognition.imageHeight == 800 && recognition.configuration.languages.contains("zh-Hans") && recognition.lines.isEmpty),
            ("avfoundation", track != nil && CMTime(seconds: 0.5, preferredTimescale: 600).value == 300)
        ]
        return ["helper": "VideoRecords", "ok": checks.allSatisfy { $0.1 },
                "checks": checks.map { ["name": $0.0, "ok": $0.1] as [String: Any] }]
    }
    static func main() async {
        if CommandLine.arguments == [CommandLine.arguments[0], "--self-test"] {
            do {
                let result = try selfTest()
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                FileHandle.standardOutput.write(data + Data("\n".utf8))
                if result["ok"] as? Bool != true { exit(1) }
            } catch {
                let result: [String: Any] = ["helper": "VideoRecords", "ok": false,
                                             "checks": [], "error": error.localizedDescription]
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                    FileHandle.standardOutput.write(data + Data("\n".utf8))
                }
                exit(1)
            }
            return
        }
        do {
            guard CommandLine.arguments.count == 3 else { throw NSError(domain: "Video", code: 3, userInfo: [NSLocalizedDescriptionKey: "Expected video path and output directory"]) }
            let source = URL(fileURLWithPath: CommandLine.arguments[1]); let output = URL(fileURLWithPath: CommandLine.arguments[2])
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let asset = AVURLAsset(url: source); let duration = try await asset.load(.duration).seconds
            let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            var rows = [ExtractedRow](); var errors = [String](); var seen = Set<String>()
            let first = try await generator.image(at: .zero)
            let firstText = try LocalTextReader.recognize(first.image).lines.map(\.text).joined()
            let orderMode = firstText.contains("搜索我的订单") || firstText.contains("下单：") || firstText.contains("下单:")
            let interval = orderMode ? 0.1 : 0.5
            for second in stride(from: 0.0, to: duration, by: interval) {
                do {
                    let frame = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600))
                    let image = frame.image
                    let context = orderMode ? nil : try LocalTextReader.recognize(image)
                    let year = firstMatch("20[0-9]{2}年", context?.lines.map(\.text).joined(separator: " ") ?? "")
                    let dates = (context?.lines ?? []).filter { firstMatch("[01]?[0-9]\\.[0-3][0-9]", $0.text) != nil && $0.pixelBox.x < Double(image.width) * 0.3 && $0.pixelBox.y > Double(image.height) * 0.2 }
                    for (top, bottom) in (orderMode ? orderBounds(image) : rowBounds(image)) {
                        let left = orderMode ? 0 : image.width * 4 / 100
                        guard let crop = image.cropping(to: CGRect(x: left, y: top, width: image.width - left, height: bottom - top)) else { continue }
                        let recognized = try LocalTextReader.recognize(crop)
                        let text = recognized.lines.map(\.text).joined(separator: "\n")
                        let fields = orderMode ? CardFields.parse(recognized.lines) : nil
                        // A complete transaction includes merchant, amount, funding
                        // account and time. Month summaries and empty panels fail.
                        if orderMode {
                            guard fields?.orderedMinute != nil else { continue }
                        } else {
                            guard firstMatch("[¥￥][0-9,.]+", text) != nil,
                                  firstMatch("[0-9]{2}:[0-9]{2}", text) != nil,
                                  firstMatch("银行|工商|MASTERCARD", text) != nil else { continue }
                        }
                        let dateLine = dates.last { $0.pixelBox.y < Double(bottom) - 25 }
                        let date = dateLine.flatMap { firstMatch("[01]?[0-9]\\.[0-3][0-9]", $0.text) }
                        let weekday = dateLine.flatMap { firstMatch("周[一二三四五六日天]", $0.text) }
                        let identityParts: [String]
                        if orderMode {
                            let minute = fields?.orderedMinute ?? ""
                            let amount = String(fields?.amountCents ?? -1)
                            identityParts = [minute, amount, fields?.status ?? "", recognized.lines.first?.text ?? ""]
                        } else { identityParts = [year ?? "年份未知", date ?? "日期未知", text] }
                        let identity = identityParts.joined(separator: "|")
                        let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
                        if seen.insert(id).inserted {
                            let name = id + ".png"; let hash = try writePNG(crop, output.appendingPathComponent(name))
                            rows.append(ExtractedRow(id: id, requested_second: second, actual_second: frame.actualTime.seconds,
                                crop: [left, top, image.width - left, bottom - top], image: name,
                                image_sha256: hash, text: text, date_context: date, year_context: year, weekday: weekday,
                                recognition: recognized, completeness: orderMode ? "both_card_background_boundaries_visible" : "both_separator_boundaries_visible",
                                platform: orderMode ? "meituan_card" : "unionpay", parsed: fields))
                        }
                    }
                    if Int(second * 2) % 20 == 0 { print("已检查 \(Int(second)) / \(Int(duration)) 秒，完整记录素材 \(rows.count)"); fflush(stdout) }
                } catch { errors.append("\(second): " + error.localizedDescription) }
            }
            let result = VideoOutput(source: source.path, duration: duration, sample_interval: interval,
                                     rows: rows, errors: errors, recall_status: "complete_crops_selected; sampling_recall_not_yet_measured")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: output.appendingPathComponent("video-records.json"), options: .atomic)
            print("完成 \(rows.count) 张完整记录素材")
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
}
