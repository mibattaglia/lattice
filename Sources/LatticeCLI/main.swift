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
}

struct DocSection {
    let level: Int
    let title: String
    let content: String
    let id: String
}

let rawArgs = Array(CommandLine.arguments.dropFirst())

var wantsJSON = false
var wantsText = false
var wantsSummaryDocs = false
var filteredArgs: [String] = []
for arg in rawArgs {
    switch arg {
    case "--json":
        wantsJSON = true
    case "--text":
        wantsText = true
    case "--summary":
        wantsSummaryDocs = true
    default:
        filteredArgs.append(arg)
    }
}

let stdoutIsTTY = isatty(STDOUT_FILENO) != 0
let jsonMode = wantsJSON || (!wantsText && !stdoutIsTTY)

let command = filteredArgs.first ?? "help"
let commandArgs = Array(filteredArgs.dropFirst())
let context = Context(command: command, args: commandArgs, json: jsonMode, summaryDocs: wantsSummaryDocs)

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

func emitText(_ text: String) {
    print(text)
}

func errorResponse(_ err: CLIError) -> Never {
    if context.json {
        emitJSON([
            "ok": false,
            "cmd": context.command,
            "error": [
                "code": err.code,
                "message": err.message,
                "suggestions": err.suggestions,
            ],
        ])
    } else {
        let suggestions = err.suggestions.isEmpty ? "" : " suggestions=\(err.suggestions.joined(separator: " | "))"
        emitText("error: code=\(err.code) message=\(err.message)\(suggestions)")
    }
    exit(err.exitCode.rawValue)
}

func helpOutput(topic: String?) -> (text: String, json: [String: Any]) {
    let usage = "usage: lattice <cmd> [args] [--json]"
    let commands = ["help [topic]", "meta", "version", "docs [topic|search <term>|topics] [--summary]"]
    let topics = ["commands", "json", "errors", "exit-codes", "docs"]
    let notes = "pipe=auto --json"

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
                json: ["topic": "json", "rules": ["--json", "pipe=auto"]]
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
                text: "docs: docs topics | docs <topic> [--summary] | docs search <term>",
                json: ["topic": "docs", "usage": ["docs topics", "docs <topic> [--summary]", "docs search <term>"]]
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
        "notes": ["pipe=auto", "--json"],
    ]

    return (text, json)
}

func metaOutput() -> (text: String, json: [String: Any]) {
    let json: [String: Any] = [
        "name": "lattice",
        "commands": ["help", "meta", "version", "docs"],
        "flags": ["--json", "--text", "--summary"],
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
            "commands": ["topics", "search", "topic"],
            "source": "Resources/agent-docs.md",
            "flags": ["--summary"],
        ],
    ]

    let text = "meta: cmds=help|meta|version|docs flags=--json|--summary exit=0/1/2/3/4"
    return (text, json)
}

func versionString() -> String {
    if let envVersion = ProcessInfo.processInfo.environment["LATTICE_VERSION"], !envVersion.isEmpty {
        return envVersion
    }
    return "dev"
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

func docSuggestions(for query: String, sections: [DocSection]) -> [String] {
    let q = query.lowercased()
    let hits = sections.filter { $0.title.lowercased().contains(q) || $0.id.contains(q) }
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
            emitJSON(["ok": true, "cmd": "help", "out": output.json])
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
            emitJSON(["ok": true, "cmd": "meta", "out": output.json])
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
            emitJSON(["ok": true, "cmd": "version", "out": ["version": version]])
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
        if context.args.isEmpty {
            let text = "docs: topics=\(sections.count) use=docs topics | docs <topic> [--summary] | docs search <term>"
            if context.json {
                emitJSON([
                    "ok": true, "cmd": "docs",
                    "out": [
                        "topics_count": sections.count,
                        "usage": ["docs topics", "docs <topic> [--summary]", "docs search <term>"],
                    ],
                ])
            } else {
                emitText(text)
            }
            return
        }
        let sub = context.args.first ?? ""
        if sub == "topics" {
            let items = sections.map { ["id": $0.id, "title": $0.title, "level": $0.level] }
            if context.json {
                emitJSON(["ok": true, "cmd": "docs", "out": ["topics": items]])
            } else {
                let sample = sections.prefix(12).map { $0.id }.joined(separator: " | ")
                let suffix = sections.count > 12 ? " | …" : ""
                emitText("topics: count=\(sections.count) sample=\(sample)\(suffix)")
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
            let matches = sections.filter {
                $0.title.lowercased().contains(q) || $0.content.lowercased().contains(q)
            }
            let out = matches.prefix(10).map { section -> [String: Any] in
                ["id": section.id, "title": section.title, "summary": summaryFromContent(section.content)]
            }
            if context.json {
                emitJSON(["ok": true, "cmd": "docs", "out": ["term": term, "matches": out]])
            } else {
                let ids = matches.prefix(10).map { $0.id }.joined(separator: " | ")
                emitText("matches: \(ids)")
            }
            return
        }
        if context.args.count > 1 {
            throw CLIError(
                code: "invalid_args",
                message: "docs takes one topic or subcommand",
                suggestions: ["docs topics", "docs search <term>", "docs <topic>"],
                exitCode: .invalidArgs
            )
        }
        let query = sub.lowercased()
        if let section = sections.first(where: { $0.id == query || $0.title.lowercased() == query }) {
            let summary = summaryFromContent(section.content)
            if context.json {
                var out: [String: Any] = [
                    "id": section.id,
                    "title": section.title,
                    "level": section.level,
                    "summary": summary,
                ]
                if !context.summaryDocs {
                    out["content"] = section.content
                }
                emitJSON(["ok": true, "cmd": "docs", "out": out])
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
                suggestions: docSuggestions(for: query, sections: sections),
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
