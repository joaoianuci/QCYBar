import XCTest

/// Every UI string must have a pt-BR and an es translation.
final class LocalizationTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func sourceKeys() throws -> Set<String> {
        let app = try String(contentsOf: root.appendingPathComponent("Sources/QCYBar/App.swift"), encoding: .utf8)
        let proto = try String(contentsOf: root.appendingPathComponent("Sources/QCYBar/Protocol.swift"), encoding: .utf8)
        var keys = Set<String>()
        func collect(_ pattern: String, _ text: String) throws {
            let re = try NSRegularExpression(pattern: pattern)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                keys.insert(String(text[Range(m.range(at: 1), in: text)!]))
            }
        }
        try collect(#"L\("((?:[^"\\]|\\.)*)""#, app)
        try collect(#"\((?:0x[0-9A-F]+|\d+), "([^"]+)"\)"#, app)
        try collect(#"(?:name|title|help): "([^"]+)""#, proto)
        try collect(#"return "([^"]+)""#, proto)
        try collect(#"make\(\d+, "([^"]+)""#, proto)
        return keys
    }

    func testEveryStringIsTranslated() throws {
        let keys = try sourceKeys()
        XCTAssertGreaterThan(keys.count, 50)
        for lang in ["pt-BR", "es"] {
            let url = root.appendingPathComponent("Resources/\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
            let missing = keys.subtracting(table.keys).sorted()
            XCTAssertEqual(missing, [], "missing \(lang) translations")
        }
    }
}
