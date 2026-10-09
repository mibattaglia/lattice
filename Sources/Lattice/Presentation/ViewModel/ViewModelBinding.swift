import SwiftUI

#if canImport(CasePaths)
    import CasePaths
#endif

/// A wrapper that enables creating SwiftUI bindings from ViewModel state properties.
///
/// This type is not created directly. Instead, use the `@Bindable` property wrapper
/// with a view model and access properties via dynamic member lookup:
///
/// ```swift
/// @Bindable var viewModel: ViewModel<Feature<FormAction, FormState, FormViewState>>
///
/// TextField("Name", text: $viewModel.name.sending(\.nameChanged))
/// ```
@dynamicMemberLookup
public struct _ViewModelBinding<F: FeatureProtocol, Value> where F.ViewState: ObservableState {
    private let viewModel: ViewModel<F>
    private let keyPath: KeyPath<F.ViewState, Value>

    init(
        viewModel: ViewModel<F>,
        keyPath: KeyPath<F.ViewState, Value>
    ) {
        self.viewModel = viewModel
        self.keyPath = keyPath
    }

    /// Accesses nested properties of the current value.
    public subscript<Member>(
        dynamicMember keyPath: KeyPath<Value, Member>
    ) -> _ViewModelBinding<F, Member> {
        _ViewModelBinding<F, Member>(
            viewModel: viewModel,
            keyPath: self.keyPath.appending(path: keyPath)
        )
    }

    /// Creates a SwiftUI binding that sends the specified action when the value changes.
    #if canImport(CasePaths)
        @MainActor
        public func sending(_ action: CaseKeyPath<F.Action, Value>) -> Binding<Value> {
            Binding(
                get: { self.viewModel.viewState[keyPath: self.keyPath] },
                set: { newValue in
                    self.viewModel.sendViewEvent(action(newValue))
                }
            )
        }
    #endif
}

/// A convenience alias for ``_ViewModelBinding`` that is parameterized by feature type.
public typealias _ViewModelBindingOf<F: FeatureProtocol, Value> = _ViewModelBinding<F, Value> where F.ViewState: ObservableState

extension Bindable {
    /// Accesses ViewModel state properties for creating bindings.
    public subscript<F: FeatureProtocol, Member>(
        dynamicMember keyPath: KeyPath<F.ViewState, Member>
    ) -> _ViewModelBindingOf<F, Member>
    where
        Value == ViewModel<F>, F.ViewState: ObservableState
    {
        _ViewModelBinding(
            viewModel: self.wrappedValue,
            keyPath: keyPath
        )
    }

    #if canImport(CasePaths)
        /// Accesses ViewModel state case properties for CasePathable enums.
        public subscript<F: FeatureProtocol, Case>(
            dynamicMember keyPath: KeyPath<F.ViewState.AllCasePaths, AnyCasePath<F.ViewState, Case>>
        ) -> _ViewModelCaseBinding<F, Case>
        where
            Value == ViewModel<F>,
            F.ViewState: ObservableState & CasePathable
        {
            _ViewModelCaseBinding(
                viewModel: self.wrappedValue,
                casePath: F.ViewState.allCasePaths[keyPath: keyPath]
            )
        }
    #endif
}

extension Binding {
    /// Accesses ViewModel state properties for creating bindings from a Binding<ViewModel>.
    public subscript<F: FeatureProtocol, Member>(
        dynamicMember keyPath: KeyPath<F.ViewState, Member>
    ) -> _ViewModelBindingOf<F, Member>
    where
        Value == ViewModel<F>, F.ViewState: ObservableState
    {
        _ViewModelBinding(
            viewModel: self.wrappedValue,
            keyPath: keyPath
        )
    }

    #if canImport(CasePaths)
        /// Accesses ViewModel state case properties for CasePathable enums from a Binding<ViewModel>.
        public subscript<F: FeatureProtocol, Case>(
            dynamicMember keyPath: KeyPath<F.ViewState.AllCasePaths, AnyCasePath<F.ViewState, Case>>
        ) -> _ViewModelCaseBinding<F, Case>
        where
            Value == ViewModel<F>,
            F.ViewState: ObservableState & CasePathable
        {
            _ViewModelCaseBinding(
                viewModel: self.wrappedValue,
                casePath: F.ViewState.allCasePaths[keyPath: keyPath]
            )
        }
    #endif
}

