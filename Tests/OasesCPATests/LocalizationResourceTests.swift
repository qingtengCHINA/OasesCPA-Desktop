import Foundation
import XCTest
@testable import OasesCPA

/// The two `Localizable.strings` resources: keys are the Simplified Chinese source strings,
/// English is kept in sync, and every key with a value in it is a format key (`%lld`, `%@`),
/// never a Swift interpolation (`\(…)`), which SwiftUI and `localizedFormat` never look up.
final class LocalizationResourceTests: XCTestCase {
    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    private func stringsURL(_ language: String) throws -> URL {
        try XCTUnwrap(
            Self.resourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language)
                ?? Self.resourceBundle.path(forResource: language, ofType: "lproj")
                    .map { URL(fileURLWithPath: $0).appendingPathComponent("Localizable.strings") },
            "\(language).lproj/Localizable.strings is in the bundle"
        )
    }

    private func dictionary(_ language: String) throws -> [String: String] {
        let url = try stringsURL(language)
        let dictionary = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(language) parses")
        XCTAssertFalse(dictionary.isEmpty)
        return dictionary
    }

    /// The keys as written in the file. The property-list parser drops the backslash of `\(`,
    /// so an interpolation is only visible in the raw text.
    private func rawKeys(_ language: String) throws -> [String] {
        let text = try String(contentsOf: try stringsURL(language), encoding: .utf8)
        var keys: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("\"") {
            var key = ""
            var escaped = false
            for character in line.dropFirst() {
                if escaped { key.append("\\"); key.append(character); escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == "\"" { break }
                key.append(character)
            }
            keys.append(key)
        }
        XCTAssertFalse(keys.isEmpty)
        return keys
    }

    func testNoKeyContainsSwiftInterpolation() throws {
        // A leftover of an extracted interpolation reads like `(aliasCount) 条…` or `") 凭证？"`.
        let residue = try NSRegularExpression(pattern: #"\((?:[a-z$][A-Za-z0-9_$]*)(?:\??\.[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)*\)"#)
        for language in ["zh-Hans", "en"] {
            for key in try rawKeys(language) {
                XCTAssertFalse(key.contains("\\("), "\(language): \(key)")
            }
            for key in try dictionary(language).keys {
                XCTAssertFalse(key.hasPrefix(")") || key.hasPrefix(" :") || key.hasPrefix(" ]"), "\(language): a fragment key \(key)")
                let range = NSRange(key.startIndex..<key.endIndex, in: key)
                XCTAssertNil(residue.firstMatch(in: key, range: range), "\(language): interpolation residue in \(key)")
            }
        }
    }

    func testEnglishAndChineseKeySetsAreEqual() throws {
        let chinese = Set(try dictionary("zh-Hans").keys)
        let english = Set(try dictionary("en").keys)
        XCTAssertEqual(chinese.subtracting(english).sorted(), [], "keys without an English entry")
        XCTAssertEqual(english.subtracting(chinese).sorted(), [], "English keys without a Chinese entry")
        // A key written twice in one file silently keeps the last value.
        for language in ["zh-Hans", "en"] {
            let keys = try rawKeys(language)
            var seen = Set<String>()
            let duplicates = keys.filter { !seen.insert($0).inserted }
            XCTAssertEqual(duplicates, [], "\(language) duplicates")
        }
    }

    /// The kind each argument (by position) is converted with. Comparing these maps, not counts
    /// per kind, catches an English value whose plain specifiers come in another order than the
    /// key's (`%@ … %lld` against `%lld … %@`): the arguments are passed in the key's order, so a
    /// different order needs positional specifiers (`%2$lld … %1$@`).
    static func argumentKinds(_ text: String) -> [Int: OasesFormat.Specifier.Kind] {
        var kinds: [Int: OasesFormat.Specifier.Kind] = [:]
        for specifier in OasesFormat.specifiers(in: text) where kinds[specifier.argument] == nil {
            kinds[specifier.argument] = specifier.kind
        }
        return kinds
    }

    func testArgumentOrderCheckRejectsReorderedPlainSpecifiers() {
        let key = "用户 %@ 调用 %lld 次"
        XCTAssertNotEqual(Self.argumentKinds("%lld calls by %@"), Self.argumentKinds(key), "plain specifiers in another order")
        XCTAssertEqual(Self.argumentKinds("%2$lld calls by %1$@"), Self.argumentKinds(key), "positional specifiers keep the order")
        XCTAssertEqual(Self.argumentKinds("User %@ called %lld times"), Self.argumentKinds(key))
        XCTAssertNotEqual(Self.argumentKinds("User %@"), Self.argumentKinds(key), "a missing argument")
    }

    func testFormatSpecifiersMatchBetweenKeyAndValues() throws {
        let chinese = try dictionary("zh-Hans")
        let english = try dictionary("en")
        func kinds(_ text: String) -> [Int: OasesFormat.Specifier.Kind] { Self.argumentKinds(text) }
        for (key, value) in chinese {
            let expected = kinds(key)
            XCTAssertEqual(kinds(value), expected, "zh-Hans value of \(key)")
            if let translation = english[key] {
                XCTAssertEqual(kinds(translation), expected, "en value of \(key): \(translation)")
                let found = OasesFormat.specifiers(in: translation)
                XCTAssertFalse(found.contains(where: \.isPositional) && found.contains(where: { !$0.isPositional }), "en mixes positional and plain specifiers: \(translation)")
                XCTAssertFalse(found.contains { $0.kind == .unsupported }, "en: unsupported specifier in \(translation)")
            }
        }
    }

    /// Every literal key passed to `OasesLocalization.localized` / `localizedFormat` in the
    /// sources has both translations and is a format key, not an interpolation.
    func testEverySourceLookupKeyIsTranslated() throws {
        let chinese = try dictionary("zh-Hans")
        let english = try dictionary("en")
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OasesCPA")
        let call = try NSRegularExpression(pattern: #"OasesLocalization\.localized(?:Format)?\(\s*"((?:[^"\\]|\\.)*)""#)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in call.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let literal = String(text[range])
                XCTAssertFalse(literal.contains("\\("), "\(file.lastPathComponent): an interpolated lookup key \(literal)")
                let key = literal
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
                XCTAssertNotNil(chinese[key], "\(file.lastPathComponent): zh-Hans lacks \(key)")
                XCTAssertNotNil(english[key], "\(file.lastPathComponent): en lacks \(key)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 300)
    }

    /// A SwiftUI `Text("… \\(value) …")` literal is looked up under a key SwiftUI builds from
    /// the interpolation's types, which these files do not hold, so the Chinese text showed in
    /// English too. Interpolated Chinese literals go through `OasesLocalization.localizedFormat`.
    func testNoSwiftUILiteralInterpolatesChineseText() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OasesCPA")
        let literal = try NSRegularExpression(pattern: #"\b(?:Text|Label|Button|LabeledContent|Toggle|Section)\("((?:[^"\\]|\\.)*)""#)
        let chinese = try NSRegularExpression(pattern: #"\p{Han}"#)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in literal.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let body = String(text[range])
                guard body.contains("\\("),
                      chinese.firstMatch(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body)) != nil else { continue }
                offenders.append("\(file.lastPathComponent): \(body)")
            }
        }
        XCTAssertEqual(offenders, [])
    }

    /// A plain Chinese literal given to a SwiftUI initializer or modifier that takes a
    /// `LocalizedStringKey` (`Text("…")`, `Button("…")`, `.alert("…")`, …) is looked up under
    /// that very text, so both files must hold it; otherwise the English UI shows Chinese.
    func testEveryChineseSwiftUILiteralIsTranslated() throws {
        let chinese = try dictionary("zh-Hans")
        let english = try dictionary("en")
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OasesCPA")
        let literal = try NSRegularExpression(pattern: #"\b(?:Text|Label|Button|LabeledContent|Toggle|Section|TextField|SecureField|Picker|Menu|DisclosureGroup|Stepper|navigationTitle|help|alert|confirmationDialog)\(\s*"((?:[^"\\]|\\.)*)""#)
        let han = try NSRegularExpression(pattern: #"\p{Han}"#)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var missing: [String] = []
        var checked = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in literal.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let body = String(text[range])
                // Interpolated literals are testNoSwiftUILiteralInterpolatesChineseText's.
                guard !body.contains("\\("),
                      han.firstMatch(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body)) != nil else { continue }
                let key = body
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
                checked += 1
                if chinese[key] == nil || english[key] == nil { missing.append("\(file.lastPathComponent): \(key)") }
            }
        }
        XCTAssertGreaterThan(checked, 300)
        XCTAssertEqual(missing, [])
    }

    /// The credential health page's fallbacks and captions are looked up (they reached the
    /// English UI as Chinese text).
    func testInspectionPageHasNoRawChineseFallbacks() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OasesCPA/Views/CredentialHealthInspectionView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let raw = try NSRegularExpression(pattern: #"(?:\?\? |caption: |guard value > 0 else \{ return )"[^"]*\p{Han}"#)
        let matches = raw.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
        XCTAssertEqual(matches, [])
    }

    func testInterpolatedTitleResolvesInEnglish() {
        XCTAssertEqual(OasesLocalization.localizedFormat("已发现 %lld 个可用模型。", language: .english, 3), "3 available models found.")
        XCTAssertEqual(OasesLocalization.localizedFormat("已发现 %lld 个可用模型。", language: .simplifiedChinese, 3), "已发现 3 个可用模型。")
        // Positional arguments in English, plain ones in the key.
        XCTAssertEqual(
            OasesLocalization.localizedFormat("%@，运行 #%lld，%@", language: .english, "Done", Int64(42), "Nov 8"),
            "Done, run #42, Nov 8"
        )
        XCTAssertEqual(OasesLocalization.localizedFormat("额度剩余 %lld%%", language: .english, 40), "40% quota left")
    }

    func testMismatchedArgumentsNeverReachStringFormat() {
        // A String where an integer is expected, a missing argument, an integer for `%@`: the
        // text is still rendered, with the arguments as text.
        XCTAssertEqual(OasesFormat.format("已发现 %lld 个", locale: Locale(identifier: "en"), arguments: ["3"]), "已发现 3 个")
        XCTAssertEqual(OasesFormat.format("%@ / %@", locale: Locale(identifier: "en"), arguments: ["a"]), "a / ")
        XCTAssertEqual(OasesFormat.format("用户 %@ 100%%", locale: Locale(identifier: "en"), arguments: [7]), "用户 7 100%")
        XCTAssertTrue(OasesFormat.argumentsFit("%2$@ %1$lld", [Int64(1), "x"]))
        XCTAssertFalse(OasesFormat.argumentsFit("%@ %1$@", ["x"]), "mixed positional and plain")
        XCTAssertEqual(OasesFormat.format("%2$@ %1$lld", locale: Locale(identifier: "en"), arguments: [Int64(1), "x"]), "x 1")
    }
}
