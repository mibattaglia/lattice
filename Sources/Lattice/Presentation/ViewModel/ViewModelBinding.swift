import SwiftUI

#if canImport(CasePaths)
    import CasePaths
#endif

/// A wrapper that enables creating SwiftUI bindings from projected ViewModel members.
///
/// This type is not created directly. Instead, use the `@Bindable` property wrapper
/// with a view model and access projected members via dynamic member lookup:
///
/// ```swift
/// @Bindable var viewModel: ViewModel<FormState, FormAction>
///
/// TextField("Name", text: $viewModel.name.sending(\.nameChanged))
/// ```
///
/// Reads route through the state's view projection (registering observation access like any
/// read); writes send the event through the interactor.
@dynamicMemberLookup
@MainActor
public struct _ViewModelBinding<State: FeatureStateProtocol, Action, Value> {
    private let viewModel: ViewModel<State, Action>
    private let read: () -> Value

    init(
        viewModel: ViewModel<State, Action>,
        read: @escaping () -> Value
    ) {
        self.viewModel = viewModel
        self.read = read
    }

    /// Accesses nested properties of the current value.
    ///
    /// The first hop registered the projected member's key; nested hops read plainly through
    /// the member value (a nested change fires the member key, since stored members are
    /// diffed by whole-value equality).
    public subscript<Member>(
        dynamicMember keyPath: KeyPath<Value, Member>
    ) -> _ViewModelBinding<State, Action, Member> {
        let read = self.read
        return _ViewModelBinding<State, Action, Member>(
            viewModel: viewModel,
            read: { read()[keyPath: keyPath] }
        )
    }

    /// Creates a SwiftUI binding that sends the specified action when the value changes.
    #if canImport(CasePaths)
        @MainActor
        public func sending(_ action: CaseKeyPath<Action, Value>) -> Binding<Value> {
            let read = self.read
            let viewModel = self.viewModel
            return Binding(
                get: { read() },
                set: { newValue in
                    viewModel.sendViewEvent(action(newValue))
                }
            )
        }
    #endif
}

/// A convenience alias for ``_ViewModelBinding``.
public typealias _ViewModelBindingOf<State: FeatureStateProtocol, Action, Value> =
    _ViewModelBinding<State, Action, Value>

extension Bindable {
    /// Accesses projected ViewModel members for creating bindings.
    @MainActor
    public subscript<State: FeatureStateProtocol, Action, Member: Equatable>(
        dynamicMember keyPath: KeyPath<State._ViewMembers, Member>
    ) -> _ViewModelBindingOf<State, Action, Member>
    where
        Value == ViewModel<State, Action>
    {
        let viewModel = self.wrappedValue
        return _ViewModelBinding(
            viewModel: viewModel,
            read: { viewModel[dynamicMember: keyPath] }
        )
    }

    #if canImport(CasePaths)
        /// Accesses ViewModel state case properties for CasePathable state enums.
        @MainActor
        public subscript<State: FeatureStateProtocol, Action, Case>(
            dynamicMember keyPath: KeyPath<State.AllCasePaths, AnyCasePath<State, Case>>
        ) -> _ViewModelCaseBinding<State, Action, Case>
        where
            Value == ViewModel<State, Action>,
            State: CasePathable
        {
            _ViewModelCaseBinding(
                viewModel: self.wrappedValue,
                casePath: State.allCasePaths[keyPath: keyPath]
            )
        }
    #endif
}

extension Binding {
    /// Accesses projected ViewModel members for creating bindings from a Binding<ViewModel>.
    @MainActor
    public subscript<State: FeatureStateProtocol, Action, Member: Equatable>(
        dynamicMember keyPath: KeyPath<State._ViewMembers, Member>
    ) -> _ViewModelBindingOf<State, Action, Member>
    where
        Value == ViewModel<State, Action>
    {
        let viewModel = self.wrappedValue
        return _ViewModelBinding(
            viewModel: viewModel,
            read: { viewModel[dynamicMember: keyPath] }
        )
    }

