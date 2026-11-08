import Foundation

/// Why `CPAConfigYAMLPatcher` refused a file: it only reads and writes block-style YAML whose
/// keys are unique, and never guesses at another shape.
enum CPAConfigYAMLPatchError: LocalizedError, Equatable {
    /// The key at this path appears more than once, or its parent is not a block mapping.
    case ambiguous([String])
    /// The value at this path is written in flow style (`{…}`, `[…]`) or as a block scalar.
    case flowStyle([String])

    var errorDescription: String? {
        switch self {
        case .ambiguous(let path):
            OasesLocalization.localizedFormat("配置文件里 %@ 的写法无法自动修改（重复的键或不是普通的键值结构），请在配置文件编辑器中手动修改。", path.joined(separator: "."))
        case .flowStyle(let path):
            OasesLocalization.localizedFormat("配置文件里 %@ 使用了单行（流式）写法，无法自动修改，请在配置文件编辑器中手动修改。", path.joined(separator: "."))
        }
    }
}

/// One scalar of the engine's `config.yaml`, read or written by lines without a YAML library.
///
/// Only block style is understood: `key: value` lines, nested by indentation. A key path is
/// matched from the top level (`["response-compression", "enabled"]` is `enabled` directly
/// under the top-level `response-compression`), so the same key nested elsewhere (a provider's
/// own `disable-cooling`) is never taken for it. Writing changes exactly one line (the value,
/// keeping the comment after it) or appends the missing lines; every other byte of the file
/// stays as it was. Duplicate keys, flow style, block scalars, anchors, several documents and
/// parents that are not block mappings are refused.
enum CPAConfigYAMLPatcher {
    /// The plain text of the scalar at `path` (quotes removed), nil when the key is absent or its
    /// value is empty (null).
    static func value(at path: [String], in yaml: String) throws -> String? {
        let document = Document(yaml)
        guard case .found(let index, _) = try document.locate(path) else { return nil }
        let raw = document.lines[index].valueText
        return raw.isEmpty ? nil : unquoted(raw)
    }

    /// `yaml` with the scalar at `path` set to `scalar` (written as given: `true`, `5`).
    static func setting(_ scalar: String, at path: [String], in yaml: String) throws -> String {
        precondition(!path.isEmpty, "a key path has at least one key")
        guard !scalar.isEmpty, !scalar.contains(where: \.isNewline), scalar.trimmingCharacters(in: .whitespaces) == scalar else {
            throw CPAConfigYAMLPatchError.ambiguous(path)
        }
        var document = Document(yaml)
        switch try document.locate(path) {
        case .found(let index, _):
            document.lines[index].replaceValue(with: scalar)
        case .missing(let depth, let insertAfter, let indent):
            // Keys path[depth...] are missing: written as a block under the deepest parent found.
            var block: [String] = []
            var level = indent
            for (offset, key) in path[depth...].enumerated() {
                let isLast = depth + offset == path.count - 1
                block.append(String(repeating: " ", count: level) + key + ":" + (isLast ? " " + scalar : ""))
                level += 2
            }
            document.insert(block, after: insertAfter)
        }
        return document.text
    }

