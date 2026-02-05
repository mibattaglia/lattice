import Darwin
import Foundation

enum ExitCode: Int32 {
    case success = 0
    case notFound = 1
    case invalidArgs = 2
    case runtimeError = 3
    case ioError = 4
}

struct CLIError: Error {
    let code: String
    let message: String
    let suggestions: [String]
    let exitCode: ExitCode
}

struct Context {
    let command: String
    let args: [String]
    let json: Bool
    let summaryDocs: Bool
    let compactJSON: Bool
}

struct DocSection {
    let level: Int
    let title: String
    let content: String
    let id: String
}

struct DocIndexEntry {
    let id: String
    let title: String
    let level: Int
    let parent: String?
    let aliases: [String]
    let tags: [String]
    let related: [String]
}

let rawArgs = Array(CommandLine.arguments.dropFirst())

var wantsJSON = false
var wantsText = false
var wantsSummaryDocs = false
var wantsCompactJSON = false
var filteredArgs: [String] = []
for arg in rawArgs {
    switch arg {
    case "--json":
        wantsJSON = true
    case "--text":
        wantsText = true
    case "--summary":
        wantsSummaryDocs = true
    case "--compact":
        wantsCompactJSON = true
    default:
        filteredArgs.append(arg)
    }
}

let stdoutIsTTY = isatty(STDOUT_FILENO) != 0
let jsonMode = wantsJSON || (!wantsText && !stdoutIsTTY)

let command = filteredArgs.first ?? "help"
let commandArgs = Array(filteredArgs.dropFirst())
let context = Context(
    command: command,
    args: commandArgs,
    json: jsonMode,
    summaryDocs: wantsSummaryDocs,
    compactJSON: wantsCompactJSON
)