    #if canImport(CasePaths)
        /// Accesses ViewModel state case properties for CasePathable state enums from a
        /// Binding<ViewModel>.
        @MainActor
        public subscript<State: FeatureStateProtocol, Action, Case>(
            dynamicMember keyPath: KeyPath<State.AllCasePaths, AnyCasePath<State, Case>>
        ) -> _ViewModelCaseBinding<State, Action, Case>
        where
            Value == ViewModel<State, Action>,
            State: CasePathable
        {
            _ViewModelCaseBinding(
                viewModel: self.wrappedValue,
                casePath: State.allCasePaths[keyPath: keyPath]
            )
        }
    #endif
}

#if canImport(CasePaths)
    /// A wrapper that enables creating SwiftUI bindings from enum-state case associated
    /// values.
    ///
    /// Reads register the root observation slot (coarse: a case flip is a whole-view change).
    @dynamicMemberLookup
    @MainActor
    public struct _ViewModelCaseBinding<State: FeatureStateProtocol, Action, Case>
    where State: CasePathable {
        private let viewModel: ViewModel<State, Action>
        private let casePath: AnyCasePath<State, Case>

        init(
            viewModel: ViewModel<State, Action>,
            casePath: AnyCasePath<State, Case>
        ) {
            self.viewModel = viewModel
            self.casePath = casePath
        }

        /// Accesses nested properties of the case's associated value.
        public subscript<Member>(
            dynamicMember keyPath: KeyPath<Case, Member>
        ) -> _ViewModelCaseMemberBinding<State, Action, Case, Member> {
            _ViewModelCaseMemberBinding(
                viewModel: viewModel,
                casePath: casePath,
                memberKeyPath: keyPath
            )
        }
    }

    /// A wrapper for accessing members of an enum case's associated value.
    @dynamicMemberLookup
    @MainActor
    public struct _ViewModelCaseMemberBinding<State: FeatureStateProtocol, Action, Case, Member>
    where State: CasePathable {
        private let viewModel: ViewModel<State, Action>
        private let casePath: AnyCasePath<State, Case>
        private let memberKeyPath: KeyPath<Case, Member>

        init(
            viewModel: ViewModel<State, Action>,
            casePath: AnyCasePath<State, Case>,
            memberKeyPath: KeyPath<Case, Member>
        ) {
            self.viewModel = viewModel
            self.casePath = casePath
            self.memberKeyPath = memberKeyPath
        }

        /// Accesses nested properties of the current member.
        public subscript<NestedMember>(
            dynamicMember keyPath: KeyPath<Member, NestedMember>
        ) -> _ViewModelCaseMemberBinding<State, Action, Case, NestedMember> {
            _ViewModelCaseMemberBinding<State, Action, Case, NestedMember>(
                viewModel: viewModel,
                casePath: casePath,
                memberKeyPath: memberKeyPath.appending(path: keyPath)
            )
        }

        /// Creates a SwiftUI binding that sends the specified action when the value changes.
        ///
        /// - Warning: This will crash if the state is not in the expected case.
        ///   Use `sending(_:default:)` if the binding may be accessed when in a different
        ///   case.
        @MainActor
        public func sending(_ action: CaseKeyPath<Action, Member>) -> Binding<Member> {
            Binding(
                get: {
                    guard let caseValue = self.casePath.extract(from: self.viewModel._observedState)
                    else {
                        fatalError("Attempted to access \(Case.self) but state is not in that case")
                    }
                    return caseValue[keyPath: self.memberKeyPath]
                },
                set: { newValue in
                    self.viewModel.sendViewEvent(action(newValue))
                }
            )
        }

        /// Creates a SwiftUI binding with a default value when the case doesn't match.
        @MainActor
        public func sending(
            _ action: CaseKeyPath<Action, Member>,
            default defaultValue: Member
        ) -> Binding<Member> {
            Binding(
                get: {
                    guard let caseValue = self.casePath.extract(from: self.viewModel._observedState)
                    else {
                        return defaultValue
                    }
                    return caseValue[keyPath: self.memberKeyPath]
                },
                set: { newValue in
                    guard self.casePath.extract(from: self.viewModel._observedState) != nil else {
                        return
                    }
                    self.viewModel.sendViewEvent(action(newValue))
                }
            )
        }
    }
#endif
