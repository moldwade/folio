import XCTest

/// Folio's translations, in Localization: each has every English the others have, each translation takes the values
/// its English takes, and every English is still Folio's own.
final class LocalizationTests: XCTestCase {
    func testTranslationsMatchTheirEnglish() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Sources/Folio")
        let sources = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        func table(_ language: String) throws -> [String: String] {
            let data = try Data(contentsOf: root.appendingPathComponent("Localization/\(language).lproj/Localizable.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let french = try table("fr"), others = try ["zh-Hans", "tr", "bs"].map(table)
        for other in others { XCTAssertEqual(Set(french.keys), Set(other.keys)) }
        let specifier = #/%(?:(\d+)\$)?(lld|@)/#
        // The values in the order they're taken: by their numbers where a translation numbers them, as one that puts them in
        // another order must, else as they come. A number taken as text, or text as a number, crashes Folio.
        let values = { (text: String) -> [String] in
            let found = text.matches(of: specifier).map { (place: $0.output.1.flatMap { Int($0) }, kind: String($0.output.2)) }
            guard found.contains(where: { $0.place != nil }) else { return found.map(\.kind) }
            return found.sorted { ($0.place ?? 0) < ($1.place ?? 0) }.map(\.kind)
        }
        for (english, translated) in Array(french) + others.flatMap { Array($0) } {
            XCTAssertEqual(values(translated), values(english), translated)
        }
        for english in french.keys {
            for part in english.split(separator: specifier) {
                XCTAssertNotNil(sources.range(of: part), "“\(english)” isn't in Folio's code")
            }
        }
    }
}