func emitJSON(_ value: Any) {
    let data: Data
    do {
        data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    } catch {
        fputs(
            "{\"ok\":false,\"error\":{\"code\":\"runtime_error\",\"message\":\"JSON serialization failed\",\"suggestions\":[\"Use --text to bypass JSON\"]}}\n",
            stderr)
        exit(ExitCode.runtimeError.rawValue)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func emitJSONSuccess(cmd: String, out: Any) {
    if context.compactJSON {
        emitJSON(["ok": true, "c": cmd, "o": out])
    } else {
        emitJSON(["ok": true, "cmd": cmd, "out": out])
    }
}

func emitJSONError(cmd: String, code: String, message: String, suggestions: [String]) {
    if context.compactJSON {
        emitJSON([
            "ok": false,
            "c": cmd,
            "e": ["cd": code, "m": message, "s": suggestions],
        ])
    } else {
        emitJSON([
            "ok": false,
            "cmd": cmd,
            "error": ["code": code, "message": message, "suggestions": suggestions],
        ])
    }
}

func emitText(_ text: String) {
    print(text)
}

func errorResponse(_ err: CLIError) -> Never {
    if context.json {
        emitJSONError(cmd: context.command, code: err.code, message: err.message, suggestions: err.suggestions)
    } else {
        let suggestions = err.suggestions.isEmpty ? "" : " suggestions=\(err.suggestions.joined(separator: " | "))"
        emitText("error: code=\(err.code) message=\(err.message)\(suggestions)")
    }
    exit(err.exitCode.rawValue)
}

func helpOutput(topic: String?) -> (text: String, json: [String: Any]) {
    let usage = "usage: lattice <cmd> [args] [--json]"
    let commands = ["help [topic]", "meta", "version", "docs [topic|search <term>|topics|index] [--summary]"]
    let topics = ["commands", "json", "errors", "exit-codes", "docs"]
    let notes = "pipe=auto --json --compact"

    if let topic {
        switch topic {
        case "commands":
            return (
                text: "cmds: \(commands.joined(separator: " | "))",
                json: ["topic": "commands", "commands": commands]
            )
        case "json":
            return (
                text: "json: --json or pipe to auto-switch",
                json: ["topic": "json", "rules": ["--json", "pipe=auto", "--compact"]]
            )
        case "errors":
            return (
                text: "errors: {code,message,suggestions}",
                json: ["topic": "errors", "schema": ["code", "message", "suggestions"]]
            )
        case "exit-codes":
            return (
                text: "exit: 0 ok, 1 not_found, 2 invalid_args, 3 runtime, 4 io",
                json: [
                    "topic": "exit-codes",
                    "codes": [
                        "0": "success",
                        "1": "not_found",
                        "2": "invalid_args",
                        "3": "runtime_error",
                        "4": "io_error",
                    ],
                ]
            )
        case "docs":
            return (
                text: "docs: docs topics | docs index | docs <topic> [--summary] | docs search <term>",
                json: [
                    "topic": "docs",
                    "usage": ["docs topics", "docs index", "docs <topic> [--summary]", "docs search <term>"],
                ]
            )
        default:
            return (
                text: "",
                json: [:]
            )
        }
    }

    let text = [
        "lattice — compact CLI help",
        usage,
        "cmds: \(commands.joined(separator: " | "))",
        "topics: \(topics.joined(separator: " | "))",
        "note: \(notes)",
    ].joined(separator: "\n")

    let json: [String: Any] = [
        "usage": usage,
        "commands": commands,
        "topics": topics,
        "notes": ["pipe=auto", "--json", "--compact"],
    ]

    return (text, json)
}

func metaOutput() -> (text: String, json: [String: Any]) {
    let json: [String: Any] = [
        "name": "lattice",
        "commands": ["help", "meta", "version", "docs"],
        "flags": ["--json", "--text", "--summary", "--compact"],
        "auto": ["pipe": "json"],
        "errors": ["code", "message", "suggestions"],
        "exit": [
            "0": "success",
            "1": "not_found",
            "2": "invalid_args",
            "3": "runtime_error",
            "4": "io_error",
        ],
        "docs": [
            "commands": ["topics", "search", "topic", "index"],
            "source": "Resources/agent-docs.md",
            "flags": ["--summary", "--compact"],
        ],
    ]

    let text = "meta: cmds=help|meta|version|docs flags=--json|--summary|--compact exit=0/1/2/3/4"
    return (text, json)
}

func versionString() -> String {
    if let envVersion = ProcessInfo.processInfo.environment["LATTICE_VERSION"], !envVersion.isEmpty {
        return envVersion
    }
    return "dev"
}

func normalizeAlias(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "" }
    return trimmed
}

func slug(_ value: String) -> String {
    let lower = value.lowercased()
    var out: [UInt8] = []
    out.reserveCapacity(lower.utf8.count)
    var lastDash = false
    for scalar in lower.unicodeScalars {
        if (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 122) {
            out.append(UInt8(scalar.value))
            lastDash = false
        } else {
            if !lastDash {
                out.append(UInt8(ascii: "-"))
                lastDash = true
            }
        }
    }
    while out.first == UInt8(ascii: "-") { out.removeFirst() }
    while out.last == UInt8(ascii: "-") { out.removeLast() }
    return String(bytes: out, encoding: .utf8) ?? ""
}

func uniqueStrings(_ values: [String], limit: Int) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for value in values {
        if value.isEmpty { continue }
        if seen.insert(value).inserted {
            out.append(value)
            if out.count >= limit { break }
        }
    }
    return out
}

func extractBacktickedTokens(from text: String, limit: Int) -> [String] {
    var tokens: [String] = []
    var current: [Character] = []
    var inTick = false
    for ch in text {
        if ch == "`" {
            if inTick {
                let raw = String(current)
                let parts = raw.split {
                    $0.isWhitespace || $0 == ":" || $0 == "." || $0 == "," || $0 == "(" || $0 == ")"
                }
                for part in parts where !part.isEmpty {
                    tokens.append(String(part))
                    if tokens.count >= limit { return tokens }
                }
                current.removeAll(keepingCapacity: true)
            }
            inTick.toggle()
            continue
        }
        if inTick { current.append(ch) }
    }
    return tokens
}

