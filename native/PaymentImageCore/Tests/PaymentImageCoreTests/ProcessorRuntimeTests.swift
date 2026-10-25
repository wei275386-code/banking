#if os(macOS)
import XCTest
import CryptoKit
@testable import PaymentImageCore

final class ProcessorRuntimeTests: XCTestCase, @unchecked Sendable {
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func fixture(parentDirectory: URL = FileManager.default.temporaryDirectory) throws -> (URL, Bundle, [String: Any]) {
        let parent = URL(fileURLWithPath: parentDirectory.path + "/bundled-runtime-" + UUID().uuidString)
        let root = parent.appendingPathComponent("Synthetic.app")
        let files: [String: String] = [
            "Contents/Resources/ProcessorRuntime/bin/python3.13": try TestPlatform.shellScript("exec " + TestPlatform.shellQuoted(TestPlatform.python().path) + " \"$@\"\n"),
            "Contents/Helpers/VideoRecords": try TestPlatform.shellScript("printf '{\"ok\":true}\\n'\n"),
            "Contents/Helpers/FinancialProjection": try TestPlatform.shellScript("printf '{\"financial\":true}\\n'\n"),
            "Contents/Resources/defaults/default-config.json": "{}",
            "Contents/Resources/processor/scripts/processor_bootstrap.py": "import argparse,runpy,sys,os\nfrom pathlib import Path\np=argparse.ArgumentParser();p.add_argument('--bundle-root');p.add_argument('--entry');a,rest=p.parse_known_args();sys.argv=[a.entry]+rest[1:];os.environ['BANKING_VIDEO_HELPER']=str(Path(a.bundle_root)/'Contents/Helpers/VideoRecords');runpy.run_path(str(Path(a.bundle_root)/'Contents/Resources/processor/scripts'/a.entry),run_name='__main__')\n",
            "Contents/Resources/processor/scripts/runtime_doctor.py": "pass\n",
            "Contents/Resources/processor/scripts/app_review.py": "pass\n",
            "Contents/Resources/processor/scripts/import_review_materials.py": """
            import argparse,json,sys,os
            from pathlib import Path
            p=argparse.ArgumentParser()
            for name in ['root','output','files-json','operation-id','result-file']:p.add_argument('--'+name)
            a=p.parse_args()
            Path(a.output,'runtime-observation.json').write_text(json.dumps({'isolated':sys.flags.isolated,'no_site':sys.flags.no_site,'bytecode':sys.dont_write_bytecode,'root':a.root,'cwd':os.getcwd(),'helper':os.environ.get('BANKING_VIDEO_HELPER'),'pythonpath':os.environ.get('PYTHONPATH'),'merchant_db':os.environ.get('BANKING_MERCHANT_DB')}))
            Path(a.result_file).write_text(json.dumps({'version':1,'operation_id':a.operation_id,'phase':'legacy_applied','outcome':'success','message':'synthetic','inputs':[{'input_id':s,'outcome':'success'} for s in json.loads(Path(a.files_json).read_text())]}))
            """,
            "Contents/Resources/ProcessorRuntime/lib/native-fixture.so": "synthetic dependency"
        ]
        var entries = [[String: Any]]()
        for (path, source) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(source.utf8); try data.write(to: url)
            if path.hasSuffix("python3.13") || path.hasSuffix("VideoRecords") || path.hasSuffix("FinancialProjection") {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            entries.append(["path": path, "kind": "file", "size": data.count, "sha256": digest(data)])
        }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.processor.runtime", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        let manifest: [String: Any] = [
            "runtime_version": "synthetic-1", "architecture": "arm64", "minimum_macos": "14.0",
            "lock_sha256": String(repeating: "0", count: 64),
            "python": ["path": "Contents/Resources/ProcessorRuntime/bin/python3.13", "version": "3.13.7"],
            "scripts": ["path": "Contents/Resources/processor/scripts"],
            "bootstrap": ["path": "Contents/Resources/processor/scripts/processor_bootstrap.py"],
            "doctor": ["path": "Contents/Resources/processor/scripts/runtime_doctor.py"],
            "helper": ["path": "Contents/Helpers/VideoRecords", "self_test_arguments": ["--self-test"]],
            "defaults": ["path": "Contents/Resources/defaults"],
            "entry_scripts": ["app_review.py", "import_review_materials.py", "runtime_doctor.py"], "files": entries
        ]
        try write(manifest, root: root)
        return (parent, try XCTUnwrap(Bundle(url: root)), manifest)
    }
    private func write(_ manifest: [String: Any], root: URL) throws {
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("Contents/Resources/runtime-manifest.json"))
    }
    func testRelocatedAppPreservesPhysicalPathForStrictWorkspaceReads() throws {
        let physicalTemporary = try TestPlatform.temporaryDirectory()
        let (parent, bundle, _) = try fixture(parentDirectory: physicalTemporary)
        defer { try? FileManager.default.removeItem(at: parent) }
        let runtime = try ProcessorRuntime.resolve(bundle: bundle, environment: [:])
        let root = try XCTUnwrap(runtime.bundleRoot)
        XCTAssertTrue(root.path.hasPrefix(physicalTemporary.path + "/"), root.path)
        XCTAssertNoThrow(try WorkspaceIO.read(URL(fileURLWithPath: root.path + "/Contents/Resources/runtime-manifest.json")))
        XCTAssertTrue(runtime.scripts.path.hasPrefix(root.path + "/"))
        XCTAssertTrue(runtime.python.path.hasPrefix(root.path + "/"))
        let alias = parent.appendingPathComponent("bundle-alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertEqual(ProcessorRuntime.canonicalAppRoot(alias), root)
        // The runtime fix does not permit aliases in financial data paths.
        XCTAssertThrowsError(try WorkspacePaths(workspace: alias))
    }
    func testStandaloneHostExecutableFindsContainingApp() throws {
        let (parent, bundle, _) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let host = bundle.bundleURL.appendingPathComponent("Contents/Helpers/SyncHost")
        try Data(TestPlatform.shellScript("exit 0\n").utf8).write(to: host)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)
        XCTAssertEqual(try ProcessorRuntime.containingApp(executable: host), ProcessorRuntime.canonicalAppRoot(bundle.bundleURL))
        // SyncHost is authenticated by package provenance rather than runtime files.
        XCTAssertNoThrow(try ProcessorRuntime.resolve(bundle: bundle, environment: [:]))
    }
    func testFlatHelperUsesOuterManifestAndNeverDevelopmentOverrides() throws {
        let (parent, bundle, _) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let executable = bundle.bundleURL.appendingPathComponent("Contents/Helpers/SyncHost")
        try Data(TestPlatform.shellScript("exit 0\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let enclosing = try XCTUnwrap(ProcessorRuntime.containingApp(executable: executable))
        let helper = try XCTUnwrap(Bundle(url: enclosing))
        let invalid = parent.appendingPathComponent("invalid").path
        let runtime = try ProcessorRuntime.resolve(project: URL(fileURLWithPath: invalid), bundle: helper,
            environment: ["BANKING_PROCESSOR_CONFIG": invalid, "BANKING_PROCESSOR_PROJECT": invalid, "BANKING_PROCESSOR_PYTHON": invalid, "PATH": invalid])
        XCTAssertEqual(runtime.bundleRoot, ProcessorRuntime.canonicalAppRoot(bundle.bundleURL))
        XCTAssertEqual(runtime.mode, .bundled)
        let manifest = bundle.bundleURL.appendingPathComponent("Contents/Resources/runtime-manifest.json")
        try FileManager.default.removeItem(at: manifest)
        XCTAssertThrowsError(try ProcessorRuntime.resolve(project: parent, bundle: helper, environment: ["PATH": parent.path])) {
            XCTAssertEqual(($0 as? ProcessorRuntimeError)?.code, .manifestMissing)
        }
        try Data("{broken".utf8).write(to: manifest)
        XCTAssertThrowsError(try ProcessorRuntime.resolve(project: parent, bundle: helper, environment: ["PATH": parent.path])) {
            XCTAssertEqual(($0 as? ProcessorRuntimeError)?.code, .manifestInvalid)
        }
    }
    func testContainingAppRejectsMissingNonExecutableAndEscapingHelper() throws {
        let (parent, bundle, _) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let host = bundle.bundleURL.appendingPathComponent("Contents/Helpers/SyncHost")
        XCTAssertThrowsError(try ProcessorRuntime.containingApp(executable: host))
        try Data("synthetic host".utf8).write(to: host)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: host.path)
        XCTAssertThrowsError(try ProcessorRuntime.containingApp(executable: host))
        try FileManager.default.removeItem(at: host)
        try FileManager.default.createSymbolicLink(atPath: host.path, withDestinationPath: SystemToolLocations.executable("sh").path)
        XCTAssertThrowsError(try ProcessorRuntime.containingApp(executable: host))
        XCTAssertNil(try ProcessorRuntime.containingApp(executable: nil))
        XCTAssertNil(try ProcessorRuntime.containingApp(executable: SystemToolLocations.executable("sh")))
    }
    func testBundleManifestHasPriorityOverAllDevelopmentOverrides() throws {
        let (parent, bundle, _) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let invalid = parent.appendingPathComponent("invalid").path
        let runtime = try ProcessorRuntime.resolve(project: URL(fileURLWithPath: invalid), bundle: bundle,
            environment: ["PATH": invalid, "BANKING_PROCESSOR_CONFIG": invalid, "BANKING_PROCESSOR_PROJECT": invalid, "BANKING_PROCESSOR_PYTHON": invalid])
        XCTAssertEqual(runtime.mode, .bundled)
        XCTAssertEqual(runtime.bundleRoot, ProcessorRuntime.canonicalAppRoot(bundle.bundleURL))
        XCTAssertEqual(runtime.scripts, ProcessorRuntime.canonicalAppRoot(bundle.bundleURL).appendingPathComponent("Contents/Resources/processor/scripts"))
        XCTAssertEqual(runtime.helper, ProcessorRuntime.canonicalAppRoot(bundle.bundleURL).appendingPathComponent("Contents/Helpers/VideoRecords"))
        XCTAssertEqual(runtime.defaults, ProcessorRuntime.canonicalAppRoot(bundle.bundleURL).appendingPathComponent("Contents/Resources/defaults"))
    }
    func testMissingAndMalformedManifestNeverFallBackToLegacyConfig() throws {
        let (parent, bundle, _) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let manifest = bundle.bundleURL.appendingPathComponent("Contents/Resources/runtime-manifest.json")
        try Data("{}".utf8).write(to: bundle.bundleURL.appendingPathComponent("Contents/Resources/processor-location.json"))
        try FileManager.default.removeItem(at: manifest)
        XCTAssertThrowsError(try ProcessorRuntime.resolve(project: parent, bundle: bundle, environment: ["PATH": parent.path])) {
            XCTAssertEqual(($0 as? ProcessorRuntimeError)?.code, .manifestMissing)
        }
        try Data("{broken".utf8).write(to: manifest)
        XCTAssertThrowsError(try ProcessorRuntime.resolve(project: parent, bundle: bundle, environment: ["PATH": parent.path])) {
            XCTAssertEqual(($0 as? ProcessorRuntimeError)?.code, .manifestInvalid)
        }
    }
    func testInterpreterHelperAndNativeDependencyTamperingFailsClosed() throws {
        for path in ["Contents/Resources/ProcessorRuntime/bin/python3.13", "Contents/Helpers/VideoRecords", "Contents/Resources/ProcessorRuntime/lib/native-fixture.so"] {
            let (parent, bundle, _) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
            let runtime = try ProcessorRuntime.resolve(bundle: bundle, environment: [:])
            try Data("changed".utf8).write(to: bundle.bundleURL.appendingPathComponent(path))
            XCTAssertThrowsError(try runtime.validateIntegrity())
            XCTAssertThrowsError(try ProcessorRuntime.resolve(project: parent, bundle: bundle, environment: ["PATH": parent.path]))
        }
    }
    func testInvalidPathsDuplicateEntriesAndOmittedDependenciesFailClosed() throws {
        let (parent, bundle, original) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        for path in [try TestPlatform.python().path, "Contents/../outside", "Contents//python", "Contents/./python"] {
            var manifest = original; manifest["python"] = ["path": path, "version": "3.13.7"]
            try write(manifest, root: bundle.bundleURL)
            XCTAssertThrowsError(try ProcessorRuntime.resolve(bundle: bundle, environment: [:]))
        }
        var manifest = original; var files = try XCTUnwrap(original["files"] as? [[String: Any]])
        files.append(files[0]); manifest["files"] = files
        try write(manifest, root: bundle.bundleURL)
        XCTAssertThrowsError(try ProcessorRuntime.resolve(bundle: bundle, environment: [:]))
        manifest = original
        manifest["files"] = files.filter { $0["path"] as? String != "Contents/Helpers/VideoRecords" }
        try write(manifest, root: bundle.bundleURL)
        XCTAssertThrowsError(try ProcessorRuntime.resolve(bundle: bundle, environment: [:]))
    }
    func testSymlinkCannotEscapeBundleEvenWhenTargetIsHashed() throws {
        let (parent, bundle, original) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let link = bundle.bundleURL.appendingPathComponent("Contents/Helpers/VideoRecords")
        try FileManager.default.removeItem(at: link)
        let target = try SystemToolLocations.executable("sh").path
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        var manifest = original
        var files = try XCTUnwrap(original["files"] as? [[String: Any]])
        let index = try XCTUnwrap(files.firstIndex { $0["path"] as? String == "Contents/Helpers/VideoRecords" })
        files[index] = ["path": "Contents/Helpers/VideoRecords", "kind": "symlink", "size": target.utf8.count, "sha256": digest(Data(target.utf8)), "target": target]
        manifest["files"] = files; try write(manifest, root: bundle.bundleURL)
        XCTAssertThrowsError(try ProcessorRuntime.resolve(bundle: bundle, environment: [:]))
    }
    func testManifestedInternalInterpreterSymlinkIsSupported() throws {
        let (parent, bundle, original) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let relative = "Contents/Resources/ProcessorRuntime/bin/python3"
        let target = "python3.13"
        try FileManager.default.createSymbolicLink(atPath: bundle.bundleURL.appendingPathComponent(relative).path, withDestinationPath: target)
        var manifest = original
        var files = try XCTUnwrap(original["files"] as? [[String: Any]])
        files.append(["path": relative, "kind": "symlink", "size": target.utf8.count, "sha256": digest(Data(target.utf8)), "target": target])
        manifest["files"] = files; manifest["python"] = ["path": relative, "version": "3.13.7"]
        try write(manifest, root: bundle.bundleURL)
        let runtime = try ProcessorRuntime.resolve(bundle: bundle, environment: [:])
        XCTAssertEqual(runtime.python, ProcessorRuntime.canonicalAppRoot(bundle.bundleURL).appendingPathComponent(relative))
        try runtime.validateIntegrity()
    }
    func testUntrackedImportableFileAndOmittedNativeDependencyFailClosed() throws {
        let (parent, bundle, original) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let injection = bundle.bundleURL.appendingPathComponent("Contents/Resources/processor/scripts/injected.py")
        try Data("raise RuntimeError('untracked')".utf8).write(to: injection)
        XCTAssertThrowsError(try ProcessorRuntime.resolve(bundle: bundle, environment: [:]))
        try FileManager.default.removeItem(at: injection)
        var manifest = original
        let files = try XCTUnwrap(original["files"] as? [[String: Any]])
        manifest["files"] = files.filter { $0["path"] as? String != "Contents/Resources/ProcessorRuntime/lib/native-fixture.so" }
        try write(manifest, root: bundle.bundleURL)
        XCTAssertThrowsError(try ProcessorRuntime.resolve(bundle: bundle, environment: [:]))
    }
    func testNoImplicitDevelopmentCurrentDirectoryOrEnvironmentProject() throws {
        XCTAssertThrowsError(try ProcessorRuntime.resolve(environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "", "BANKING_PROCESSOR_PROJECT": FileManager.default.currentDirectoryPath]))
    }
}
#endif
