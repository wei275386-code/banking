import Foundation
import CoreGraphics
import Vision

public struct TextBox: Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct TextCandidate: Codable, Sendable {
    public let text: String
    public let confidence: Float
}

public struct TextCharacter: Codable, Sendable {
    public let text: String
    public let visionBox: TextBox?

    public init(text: String, visionBox: TextBox?) { self.text = text; self.visionBox = visionBox }
}

public struct TextLine: Codable, Sendable {
    public let text: String
    public let candidates: [TextCandidate]
    /// Vision normalized coordinates, with origin at the lower left.
    public let visionBox: TextBox
    /// Native image pixels, with origin at the upper left.
    public let pixelBox: TextBox
    public let characters: [TextCharacter]

    public init(text: String, visionBox: TextBox, characters: [TextCharacter] = []) {
        self.text = text; self.candidates = []; self.visionBox = visionBox
        self.pixelBox = TextBox(x: 0, y: 0, width: 0, height: 0)
        self.characters = characters
    }

    init(observation: VNRecognizedTextObservation, width: Int, height: Int) {
        let alternatives = observation.topCandidates(3)
        text = alternatives.first?.string ?? ""
        candidates = alternatives.map { TextCandidate(text: $0.string, confidence: $0.confidence) }
        let box = observation.boundingBox
        visionBox = TextBox(x: box.minX, y: box.minY, width: box.width, height: box.height)
        pixelBox = TextBox(x: box.minX * Double(width), y: (1 - box.maxY) * Double(height),
                           width: box.width * Double(width), height: box.height * Double(height))
        if let candidate = alternatives.first {
            characters = candidate.string.indices.map { index in
                let end = candidate.string.index(after: index)
                let rect = try? candidate.boundingBox(for: index..<end)?.boundingBox
                return TextCharacter(text: String(candidate.string[index..<end]),
                                     visionBox: rect.map { TextBox(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) })
            }
        } else { characters = [] }
    }
}

public struct OCRConfiguration: Codable, Sendable {
    public let revision: Int
    public let languages: [String]
    public let languageCorrection: Bool
}

public struct OCRResult: Codable, Sendable {
    public let imageWidth: Int
    public let imageHeight: Int
    public let configuration: OCRConfiguration
    public let elapsedSeconds: Double
    public let lines: [TextLine]
}

public enum LocalTextReader {
    /// Run off MainActor when used in an App. VN objects do not cross that boundary.
    public static func recognize(_ image: CGImage, languageCorrection: Bool = false) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        let languages = ["zh-Hans", "en-US"].filter { supported.contains($0) }
        guard languages.contains("zh-Hans") else {
            throw NSError(domain: "PaymentImageCore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "当前 Vision 配置不支持简体中文"])
        }
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = languageCorrection
        let start = ProcessInfo.processInfo.systemUptime
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        return OCRResult(
            imageWidth: image.width, imageHeight: image.height,
            configuration: OCRConfiguration(revision: request.revision, languages: languages,
                                             languageCorrection: languageCorrection),
            elapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
            lines: (request.results ?? []).map { TextLine(observation: $0, width: image.width, height: image.height) }
        )
    }
}