func buildDocIndex(sections: [DocSection]) -> [DocIndexEntry] {
    var parents: [Int] = Array(repeating: -1, count: sections.count)
    for i in 0..<sections.count {
        let level = sections[i].level
        var j = i - 1
        while j >= 0 {
            if sections[j].level < level {
                parents[i] = j
                break
            }
            j -= 1
        }
    }

    var entries: [DocIndexEntry] = []
    entries.reserveCapacity(sections.count)
    for (idx, section) in sections.enumerated() {
        let parentId = parents[idx] >= 0 ? sections[parents[idx]].id : nil
        var aliasCandidates: [String] = []
        aliasCandidates.append(section.id)
        aliasCandidates.append(section.title)
        aliasCandidates.append(section.title.lowercased())
        for separator in [":", " - ", " / "] {
            if section.title.contains(separator) {
                let parts = section.title.components(separatedBy: separator).map { normalizeAlias($0) }
                aliasCandidates.append(contentsOf: parts)
                aliasCandidates.append(contentsOf: parts.map { $0.lowercased() })
            }
        }
        let aliases = uniqueStrings(aliasCandidates.map(normalizeAlias), limit: 8)

        var tagCandidates = extractBacktickedTokens(from: section.content, limit: 12)
        if tagCandidates.isEmpty {
            let words = section.title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            tagCandidates.append(contentsOf: words)
        }
        let tags = uniqueStrings(tagCandidates, limit: 8)

        let siblingIndexes = sections.indices.filter { parents[$0] == parents[idx] && $0 != idx }
        let related = uniqueStrings(siblingIndexes.prefix(6).map { sections[$0].id }, limit: 5)

        entries.append(
            DocIndexEntry(
                id: section.id,
                title: section.title,
                level: section.level,
                parent: parentId,
                aliases: aliases,
                tags: tags,
                related: related
            ))
    }
    return entries
}

func compactDocEntry(_ entry: DocIndexEntry, summary: String?, content: String?) -> [String: Any] {
    var out: [String: Any] = [
        "i": entry.id,
        "t": entry.title,
        "l": entry.level,
    ]
    if let parent = entry.parent { out["p"] = parent }
    if !entry.aliases.isEmpty { out["a"] = entry.aliases }
    if !entry.tags.isEmpty { out["g"] = entry.tags }
    if !entry.related.isEmpty { out["r"] = entry.related }
    if let summary { out["s"] = summary }
    if let content { out["c"] = content }
    return out
}

func fullDocEntry(_ entry: DocIndexEntry, summary: String?, content: String?) -> [String: Any] {
    var out: [String: Any] = [
        "id": entry.id,
        "title": entry.title,
        "level": entry.level,
        "aliases": entry.aliases,
        "tags": entry.tags,
        "related": entry.related,
        "summary": summary ?? "",
    ]
    if let parent = entry.parent { out["parent"] = parent }
    if let content { out["content"] = content }
    return out
}

func loadDocsText() -> String? {
    if let url = Bundle.module.url(forResource: "agent-docs", withExtension: "md"),
        let data = try? Data(contentsOf: url),
        let text = String(data: data, encoding: .utf8)
    {
        return text
    }
    let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let readmeURL = cwdURL.appendingPathComponent("README.md")
    if let data = try? Data(contentsOf: readmeURL),
        let text = String(data: data, encoding: .utf8)
    {
        return text
    }
    return nil
}

func parseDocsSections(from text: String) -> [DocSection] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var sections: [DocSection] = []
    var currentTitle: String?
    var currentLevel = 0
    var currentLines: [Substring] = []

    func flush() {
        guard let title = currentTitle else { return }
        let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let id = slug(title)
        sections.append(DocSection(level: currentLevel, title: title, content: content, id: id))
        currentTitle = nil
        currentLevel = 0
        currentLines.removeAll(keepingCapacity: true)
    }

    for line in lines {
        if line.hasPrefix("#") {
            let hashCount = line.prefix { $0 == "#" }.count
            let title = line.dropFirst(hashCount).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty {
                flush()
                currentTitle = title
                currentLevel = hashCount
                continue
            }
        }
        currentLines.append(line)
    }
    flush()
    return sections
}

