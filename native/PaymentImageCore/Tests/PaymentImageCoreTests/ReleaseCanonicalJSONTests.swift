import Foundation
import CryptoKit
import XCTest
@testable import PaymentImageCore

final class ReleaseCanonicalJSONTests: XCTestCase {
    func testObjectEntriesPreserveExactKeysAndScalarKindsInOneRead() throws {
        let raw = Data("{\"é\":1.0,\"e\\u0301\":1,\"other\":null}".utf8)
        let entries = try ReleaseCanonicalJSON.canonicalObjectEntries(raw: raw)
        XCTAssertEqual(entries.count, 3)
        XCTAssertNotEqual(Data(entries[0].key.utf8), Data(entries[1].key.utf8))
        XCTAssertEqual(entries.map(\.value), [Data("1.0".utf8), Data("1".utf8), Data("null".utf8)])
        XCTAssertThrowsError(try ReleaseCanonicalJSON.canonicalObjectEntries(raw: Data("{\"a\":1,\"a\":2}".utf8)))
        XCTAssertThrowsError(try ReleaseCanonicalJSON.canonicalObjectEntries(raw: Data("[]".utf8)))
    }
    private struct Golden: Decodable {
        let name: String
        let raw: String
        let canonical_utf8: String
        let canonical_payload_hash: String
    }
    private func canonical(_ raw: String) throws -> String {
        String(decoding: try ReleaseCanonicalJSON.canonicalize(raw: Data(raw.utf8)), as: UTF8.self)
    }
    private func assertResourceLimit(_ raw: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ReleaseCanonicalJSON.canonicalize(raw: raw), file: file, line: line) { error in
            guard case ReleaseCanonicalJSON.ContractError.resourceLimit = error else {
                return XCTFail("Expected explicit resource limit, got \(error)", file: file, line: line)
            }
        }
    }

    /// Python and Swift must preserve the same exact numbers and Unicode keys.
    func testPythonGoldenVectors() throws {
        let file = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/release/canonical-golden-vectors.json")
        let vectors = try JSONDecoder().decode([Golden].self, from: Data(contentsOf: file))
        XCTAssertEqual(vectors.count, 6)
        for vector in vectors {
            let raw = try ReleaseCanonicalJSON.canonicalize(raw: Data(vector.raw.utf8))
            XCTAssertEqual(raw, Data(vector.canonical_utf8.utf8), vector.name)
            XCTAssertEqual(ReviewSyncIO.digest(raw), vector.canonical_payload_hash, vector.name)
        }
    }

    func testDecimalBoundariesExactCoefficientAndSignedZero() throws {
        let raw = "[1e-6,1e-7,1e20,1e21,12.34000e2,-0,-0e999999,0.0000,1000.00,123456789012345678901234567890.12000]"
        let expected = "[0.000001,1.0e-7,100000000000000000000.0,1.0e21,1234.0,0,-0.0,0.0,1000.0,1.2345678901234567890123456789012e29]"
        XCTAssertEqual(try canonical(raw), expected)
        XCTAssertEqual(try canonical("[1e999999999999999999,1e-999999999999999999]"),
                       "[1.0e999999999999999999,1.0e-999999999999999999]")
        let integer = String(repeating: "9", count: ReleaseCanonicalJSON.maximumIntegerDigits)
        XCTAssertEqual(try canonical(integer), integer)
    }

    func testDistinctCanonicallyEquivalentUnicodeKeysAndValuesSurvive() throws {
        let raw = #"{"é":{"note":"keep composed"},"e\u0301":{"note":"keep decomposed"},"𐀀":1,"":2,"strings":["é","e\u0301"]}"#
        let expected = "{\"e\u{0301}\":{\"note\":\"keep decomposed\"},\"strings\":[\"é\",\"e\u{0301}\"],\"é\":{\"note\":\"keep composed\"},\"\u{E000}\":2,\"\u{10000}\":1}"
        XCTAssertEqual(try canonical(raw), expected)
        XCTAssertEqual(Data(try canonical(raw).utf8), Data(expected.utf8))
        let first = try ReleaseCanonicalJSON.canonicalFragment(raw: Data(raw.utf8), atObjectKeys: ["é", "note"])
        let second = try ReleaseCanonicalJSON.canonicalFragment(raw: Data(raw.utf8), atObjectKeys: ["e\u{0301}", "note"])
        XCTAssertEqual(first, Data("\"keep composed\"".utf8))
        XCTAssertEqual(second, Data("\"keep decomposed\"".utf8))
    }

    func testOnlyMandatoryStringEscapesAndSupplementaryScalars() throws {
        let raw = #""\/\"\\\b\f\n\r\t\u0000\u001f\u2028\u2029\ud800\udc00""#
        let expected = "\"/\\\"\\\\\\b\\f\\n\\r\\t\\u0000\\u001f\u{2028}\u{2029}\u{10000}\""
        XCTAssertEqual(try canonical(raw), expected)
    }

    func testFragmentRetainsNumberKindAndUsesObjectOnlyPaths() throws {
        for token in ["1.0", "1e0", "1E+0"] {
            let fragment = try XCTUnwrap(ReleaseCanonicalJSON.canonicalFragment(raw: Data("{\"format_version\":\(token)}".utf8), atObjectKeys: ["format_version"]))
            let text = try XCTUnwrap(String(data: fragment, encoding: .utf8))
            XCTAssertEqual(text, "1.0")
            XCTAssertNil(Int64(text))
        }
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalFragment(raw: Data(#"{"a":1}"#.utf8), atObjectKeys: ["a"]), Data("1".utf8))
        XCTAssertNil(try ReleaseCanonicalJSON.canonicalFragment(raw: Data(#"{"a":[1]}"#.utf8), atObjectKeys: ["a", "0"]))
        XCTAssertNil(try ReleaseCanonicalJSON.canonicalFragment(raw: Data(#"{"a":1}"#.utf8), atObjectKeys: ["missing"]))
    }

    func testMalformedDuplicatesNonFiniteUTF8AndSurrogatesReject() throws {
        for raw in ["", " ", "01", "-01", "+1", "1.", "1e", "1e+", "NaN", "Infinity", "-Infinity",
                    "[1,]", "{\"a\":1,}", "{}{}", "true false", #"{"a":1,"\u0061":2}"#,
                    #""\ud800""#, #""\udc00""#, #""\ud800\u0041""#, #""\x00""#, "\"\n\""] {
            XCTAssertThrowsError(try canonical(raw), raw) { error in
                guard case ReleaseCanonicalJSON.ContractError.invalidJSON = error else {
                    return XCTFail("Expected invalid JSON for \(raw), got \(error)")
                }
            }
        }
        for raw in [Data([34, 0xC0, 0xAF, 34]), Data([34, 0xED, 0xA0, 0x80, 34]),
                    Data([0xFF, 0xFE, 34, 0, 0, 0xD8, 34, 0]), Data([0xFE, 0xFF, 0])] {
            XCTAssertThrowsError(try ReleaseCanonicalJSON.canonicalize(raw: raw))
        }
    }

    func testPythonRawByteEncodingDetection() throws {
        let raw = #"{"z":9007199254740993,"é":"𐀀","a":1.0}"#
        let expected = Data(#"{"a":1.0,"z":9007199254740993,"é":"𐀀"}"#.utf8)
        var inputs = [Data([0xEF, 0xBB, 0xBF]) + Data(raw.utf8)]
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            inputs.append(try XCTUnwrap(raw.data(using: encoding)))
        }
        for input in inputs {
            XCTAssertEqual(try ReleaseCanonicalJSON.canonicalize(raw: input), expected)
        }
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalize(raw: Data([48, 0])), Data("0".utf8))
    }

    func testLedgerOperationsPreserveLosslessUnknownFieldsAndUnicodeKeys() throws {
        let raw = Data(#"{"state_id":"old","results":[{"result_digest":"excluded","phase":"committed","result_generation":null,"unknown":{"é":9007199254740993,"e\u0301":0.123456789012345678901}}],"unknown":-0.0}"#.utf8)
        let replaced = try ReleaseCanonicalJSON.replacingObjectMember(raw: raw, key: "state_id", valueRaw: Data(#""new""#.utf8))
        XCTAssertEqual(replaced, Data("{\"results\":[{\"phase\":\"committed\",\"result_digest\":\"excluded\",\"result_generation\":null,\"unknown\":{\"e\u{0301}\":0.123456789012345678901,\"é\":9007199254740993}}],\"state_id\":\"new\",\"unknown\":-0.0}".utf8))
        let elements = try XCTUnwrap(ReleaseCanonicalJSON.canonicalArrayElements(raw: replaced, atObjectKeys: ["results"]))
        XCTAssertEqual(elements.count, 1)
        let business = try ReleaseCanonicalJSON.removingObjectMembers(raw: elements[0], keys: ["result_digest", "phase", "result_generation"])
        XCTAssertEqual(business, Data("{\"unknown\":{\"e\u{0301}\":0.123456789012345678901,\"é\":9007199254740993}}".utf8))
        let exactRemoval = try ReleaseCanonicalJSON.removingObjectMembers(raw: Data("{\"é\":1,\"e\u{0301}\":2}".utf8), keys: ["é"])
        XCTAssertEqual(exactRemoval, Data("{\"e\u{0301}\":2}".utf8))
        let inserted = try ReleaseCanonicalJSON.replacingObjectMember(raw: Data("{}".utf8), key: "id", valueRaw: Data("9007199254740993".utf8))
        XCTAssertEqual(inserted, Data("{\"id\":9007199254740993}".utf8))
        XCTAssertNil(try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["state_id"]))
        XCTAssertThrowsError(try ReleaseCanonicalJSON.replacingObjectMember(raw: Data("[]".utf8), key: "id", valueRaw: Data("1".utf8)))
        XCTAssertThrowsError(try ReleaseCanonicalJSON.removingObjectMembers(raw: Data("null".utf8), keys: []))
        XCTAssertThrowsError(try ReleaseCanonicalJSON.replacingObjectMember(raw: raw, key: "id", valueRaw: Data("NaN".utf8)))
    }

    func testUntrustedResourceLimitsAreExplicitAndBoundedExponentDoesNotExpand() throws {
        assertResourceLimit(Data(repeating: 32, count: ReleaseCanonicalJSON.maximumInputBytes + 1))
        let nesting = ReleaseCanonicalJSON.maximumDepth + 1
        assertResourceLimit(Data((String(repeating: "[", count: nesting) + "0" + String(repeating: "]", count: nesting)).utf8))
        assertResourceLimit(Data(String(repeating: "9", count: ReleaseCanonicalJSON.maximumIntegerDigits + 1).utf8))
        assertResourceLimit(Data(("0." + String(repeating: "1", count: ReleaseCanonicalJSON.maximumNumberTokenBytes)).utf8))
        assertResourceLimit(Data("1e9999999999999999999".utf8))
        let bytes = try ReleaseCanonicalJSON.canonicalize(raw: Data("[1e999999,1e-999999]".utf8))
        XCTAssertEqual(bytes, Data("[1.0e999999,1.0e-999999]".utf8))
        XCTAssertLessThan(bytes.count, 32)
    }
}
