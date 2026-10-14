import SwiftSyntax
import SwiftSyntaxBuilder

/// Renders the generated projection declarations for one `@FeatureState` type.
struct ViewStateRenderer {
    let typeName: String
    /// `public `, `package `, `fileprivate ` or empty.
    let access: String
    let members: [ViewStateMember]
    let isIdentifiable: Bool
    var attributes: [String]
    let conformances: String

    var structDeclarations: [DeclSyntax] {
        let body =
            [
                "@_spi(Lattice) public let \(FeatureStateMacro.viewStateStorageName): \(typeName)",
                "\(access)init(_ state: \(typeName)) {",
                "self._state = state",
                "}",
            ] + forwardedProperties + domainStubs
        return [
            typesProtocol,
            witnessStruct,
            declaration(
                attributes + ["\(access)struct \(FeatureStateMacro.viewStateTypeName): \(conformances)"],
                body
            ),
        ]
    }

    func enumDeclarations(isIndirect: Bool) -> [DeclSyntax] {
        let cases = render { member in
            guard case .enumCase(let enumCase) = member else { return [] }
            let indirect = enumCase.isIndirect ? "indirect " : ""
            guard !enumCase.payloads.isEmpty else { return ["\(indirect)case \(enumCase.name.text)"] }
            let payloads = enumCase.payloads.indices.map { index in
                labeled(enumCase.payloads[index], "_$ViewStateWitness.\(enumCase.witnessName(index))")
            }
            return ["\(indirect)case \(enumCase.name.text)(\(payloads.joined(separator: ", ")))"]
        }
        let initCases = render { member in
            guard case .enumCase(let enumCase) = member else { return [] }
            return switchCase(enumCase, body: "self =") { index in "Lattice._$project(p\(index))" }
        }
        let stateCases = render { member in
            guard case .enumCase(let enumCase) = member else { return [] }
            return switchCase(enumCase, body: "return") { index in
                "Lattice._$unproject(p\(index), to: (\(enumCase.payloads[index].type.trimmedDescription)).self)"
            }
        }
        let body =
            cases
            + ["\(access)init(_ state: \(typeName)) {", "switch state {"] + initCases + ["}", "}"]
            + ["@_spi(Lattice) public var \(FeatureStateMacro.viewStateStorageName): \(typeName) {", "switch self {"]
            + stateCases + ["}", "}"]
            + forwardedProperties + domainStubs
        let indirect = isIndirect ? "indirect " : ""
        return [
            typesProtocol,
            witnessStruct,
            declaration(
                attributes + ["\(access)\(indirect)enum \(FeatureStateMacro.viewStateTypeName): \(conformances)"],
                body
            ),
        ]
    }

    /// One associated type per visible property, per inferred-type `@Domain` property (its stub
    /// needs a type) and per enum payload.
    private var typesProtocol: DeclSyntax {
        let requirements = render { member in
            switch member {
            case .property(let name, let type, let isDomain):
                guard !isDomain || type == nil else { return [] }
                return ["associatedtype \(name.text)", "var _$\(name.bareText): \(name.text) { get }"]
            case .enumCase(let enumCase):
                return enumCase.payloads.indices.flatMap { index in
                    let witness = enumCase.witnessName(index)
                    return ["associatedtype \(witness)", "var _$\(witness): \(witness) { get }"]
                }
            case .ifConfig:
                return []
            }
        }
        return declaration(["\(access)protocol \(FeatureStateMacro.viewStateTypesProtocolName)"], requirements)
    }

    private var witnessStruct: DeclSyntax {
        // A value of the state's type, or of a payload's type for enum cases, for the type checker
        // to infer each member's projected type; never evaluated.
        let placeholder = "Lattice._$placeholder(\(typeName).self)"
        let witnesses = render { member in
            switch member {
            case .property(let name, let type, let isDomain):
                if isDomain {
                    // No `_$project`: the stub keeps the member's own type.
                    return type == nil ? ["\(access)let _$\(name.bareText) = \(placeholder).\(name.text)"] : []
                }
                return ["\(access)let _$\(name.bareText) = Lattice._$project(\(placeholder).\(name.text))"]
            case .enumCase(let enumCase):
                return enumCase.payloads.indices.map { index in
                    let payloadType = enumCase.payloads[index].type.trimmedDescription
                    return "\(access)let _$\(enumCase.witnessName(index)) = "
                        + "Lattice._$project(Lattice._$placeholder((\(payloadType)).self))"
                }
            case .ifConfig:
                return []
            }
        }
        return declaration(
            [
                "\(access)struct \(FeatureStateMacro.viewStateWitnessTypeName): "
                    + FeatureStateMacro.viewStateTypesProtocolName
            ],
            witnesses
        )
    }

