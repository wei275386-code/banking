import Foundation

/// Complete versioned synthetic snapshot inputs, independent of app Seed files.
enum CoreFixtures {
    static var root: URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures/current") }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(name)) }
}
