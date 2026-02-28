import Testing

@testable import Lattice

@Suite
@MainActor
struct EmissionAppendTests {

    enum Action: Sendable, Equatable {
        case a, b, c
    }

    @Test
    func flattenNestedAppend() {
        let inner = Emission<Action>.append(
            .action(.a),
            .action(.b)
        )
        let outer = Emission<Action>.append(inner, .action(.c))

        guard case .append(let children) = outer.kind else {
            Issue.record("Expected .append")
            return
        }

        #expect(children.count == 3)
        guard case .action(.a) = children[0].kind,
            case .action(.b) = children[1].kind,
            case .action(.c) = children[2].kind
        else {
            Issue.record("Expected flattened [.a, .b, .c]")
            return
        }
    }

    @Test
    func dropsNoneChildren() {
        let emission = Emission<Action>.append(.none, .action(.a), .none)

        guard case .action(.a) = emission.kind else {
            Issue.record("Expected single .action(.a) after dropping .none")
            return
        }
    }

    @Test
    func emptyAppendIsNone() {
        let emission = Emission<Action>.append([Emission<Action>]())

        guard case .none = emission.kind else {
            Issue.record("Expected .none for empty append")
            return
        }
    }

    @Test
    func allNoneChildrenCollapseToNone() {
        let emission = Emission<Action>.append(.none, .none, .none)

        guard case .none = emission.kind else {
            Issue.record("Expected .none when all children are .none")
            return
        }
    }

    @Test
    func singleChildUnwrapped() {
        let emission = Emission<Action>.append(.action(.a))

        guard case .action(.a) = emission.kind else {
            Issue.record("Expected unwrapped .action(.a)")
            return
        }
    }

    @Test
    func thenProducesSameResultAsAppending() {
        let via_then = Emission<Action>.action(.a)
            .then(.action(.b))

        let via_appending = Emission<Action>.action(.a)
            .appending(with: .action(.b))

        guard case .append(let c1) = via_then.kind,
            case .append(let c2) = via_appending.kind
        else {
            Issue.record("Expected .append for both")
            return
        }

        #expect(c1.count == c2.count)
    }

    @Test
    func mapRecursivelyTransformsAppendChildren() {
        let emission = Emission<Int>.append(
            .action(1),
            .action(2)
        )

        let mapped = emission.map { String($0) }

        guard case .append(let children) = mapped.kind else {
            Issue.record("Expected .append")
            return
        }

        #expect(children.count == 2)
        guard case .action(let first) = children[0].kind,
            case .action(let second) = children[1].kind
        else {
            Issue.record("Expected .action children")
            return
        }
        #expect(first == "1")
        #expect(second == "2")
    }
}