    private var forwardedProperties: [String] {
        render { member in
            guard case .property(let name, _, isDomain: false) = member else { return [] }
            return [
                "\(access)var \(name.text): _$ViewStateWitness.\(name.text) {",
                "Lattice._$project(_state.\(name.text))",
                "}",
            ]
        }
    }

    private var domainStubs: [String] {
        render { member in
            guard case .property(let name, let type, isDomain: true) = member,
                // An `id` stub would shadow the `Identifiable` witness; that case is diagnosed.
                !(isIdentifiable && name.bareText == "id")
            else {
                return []
            }
            return [
                "@available(*, unavailable, message: \"'\(name.bareText)' is @Domain state and is not visible to views\")",
                "\(access)var \(name.text): \(type?.trimmedDescription ?? "_$ViewStateWitness.\(name.text)") {",
                "fatalError()",
                "}",
            ]
        }
    }

    /// `header` lines (attributes, then the declaration line) followed by a braced `body`.
    private func declaration(_ header: [String], _ body: [String]) -> DeclSyntax {
        let opening = header.joined(separator: "\n") + " {"
        return "\(raw: ([opening] + body + ["}"]).joined(separator: "\n"))"
    }

    private func labeled(_ payload: ViewStateCase.Payload, _ value: String) -> String {
        payload.label.map { "\($0.text): \(value)" } ?? value
    }

    private func switchCase(
        _ enumCase: ViewStateCase,
        body: String,
        payload: (Int) -> String
    ) -> [String] {
        let name = enumCase.name.text
        guard !enumCase.payloads.isEmpty else { return ["case .\(name):", "\(body) .\(name)"] }
        let bindings = enumCase.payloads.indices.map { "p\($0)" }.joined(separator: ", ")
        let arguments = enumCase.payloads.indices.map { labeled(enumCase.payloads[$0], payload($0)) }
        return [
            "case let .\(name)(\(bindings)):",
            "\(body) .\(name)(\(arguments.joined(separator: ", ")))",
        ]
    }

    /// Renders `members` in order, mirroring `#if` blocks. A block that renders no lines in
    /// every clause is dropped.
    private func render(_ line: (ViewStateMember) -> [String]) -> [String] {
        Self.render(members, line)
    }

    private static func render(
        _ members: [ViewStateMember],
        _ line: (ViewStateMember) -> [String]
    ) -> [String] {
        var lines: [String] = []
        for member in members {
            guard case .ifConfig(let clauses) = member else {
                lines += line(member)
                continue
            }
            let rendered = clauses.map { (header: $0.header, lines: render($0.members, line)) }
            guard rendered.contains(where: { !$0.lines.isEmpty }) else { continue }
            for clause in rendered {
                lines.append(clause.header)
                lines += clause.lines
            }
            lines.append("#endif")
        }
        return lines
    }
}

extension TokenSyntax {
    /// The identifier without backticks.
    var bareText: String { identifier?.name ?? text }
}

extension DeclModifierListSyntax {
    /// `public `, `package `, `fileprivate ` (for `private` and `fileprivate`) or an empty string
    /// for internal; `nil` when no access modifier is written. Generated members are never more
    /// visible than the state, and file-scope extensions of `ViewState` need `fileprivate` members.
    var accessLevel: String? {
        for modifier in self where modifier.detail == nil {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open):
                return "public "
            case .keyword(.package):
                return "package "
            case .keyword(.fileprivate), .keyword(.private):
                return "fileprivate "
            case .keyword(.internal):
                return ""
            default:
                continue
            }
        }
        return nil
    }
}

extension VariableDeclSyntax {
    var bindingNames: [TokenSyntax] {
        bindings.compactMap { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier }
    }
}

extension DeclGroupSyntax {
    /// Protocol names in the inheritance clause, looking through compositions, `@unchecked` and
    /// a `Swift.` qualifier.
    var inheritedTypeNames: Set<String> {
        var names: Set<String> = []
        func collect(_ type: TypeSyntax) {
            if let attributed = type.as(AttributedTypeSyntax.self) {
                collect(attributed.baseType)
            } else if let composition = type.as(CompositionTypeSyntax.self) {
                composition.elements.forEach { collect($0.type) }
            } else {
                let name = type.trimmedDescription
                names.insert(name.hasPrefix("Swift.") ? String(name.dropFirst("Swift.".count)) : name)
            }
        }
        inheritanceClause?.inheritedTypes.forEach { collect($0.type) }
        return names
    }
}