    private static func unquoted(_ text: String) -> String {
        if text.count >= 2, let first = text.first, let last = text.last, first == last, first == "\"" || first == "'" {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}

private extension CPAConfigYAMLPatcher {
    struct Line {
        /// The line without its terminator.
        var content: String
        /// "\n", "\r\n" or "" (the last line of a file without a final newline).
        var terminator: String

        var isBlankOrComment: Bool {
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#")
        }

        var indent: Int { content.prefix { $0 == " " }.count }

        /// `key` when the line is `key:` / `"key":` / `'key':` followed by a space, a comment or
        /// the end of the line.
        var key: String? {
            let body = content.dropFirst(indent)
            guard !body.hasPrefix("- "), body != "-", let colon = keyColon(in: body) else { return nil }
            return CPAConfigYAMLPatcher.unquoted(String(body[body.startIndex..<colon]).trimmingCharacters(in: .whitespaces))
        }

        /// The value after `key:` with the comment and surrounding spaces removed.
        var valueText: String {
            guard let range = valueRange else { return "" }
            return String(content[range])
        }

        /// The value's range in `content` (empty range when there is no value).
        private var valueRange: Range<String.Index>? {
            let body = content.dropFirst(indent)
            guard let colon = keyColon(in: body) else { return nil }
            var start = content.index(after: colon)
            while start < content.endIndex, content[start] == " " { start = content.index(after: start) }
            var end = content.endIndex
            var quote: Character?
            var previous: Character = " "
            var index = start
            while index < content.endIndex {
                let character = content[index]
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "#" && (previous == " " || previous == "\t") {
                    end = index
                    break
                }
                previous = character
                index = content.index(after: index)
            }
            while end > start, content[content.index(before: end)] == " " || content[content.index(before: end)] == "\t" {
                end = content.index(before: end)
            }
            return start..<end
        }

        /// The colon that ends the key: the first ":" outside quotes that is followed by a space,
        /// a tab or the end of the line.
        private func keyColon(in body: Substring) -> String.Index? {
            var quote: Character?
            var index = body.startIndex
            while index < body.endIndex {
                let character = body[index]
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "\"" || character == "'" {
                    if index == body.startIndex { quote = character }
                } else if character == "#" {
                    return nil
                } else if character == ":" {
                    let next = body.index(after: index)
                    if next == body.endIndex || body[next] == " " || body[next] == "\t" { return index }
                }
                index = body.index(after: index)
            }
            return nil
        }

        mutating func replaceValue(with scalar: String) {
            guard let range = valueRange else { return }
            guard range.isEmpty else {
                content.replaceSubrange(range, with: scalar)
                return
            }
            // `key:` or `key: # comment`: the value goes after the colon, before the comment.
            let head = String(content[..<range.lowerBound])
            let tail = String(content[range.upperBound...])
            let separator = head.hasSuffix(" ") || head.hasSuffix("\t") ? "" : " "
            content = head + separator + scalar + (tail.isEmpty ? "" : " " + tail)
        }

        /// A compact sequence item (`- …`), which YAML allows at its key's own indentation.
        var isSequenceItem: Bool {
            let body = content.dropFirst(indent)
            return body == "-" || body.hasPrefix("- ")
        }
    }

    enum Location {
        /// The key's line.
        case found(index: Int, indent: Int)
        /// `path[depth]` is missing: the new block goes after line `after` (-1: at the very end),
        /// starting at `indent` spaces.
        case missing(depth: Int, after: Int, indent: Int)
    }

    struct Document {
        var lines: [Line]
        let newline: String

        init(_ text: String) {
            var lines: [Line] = []
            var current = ""
            var iterator = text.unicodeScalars.makeIterator()
            var pendingCR = false
            while let scalar = iterator.next() {
                if pendingCR {
                    pendingCR = false
                    if scalar == "\n" {
                        lines.append(Line(content: current, terminator: "\r\n"))
                        current = ""
                        continue
                    }
                    current.unicodeScalars.append("\r")
                }
                if scalar == "\r" {
                    pendingCR = true
                } else if scalar == "\n" {
                    lines.append(Line(content: current, terminator: "\n"))
                    current = ""
                } else {
                    current.unicodeScalars.append(scalar)
                }
            }
            if pendingCR { current.unicodeScalars.append("\r") }
            if !current.isEmpty { lines.append(Line(content: current, terminator: "")) }
            self.lines = lines
            newline = lines.first { !$0.terminator.isEmpty }?.terminator ?? "\n"
        }

        var text: String { lines.map { $0.content + $0.terminator }.joined() }

        /// Finds `path` from the top level, refusing shapes the patcher does not handle.
        func locate(_ path: [String]) throws -> Location {
            try refuseUnsupportedDocument(path)
            var range = 0..<lines.count
            for depth in path.indices {
                let key = path[depth]
                let prefix = Array(path[...depth])
                // The keys directly inside the current block: the smallest indentation there.
                let members = range.filter { !lines[$0].isBlankOrComment }
                guard let childIndent = members.map({ lines[$0].indent }).min() else {
                    return .missing(depth: depth, after: -1, indent: 0)
                }
                let direct = members.filter { lines[$0].indent == childIndent }
                if depth > 0 && direct.contains(where: { lines[$0].key == nil }) {
                    // A list (or anything that is not `key: value`) where a mapping is expected.
                    throw CPAConfigYAMLPatchError.ambiguous(Array(path[..<depth]))
                }
                let matches = direct.filter { lines[$0].key == key }
                if matches.count > 1 { throw CPAConfigYAMLPatchError.ambiguous(prefix) }
                guard let index = matches.first else {
                    let last = range.last { !lines[$0].isBlankOrComment } ?? -1
                    return .missing(depth: depth, after: depth == 0 ? -1 : last, indent: childIndent)
                }
                let value = lines[index].valueText
                if let first = value.first, "{[|>&*!".contains(first) {
                    throw CPAConfigYAMLPatchError.flowStyle(prefix)
                }
                // The key's block: the lines below it that are indented deeper (or are compact
                // sequence items at its own indentation), up to the next key of this level.
                let blockEnd = (index + 1..<range.upperBound).first { line in
                    let next = lines[line]
                    return !next.isBlankOrComment && (next.indent < childIndent || (next.indent == childIndent && !next.isSequenceItem))
                } ?? range.upperBound
                let children = index + 1..<blockEnd
                let hasChildren = children.contains { !lines[$0].isBlankOrComment }
                if depth == path.count - 1 {
                    // The scalar itself: a key with nested lines is a mapping or a list, not a scalar.
                    if hasChildren { throw CPAConfigYAMLPatchError.ambiguous(prefix) }
                    return .found(index: index, indent: childIndent)
                }
                // A parent: a block mapping (nested lines) or empty (null: children go below it).
                if !value.isEmpty { throw CPAConfigYAMLPatchError.ambiguous(prefix) }
                guard hasChildren else {
                    return .missing(depth: depth + 1, after: index, indent: childIndent + 2)
                }
                if children.contains(where: { !lines[$0].isBlankOrComment && lines[$0].indent == childIndent }) {
                    throw CPAConfigYAMLPatchError.ambiguous(prefix)
                }
                range = children
            }
            throw CPAConfigYAMLPatchError.ambiguous(path)
        }

        /// Several documents, tabs used for indentation, or top-level lines that are neither keys
        /// nor the compact list items of the key above them.
        private func refuseUnsupportedDocument(_ path: [String]) throws {
            var sawKey = false
            for line in lines where !line.isBlankOrComment {
                if line.content.hasPrefix("\t") { throw CPAConfigYAMLPatchError.ambiguous(path) }
                let trimmed = line.content.trimmingCharacters(in: .whitespaces)
                if trimmed == "---" || trimmed.hasPrefix("--- ") || trimmed == "..." {
                    if sawKey { throw CPAConfigYAMLPatchError.ambiguous(path) }
                    continue
                }
                guard line.indent == 0 else { continue }
                if line.key != nil {
                    sawKey = true
                } else if !(line.isSequenceItem && sawKey) {
                    throw CPAConfigYAMLPatchError.ambiguous(path)
                }
            }
        }

        /// Inserts `block` (lines without terminators) after line `after`; -1 appends at the end.
        mutating func insert(_ block: [String], after: Int) {
            let position = after < 0 ? lines.count : after + 1
            if position > 0, lines[position - 1].terminator.isEmpty {
                lines[position - 1].terminator = newline
            }
            lines.insert(contentsOf: block.map { Line(content: $0, terminator: newline) }, at: position)
        }
    }
}
