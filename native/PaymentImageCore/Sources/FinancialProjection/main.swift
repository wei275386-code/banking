import Foundation
import PaymentImageCore

// Deliberately no project discovery, writes, cloud access or processor role.
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 2, arguments[0] == "--review-directory",
          arguments[1].hasPrefix("/") else {
        throw CocoaError(.fileReadInvalidFileName)
    }
    let result = try FinancialEffectiveProjection.read(review: URL(fileURLWithPath: arguments[1], isDirectory: true))
    FileHandle.standardOutput.write(result)
    FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
