import XCTest
import Foundation
import CSQLite
@testable import PaymentImageCore

final class NativeWorkspaceEffectsTests: XCTestCase {
    func testSQLiteEntitiesMatchPythonGoldenForIntegerRealBlobNULTextAndGeneratedColumns() throws {
        let canonical = try TestPlatform.temporaryDirectory().path
        let root = URL(fileURLWithPath: canonical + "/native-effects-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("samples.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        let sql = "CREATE TABLE sample(id TEXT PRIMARY KEY,integer_value INTEGER,real_value REAL,blob_value BLOB); INSERT INTO sample VALUES('one',1,1.0,X'00ff'); INSERT INTO sample VALUES('negative-zero',-1,-0.0,X''); INSERT INTO sample VALUES('fractional',9007199254740993,1.25,X'616263'); CREATE TABLE text_sample(id TEXT PRIMARY KEY,value TEXT); INSERT INTO text_sample VALUES(CAST(X'6e756c006b6579' AS TEXT),'before'||char(0)||'after🧾'); INSERT INTO text_sample VALUES('empty',''); CREATE TABLE generated_sample(id TEXT PRIMARY KEY,value TEXT,derived TEXT GENERATED ALWAYS AS (value || ' generated') STORED); INSERT INTO generated_sample(id,value) VALUES('generated','before'||char(0)||'after🧾');"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let expectedFile = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/release/native-sqlite-entities.json")
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: expectedFile))
        XCTAssertEqual(try NativeWorkspaceEffects.database(file, relative: "samples.sqlite3"), expected)
    }
    func testDuplicateNullablePrimaryKeyIsRejected() throws {
        try assertRejected(sql: "CREATE TABLE sample(id TEXT PRIMARY KEY,value TEXT); INSERT INTO sample VALUES(NULL,'first'); INSERT INTO sample VALUES(NULL,'second');", expected: "duplicate SQLite primary-key identity")
    }
    func testSealedWALHeaderReaderLeavesOriginalDirectoryUnchanged() throws {
        let canonical = try TestPlatform.temporaryDirectory().path
        let root = URL(fileURLWithPath: canonical + "/sealed-effects-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("samples.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE sample(id INTEGER PRIMARY KEY,value TEXT); INSERT INTO sample VALUES(1,'retained');", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        // A sealed, checkpointed database can retain WAL header flags while
        // having no live WAL. Do not rely on test-runner checkpoint-on-close.
        var original = try Data(contentsOf: file)
        original[18] = 2; original[19] = 2
        try original.write(to: file)
        XCTAssertEqual(Array(original[18..<20]), [2, 2])
        XCTAssertFalse(try NativeWorkspaceEffects.database(file, relative: "samples.sqlite3").isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["samples.sqlite3"])
        let sidecar = URL(fileURLWithPath: file.path + "-wal")
        try Data([1]).write(to: sidecar)
        XCTAssertThrowsError(try NativeWorkspaceEffects.database(file, relative: "samples.sqlite3"))
        XCTAssertEqual(try Data(contentsOf: sidecar), Data([1]))
    }
    func testInvalidUTF8TextIsRejectedWithoutReplacement() throws {
        try assertRejected(sql: "CREATE TABLE sample(id TEXT PRIMARY KEY,value TEXT); INSERT INTO sample VALUES('invalid',CAST(X'80' AS TEXT));", expected: "SQLite TEXT is not valid UTF-8")
    }
    func testOversizedCellsAreRejectedBeforeSwiftValueAllocation() throws {
        try assertRejected(sql: "CREATE TABLE sample(id INTEGER PRIMARY KEY,value BLOB); INSERT INTO sample VALUES(1,zeroblob(1048577));", expected: "SQLite BLOB byte budget")
        try assertRejected(sql: "CREATE TABLE sample(id INTEGER PRIMARY KEY,value TEXT); INSERT INTO sample VALUES(1,replace(hex(zeroblob(1572864)),'0','x'));", expected: "SQLite effect row byte budget")
    }
    private func assertRejected(sql: String, expected: String) throws {
        let canonical = try TestPlatform.temporaryDirectory().path
        let root = URL(fileURLWithPath: canonical + "/native-effects-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("samples.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try NativeWorkspaceEffects.database(file, relative: "samples.sqlite3")) { error in
            guard case WorkspaceError.invalid(let detail) = error else { return XCTFail("Expected explicit invalid effect error: \(error)") }
            XCTAssertEqual(detail, expected)
        }
    }

}
