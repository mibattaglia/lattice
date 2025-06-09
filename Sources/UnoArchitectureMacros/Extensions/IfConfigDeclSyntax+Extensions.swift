import SwiftSyntax

extension IfConfigDeclSyntax {
    var availability: IfConfigDeclSyntax? {
        var elements = [IfConfigClauseListSyntax.Element]()
        for clause in clauses {
            if let availability = clause.availability {
                if elements.isEmpty {
                    elements.append(availability.clonedAsIf)
                } else {
                    elements.append(availability)
                }
            }
        }
        if elements.isEmpty {
            return nil
        } else {
            return with(\.clauses, IfConfigClauseListSyntax(elements))
        }
    }
}

extension IfConfigClauseSyntax {
    var availability: IfConfigClauseSyntax? {
        if let availability = elements?.availability {
            return with(\.elements, availability)
        } else {
            return nil
        }
    }

    var clonedAsIf: IfConfigClauseSyntax {
        detached.with(\.poundKeyword, .poundIfToken())
    }
}

extension IfConfigClauseSyntax.Elements {
    var availability: IfConfigClauseSyntax.Elements? {
        switch self {
        case .attributes(let attributes):
            if let availability = attributes.availability {
                return .attributes(availability)
            } else {
                return nil
            }
        default:
            return nil
        }
    }
}
