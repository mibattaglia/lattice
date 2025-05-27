import Foundation

@resultBuilder
public enum ViewStateReducerBuilder<DomainState, ViewState> {
    public static func buildBlock<V: ViewStateReducer<DomainState, ViewState>>(
        _ component: V
    ) -> V {
        component
    }
}
