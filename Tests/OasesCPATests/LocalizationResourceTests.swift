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
        // Xcode compiles `.strings` into a binary property list, so the raw text only exists in
        // the SwiftPM run of this test (it reads the original file); the Xcode-hosted run checks
        // the parsed keys instead.
        guard let text = try? String(contentsOf: try stringsURL(language), encoding: .utf8) else {
            return Array(try dictionary(language).keys)
        }
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

    // MARK: - Chinese literals outside SwiftUI initializers

    /// The Swift sources with comments and multi-line string literals (the generated bash
    /// scripts) blanked out, offsets kept.
    private func scannedSources() throws -> [(name: String, text: String)] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OasesCPA")
        let multiline = try NSRegularExpression(pattern: ##"#*"""[\s\S]*?"""#*"##)
        let lineComment = try NSRegularExpression(pattern: #"(?m)^\s*//.*$"#)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            var text = try String(contentsOf: file, encoding: .utf8)
            for regex in [multiline, lineComment] {
                let ns = NSMutableString(string: text)
                for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                    let blank = String(ns.substring(with: match.range).map { $0 == "\n" ? "\n" : " " })
                    ns.replaceCharacters(in: match.range, with: blank)
                }
                text = ns as String
            }
            files.append((file.lastPathComponent, text))
        }
        return files
    }

    private static let stringLiteral = try! NSRegularExpression(pattern: #"(?<![#\\])"((?:[^"\\\n]|\\.)*)""#)
    private static let han = try! NSRegularExpression(pattern: #"\p{Han}"#)

    private static func containsHan(_ text: String) -> Bool {
        han.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    private static func key(ofLiteralBody body: String) -> String {
        body.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// I3: every Chinese string literal in the app's Swift code is a key of both tables,
    /// wherever it is written — a ternary handed to `Text`, a chart's `.value(…)` label, an
    /// error's description, a `String` property. (`testEveryChineseSwiftUILiteralIsTranslated`
    /// sees only literals written directly inside a SwiftUI initializer.) Exempt: patterns
    /// searched in script output (`.contains("…")`, `case "…":`); the scripts themselves are
    /// multi-line literals and are skipped.
    func testEveryChineseLiteralIsATranslationKey() throws {
        let chinese = try dictionary("zh-Hans")
        let english = try dictionary("en")
        let search = try NSRegularExpression(pattern: #"(?:\.contains\(|\bcase\s+)$"#)
        var missing: [String] = []
        var checked = 0
        for (name, text) in try scannedSources() {
            let ns = text as NSString
            for match in Self.stringLiteral.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let body = ns.substring(with: match.range(at: 1))
                guard Self.containsHan(body), !body.contains("\\(") else { continue }
                let lineStart = ns.lineRange(for: NSRange(location: match.range.location, length: 0)).location
                let before = ns.substring(with: NSRange(location: lineStart, length: match.range.location - lineStart))
                if search.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil { continue }
                checked += 1
                let key = Self.key(ofLiteralBody: body)
                if chinese[key] == nil || english[key] == nil { missing.append("\(name): \(key)") }
            }
        }
        XCTAssertGreaterThan(checked, 1_000)
        XCTAssertEqual(missing, [])
    }

    /// I3: a `String` property or function that returns Chinese text shown in the UI is shown
    /// verbatim by `Text(String)`, so its literals go through `OasesLocalization` (or a
    /// `LocalizedStringKey`) where they are written; otherwise the English UI shows Chinese
    /// ("已加载" on Auth Files). Exempt: `case "…":` patterns, `AppLanguage` (each language's
    /// own name, chosen explicitly) and the SSH service (its error details are keys looked up
    /// in `SSHConnectionError.message`, tested in `SSHConnectionServiceSecurityTests`).
    func testStringTypedDeclarationsLookUpTheirChineseText() throws {
        let declaration = try NSRegularExpression(
            pattern: #"(?:\bvar\s+\w+\s*:\s*String\??\s*\{|\bfunc\s+\w+[^{]*->\s*String\??\s*\{)"#
        )
        let wrapper = try NSRegularExpression(pattern: #"OasesLocalization\.localized(?:Format)?\(|LocalizedStringKey\("#)
        let casePattern = try NSRegularExpression(pattern: #"\bcase\s+$"#)
        let exempt: Set<String> = ["AppLanguage.swift", "SSHConnectionService.swift"]
        var offenders: [String] = []
        var declarations = 0
        for (name, text) in try scannedSources() where !exempt.contains(name) {
            let characters = Array(text.utf16)
            let ns = text as NSString
            for match in declaration.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                declarations += 1
                var index = match.range.location + match.range.length
                var depth = 1
                while depth > 0, index < characters.count {
                    if characters[index] == 0x7B { depth += 1 } else if characters[index] == 0x7D { depth -= 1 }
                    index += 1
                }
                let bodyRange = NSRange(location: match.range.location + match.range.length, length: index - (match.range.location + match.range.length))
                let body = ns.substring(with: bodyRange) as NSString
                for literal in Self.stringLiteral.matches(in: body as String, range: NSRange(location: 0, length: body.length)) {
                    let content = body.substring(with: literal.range(at: 1))
                    guard Self.containsHan(content) else { continue }
                    let before = body.substring(to: literal.range.location)
                    if casePattern.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil { continue }
                    // Inside a wrapper call that is still open at the literal.
                    let wrapped = wrapper.matches(in: before, range: NSRange(location: 0, length: (before as NSString).length)).contains { call in
                        let tail = (before as NSString).substring(from: call.range.location + call.range.length)
                        return tail.filter { $0 == "(" }.count >= tail.filter { $0 == ")" }.count
                    }
                    if !wrapped { offenders.append("\(name): \(content)") }
                }
            }
        }
        XCTAssertGreaterThan(declarations, 100)
        XCTAssertEqual(offenders, [])
    }

    /// I4: one English label per intent, with the sidebar names as the glossary (连接与部署 =
    /// Connect & Deploy, 认证文件 = Auth Files / auth file, 脱敏 = redacted / masked, 额度 =
    /// quota, 巡检 = health check). The synonyms an earlier machine translation used must not
    /// come back.
    func testEnglishFollowsTheSidebarGlossary() throws {
        let english = try dictionary("en")
        let banned = [
            "certification file", "certified file", "certification document", "authentication file",
            "desensiti", "connection & deployment", "connection and deployment", "connections & deployment",
            "patrol", "account credit", "credit window", "credit cooldown", "certified identity",
            "certification history",
        ]
        var offenders: [String] = []
        for (key, value) in english {
            let lowered = value.lowercased()
            for term in banned where lowered.contains(term) { offenders.append("\(key) → \(value) [\(term)]") }
        }
        XCTAssertEqual(offenders.sorted(), [])
        XCTAssertEqual(english["连接与部署"], "Connect & Deploy")
        XCTAssertEqual(english["认证文件"], "Auth Files")
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
