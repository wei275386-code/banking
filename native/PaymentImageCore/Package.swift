// swift-tools-version: 6.1
import PackageDescription
import Foundation

// The production source profile excludes test and diagnostic sources. Keep the
// same manifest usable for both that profile and a full development checkout.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
func hasSources(_ relativePath: String) -> Bool {
    FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent(relativePath).path)
}
let hasVisionProbe = hasSources("Sources/VisionProbe")
var developmentTests: [Target] = []
if hasSources("Tests/PaymentImageCoreTests") {
    developmentTests.append(.testTarget(name: "PaymentImageCoreTests", dependencies: ["PaymentImageCore"], resources: [.copy("Fixtures")]))
}
if hasSources("Tests/FinancialStoreTests") {
    developmentTests.append(.testTarget(name: "FinancialStoreTests", dependencies: ["EvidenceBrowser", "PaymentImageCore"], resources: [.copy("Fixtures")]))
}

let package = Package(
    name: "PaymentImageCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PaymentImageCore", targets: ["PaymentImageCore"]),
        .executable(name: "EvidenceBrowser", targets: ["EvidenceBrowser"]),
        .executable(name: "VideoRecords", targets: ["VideoRecords"]),
        .executable(name: "SyncHost", targets: ["SyncHost"]),
        .executable(name: "FinancialProjection", targets: ["FinancialProjection"]),
    ] + (hasVisionProbe ? [.executable(name: "VisionProbe", targets: ["VisionProbe"])] : []),
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "PaymentImageCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "EvidenceBrowser", dependencies: ["PaymentImageCore"]),
        .executableTarget(name: "VideoRecords", dependencies: ["PaymentImageCore"]),
        .executableTarget(name: "SyncHost", dependencies: ["PaymentImageCore"]),
        .executableTarget(name: "FinancialProjection", dependencies: ["PaymentImageCore"]),
    ] + (hasVisionProbe ? [.executableTarget(name: "VisionProbe", dependencies: ["PaymentImageCore"])] : []) + developmentTests
)