func compactText(_ value: String, maxChars: Int) -> String {
    let collapsed =
        value
        .replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "  ", with: " ")
    if collapsed.count <= maxChars { return collapsed }
    let endIndex = collapsed.index(collapsed.startIndex, offsetBy: maxChars)
    return String(collapsed[..<endIndex]).trimmingCharacters(in: .whitespaces) + "…"
}

func summaryFromContent(_ content: String) -> String {
    let paragraphs = content.split(separator: "\n\n", omittingEmptySubsequences: true)
    let first = paragraphs.first.map(String.init) ?? ""
    return compactText(first.trimmingCharacters(in: .whitespacesAndNewlines), maxChars: 320)
}

func docSuggestions(for query: String, entries: [DocIndexEntry]) -> [String] {
    let q = query.lowercased()
    let hits = entries.filter { entry in
        if entry.title.lowercased().contains(q) { return true }
        if entry.id.contains(q) { return true }
        if entry.aliases.contains(where: { $0.lowercased().contains(q) }) { return true }
        if entry.tags.contains(where: { $0.lowercased().contains(q) }) { return true }
        return false
    }
    return Array(hits.prefix(4).map { $0.id })
}

func run() throws {
    switch context.command {
    case "help", "-h", "--help":
        if context.args.count > 1 {
            throw CLIError(
                code: "invalid_args",
                message: "too many help args",
                suggestions: ["help", "help commands", "help json", "help errors", "help exit-codes"],
                exitCode: .invalidArgs
            )
        }
        let topic = context.args.first
        let output = helpOutput(topic: topic)
        if topic != nil && output.text.isEmpty {
            throw CLIError(
                code: "not_found",
                message: "unknown help topic",
                suggestions: ["help commands", "help json", "help errors", "help exit-codes"],
                exitCode: .notFound
            )
        }
        if context.json {
            emitJSONSuccess(cmd: "help", out: output.json)
        } else {
            emitText(output.text)
        }
    case "meta":
        if !context.args.isEmpty {
            throw CLIError(
                code: "invalid_args",
                message: "meta takes no args",
                suggestions: ["meta", "help meta"],
                exitCode: .invalidArgs
            )
        }
        let output = metaOutput()
        if context.json {
            emitJSONSuccess(cmd: "meta", out: output.json)
        } else {
            emitText(output.text)
        }
    case "version", "-v", "--version":
        if !context.args.isEmpty {
            throw CLIError(
                code: "invalid_args",
                message: "version takes no args",
                suggestions: ["version"],
                exitCode: .invalidArgs
            )
        }
        let version = versionString()
        if context.json {
            emitJSONSuccess(cmd: "version", out: ["version": version])
        } else {
            emitText(version)
        }
    case "docs":
        guard let docsText = loadDocsText() else {
            throw CLIError(
                code: "io_error",
                message: "docs source missing",
                suggestions: ["run in repo", "install resources"],
                exitCode: .ioError
            )
        }
        let sections = parseDocsSections(from: docsText)
        let indexEntries = buildDocIndex(sections: sections)
        let entryById = Dictionary(uniqueKeysWithValues: indexEntries.map { ($0.id, $0) })
        if context.args.isEmpty {
            let text =
                "docs: topics=\(sections.count) use=docs topics | docs index | docs <topic> [--summary] | docs search <term>"
            if context.json {
                let usage = ["docs topics", "docs index", "docs <topic> [--summary]", "docs search <term>"]
                if context.compactJSON {
                    emitJSONSuccess(cmd: "docs", out: ["n": sections.count, "u": usage])
                } else {
                    emitJSONSuccess(cmd: "docs", out: ["topics_count": sections.count, "usage": usage])
                }
            } else {
                emitText(text)
            }
            return
        }
        let sub = context.args.first ?? ""
        if sub == "topics" {
            let items = sections.map { ["id": $0.id, "title": $0.title, "level": $0.level] }
            if context.json {
                if context.compactJSON {
                    let ids = sections.map { $0.id }
                    emitJSONSuccess(cmd: "docs", out: ["t": ids])
                } else {
                    emitJSONSuccess(cmd: "docs", out: ["topics": items])
                }
            } else {
                let sample = sections.prefix(12).map { $0.id }.joined(separator: " | ")
                let suffix = sections.count > 12 ? " | …" : ""
                emitText("topics: count=\(sections.count) sample=\(sample)\(suffix)")
            }
            return
        }
        if sub == "index" {
            if context.json {
                if context.compactJSON {
                    let payload = indexEntries.map { compactDocEntry($0, summary: nil, content: nil) }
                    emitJSONSuccess(cmd: "docs", out: ["t": payload])
                } else {
                    let payload = indexEntries.map { fullDocEntry($0, summary: nil, content: nil) }
                    emitJSONSuccess(cmd: "docs", out: ["topics": payload])
                }
            } else {
                emitText("index: topics=\(sections.count)")
            }
            return
        }
        if sub == "search" {
            if context.args.count < 2 {
                throw CLIError(
                    code: "invalid_args",
                    message: "search needs term",
                    suggestions: ["docs search interactor", "docs search viewstate"],
                    exitCode: .invalidArgs
                )
            }
            let term = context.args.dropFirst().joined(separator: " ")
            let q = term.lowercased()
            let matches = sections.compactMap { section -> (DocSection, DocIndexEntry)? in
                guard let entry = entryById[section.id] else { return nil }
                let haystack = [
                    section.title,
                    section.content,
                    entry.aliases.joined(separator: " "),
                    entry.tags.joined(separator: " "),
                ].joined(separator: " ").lowercased()
                return haystack.contains(q) ? (section, entry) : nil
            }
            let out = matches.prefix(10).map { section, entry -> [String: Any] in
                let summary = summaryFromContent(section.content)
                if context.compactJSON {
                    return compactDocEntry(entry, summary: summary, content: nil)
                }
                return fullDocEntry(entry, summary: summary, content: nil)
            }
            if context.json {
                if context.compactJSON {
                    emitJSONSuccess(cmd: "docs", out: ["q": term, "m": out])
                } else {
                    emitJSONSuccess(cmd: "docs", out: ["term": term, "matches": out])
                }
            } else {
                let ids = matches.prefix(10).map { $0.0.id }.joined(separator: " | ")
                emitText("matches: \(ids)")
            }
            return
        }
        if context.args.count > 1 {
            throw CLIError(
                code: "invalid_args",
                message: "docs takes one topic or subcommand",
                suggestions: ["docs topics", "docs index", "docs search <term>", "docs <topic>"],
                exitCode: .invalidArgs
            )
        }
        let query = sub.lowercased()
        if let section = sections.first(where: { $0.id == query || $0.title.lowercased() == query }) {
            let summary = summaryFromContent(section.content)
            if context.json {
                if let entry = entryById[section.id] {
                    let content = context.summaryDocs ? nil : section.content
                    if context.compactJSON {
                        let out = compactDocEntry(entry, summary: summary, content: content)
                        emitJSONSuccess(cmd: "docs", out: out)
                    } else {
                        let out = fullDocEntry(entry, summary: summary, content: content)
                        emitJSONSuccess(cmd: "docs", out: out)
                    }
                } else {
                    emitJSONSuccess(cmd: "docs", out: ["id": section.id, "title": section.title, "summary": summary])
                }
            } else {
                if context.summaryDocs {
                    emitText("doc: id=\(section.id) title=\(section.title) summary=\(summary)")
                } else {
                    emitText(section.content)
                }
            }
        } else {
            throw CLIError(
                code: "not_found",
                message: "unknown doc topic",
                suggestions: docSuggestions(for: query, entries: indexEntries),
                exitCode: .notFound
            )
        }
    default:
        throw CLIError(
            code: "not_found",
            message: "unknown command",
            suggestions: ["help", "meta", "version", "docs"],
            exitCode: .notFound
        )
    }
}

do {
    try run()
} catch let err as CLIError {
    errorResponse(err)
} catch {
    let err = CLIError(
        code: "runtime_error",
        message: "unexpected error",
        suggestions: ["run with --json for details"],
        exitCode: .runtimeError
    )
    errorResponse(err)
}
