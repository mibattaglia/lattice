#if canImport(Testing)
    import Testing

    public func streamConfirmation<State: Equatable>(
        stream: AsyncStream<State>,
        expectedResult: State...
    ) async {
        let expected = expectedResult.map { $0 }
        var actual: [State] = []
        for await value in stream {
            actual.append(value)
            if actual.count == expected.count {
                break
            }
        }

        #expect(actual == expected)
    }

    public func streamConfirmation<State: Equatable>(
        stream: AsyncStream<State>,
        expectedResult: [State]
    ) async {
        let expected = expectedResult
        var actual: [State] = []
        for await value in stream {
            actual.append(value)
            if actual.count == expected.count {
                break
            }
        }

        #expect(actual == expected)
    }
#endif
