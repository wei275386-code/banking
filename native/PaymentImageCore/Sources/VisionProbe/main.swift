import Foundation
import ImageIO
import PaymentImageCore

struct Expected: Codable { let amountCents: Int; let status: String; let orderedMinute: String }
struct Job: Codable { let cardID: String; let imagePath: String; let expected: Expected }
struct Manifest: Codable { let jobs: [Job] }
struct JobResult: Codable {
    let cardID: String; let imagePath: String; let expected: Expected
    let recognized: OCRResult?; let parsed: CardFields?; let error: String?
}
struct ProbeResult: Codable { let systemVersion: String; let results: [JobResult] }

do {
    guard CommandLine.arguments.count == 3 else {
        throw NSError(domain: "VisionProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected manifest and output path"])
    }
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    var results = [JobResult]()
    for job in manifest.jobs {
        do {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: job.imagePath) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw NSError(domain: "VisionProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot decode image"])
            }
            let result = try LocalTextReader.recognize(image)
            results.append(JobResult(cardID: job.cardID, imagePath: job.imagePath, expected: job.expected,
                                      recognized: result, parsed: CardFields.parse(result.lines), error: nil))
        } catch {
            results.append(JobResult(cardID: job.cardID, imagePath: job.imagePath, expected: job.expected,
                                      recognized: nil, parsed: nil, error: error.localizedDescription))
        }
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(ProbeResult(systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                   results: results)).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
    print("Processed \(results.count) complete-card samples locally")
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
