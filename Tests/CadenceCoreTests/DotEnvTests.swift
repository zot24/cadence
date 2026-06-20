import XCTest
@testable import CadenceCore

final class DotEnvTests: XCTestCase {
    private func tmpFile(_ contents: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cadence-env-\(UUID().uuidString).env")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testReadParsesKeysQuotesExportsComments() throws {
        let url = try tmpFile("""
        # a comment
        ANTHROPIC_API_KEY=sk-abc
        export DEBUG="1"
        QUOTED='hello world'
        notakey
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let env = DotEnv.read(url)
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-abc")
        XCTAssertEqual(env["DEBUG"], "1")
        XCTAssertEqual(env["QUOTED"], "hello world")
        XCTAssertNil(env["notakey"])
    }

    func testWritePreservesCommentsUpdatesAddsRemoves() throws {
        let url = try tmpFile("""
        # keep me
        ANTHROPIC_API_KEY=old
        REMOVE_ME=x
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        try DotEnv.write(["ANTHROPIC_API_KEY": "new", "ADDED": "yes"], to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# keep me"))            // comment preserved
        XCTAssertTrue(text.contains("ANTHROPIC_API_KEY=new")) // updated in place
        XCTAssertFalse(text.contains("REMOVE_ME"))           // dropped
        XCTAssertTrue(text.contains("ADDED=yes"))            // appended

        // Round-trips back to the same dict.
        let env = DotEnv.read(url)
        XCTAssertEqual(env, ["ANTHROPIC_API_KEY": "new", "ADDED": "yes"])
    }

    func testWriteQuotesValuesWithSpaces() throws {
        let url = try tmpFile("")
        defer { try? FileManager.default.removeItem(at: url) }
        try DotEnv.write(["PHRASE": "two words"], to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("PHRASE=\"two words\""))
        XCTAssertEqual(DotEnv.read(url)["PHRASE"], "two words")
    }
}
