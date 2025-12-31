extension AsyncStream {
    public func interact<I: Interactor>(with interactor: I) -> AsyncStream<I.DomainState>
    where Element == I.Action {
        interactor.interact(self)
    }
}