#if canImport(CasePaths)
    /// A wrapper that enables creating SwiftUI bindings from ViewModel enum case associated values.
    @dynamicMemberLookup
    public struct _ViewModelCaseBinding<F: FeatureProtocol, Case>
    where F.ViewState: ObservableState & CasePathable {
        private let viewModel: ViewModel<F>
        private let casePath: AnyCasePath<F.ViewState, Case>

        init(
            viewModel: ViewModel<F>,
            casePath: AnyCasePath<F.ViewState, Case>
        ) {
            self.viewModel = viewModel
            self.casePath = casePath
        }

        /// Accesses nested properties of the case's associated value.
        public subscript<Member>(
            dynamicMember keyPath: KeyPath<Case, Member>
        ) -> _ViewModelCaseMemberBinding<F, Case, Member> {
            _ViewModelCaseMemberBinding(
                viewModel: viewModel,
                casePath: casePath,
                memberKeyPath: keyPath
            )
        }
    }

    /// A wrapper for accessing members of an enum case's associated value.
    @dynamicMemberLookup
    public struct _ViewModelCaseMemberBinding<F: FeatureProtocol, Case, Member>
    where F.ViewState: ObservableState & CasePathable {
        private let viewModel: ViewModel<F>
        private let casePath: AnyCasePath<F.ViewState, Case>
        private let memberKeyPath: KeyPath<Case, Member>

        init(
            viewModel: ViewModel<F>,
            casePath: AnyCasePath<F.ViewState, Case>,
            memberKeyPath: KeyPath<Case, Member>
        ) {
            self.viewModel = viewModel
            self.casePath = casePath
            self.memberKeyPath = memberKeyPath
        }

        /// Accesses nested properties of the current member.
        public subscript<NestedMember>(
            dynamicMember keyPath: KeyPath<Member, NestedMember>
        ) -> _ViewModelCaseMemberBinding<F, Case, NestedMember> {
            _ViewModelCaseMemberBinding<F, Case, NestedMember>(
                viewModel: viewModel,
                casePath: casePath,
                memberKeyPath: memberKeyPath.appending(path: keyPath)
            )
        }

        /// Creates a SwiftUI binding that sends the specified action when the value changes.
        ///
        /// - Warning: This will crash if the viewState is not in the expected case.
        ///   Use `sending(_:default:)` if the binding may be accessed when in a different case.
        @MainActor
        public func sending(_ action: CaseKeyPath<F.Action, Member>) -> Binding<Member> {
            Binding(
                get: {
                    guard let caseValue = self.casePath.extract(from: self.viewModel.viewState) else {
                        fatalError("Attempted to access \(Case.self) but viewState is not in that case")
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
        public func sending(_ action: CaseKeyPath<F.Action, Member>, default defaultValue: Member) -> Binding<Member> {
            Binding(
                get: {
                    guard let caseValue = self.casePath.extract(from: self.viewModel.viewState) else {
                        return defaultValue
                    }
                    return caseValue[keyPath: self.memberKeyPath]
                },
                set: { newValue in
                    guard self.casePath.extract(from: self.viewModel.viewState) != nil else {
                        return
                    }
                    self.viewModel.sendViewEvent(action(newValue))
                }
            )
        }
    }

#endif

/// Filtered leaf binding for the temporary tracked Feature host. It deliberately
/// has no unrestricted nested dynamic-member forwarding.
public struct _FeatureStateViewModelBinding<F: FeatureProtocol, Value>
where F.DomainState: FeatureStateProtocol, F.ViewState == _FeatureStatePresentation {
    private let model: ViewModel<F>
    private let member: KeyPath<F.DomainState._ViewMembers, FeatureStateValueMember<F.DomainState, Value>>

    init(model: ViewModel<F>, member: KeyPath<F.DomainState._ViewMembers, FeatureStateValueMember<F.DomainState, Value>>) {
        self.model = model
        self.member = member
    }

    @MainActor
    public func sending(_ embed: @escaping @MainActor (Value) -> F.Action) -> Binding<Value> {
        model.binding(member, sending: embed)
    }

    #if canImport(CasePaths)
        @MainActor
        public func sending(_ embed: CaseKeyPath<F.Action, Value>) -> Binding<Value> {
            model.binding(member, sending: { embed($0) })
        }
    #endif
}

extension Bindable {
    public subscript<F: FeatureProtocol, Member>(
        dynamicMember member: KeyPath<F.DomainState._ViewMembers, FeatureStateValueMember<F.DomainState, Member>>
    ) -> _FeatureStateViewModelBinding<F, Member>
    where Value == ViewModel<F>, F.DomainState: FeatureStateProtocol, F.ViewState == _FeatureStatePresentation {
        _FeatureStateViewModelBinding(model: wrappedValue, member: member)
    }
}

extension Binding {
    public subscript<F: FeatureProtocol, Member>(
        dynamicMember member: KeyPath<F.DomainState._ViewMembers, FeatureStateValueMember<F.DomainState, Member>>
    ) -> _FeatureStateViewModelBinding<F, Member>
    where Value == ViewModel<F>, F.DomainState: FeatureStateProtocol, F.ViewState == _FeatureStatePresentation {
        _FeatureStateViewModelBinding(model: wrappedValue, member: member)
    }
}
