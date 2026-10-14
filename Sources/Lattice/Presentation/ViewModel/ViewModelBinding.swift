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
/// @Bindable var viewModel: ViewModel<Feature<FormAction, FormState>>
///
/// TextField("Name", text: $viewModel.name.sending(\.nameChanged))
/// ```
///
/// Key paths are rooted at `F.State.ViewState`, so a `@Domain` member is rejected at the
/// `$viewModel.member` site.
@dynamicMemberLookup
public struct _ViewModelBinding<F: FeatureProtocol, Value> {
    private let viewModel: ViewModel<F>
    private let keyPath: KeyPath<F.State.ViewState, Value>

    init(
        viewModel: ViewModel<F>,
        keyPath: KeyPath<F.State.ViewState, Value>
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
public typealias _ViewModelBindingOf<F: FeatureProtocol, Value> = _ViewModelBinding<F, Value>

extension Bindable {
    /// Accesses ViewModel state properties for creating bindings.
    public subscript<F: FeatureProtocol, Member>(
        dynamicMember keyPath: KeyPath<F.State.ViewState, Member>
    ) -> _ViewModelBinding<F, Member>
    where
        Value == ViewModel<F>
    {
        _ViewModelBinding(
            viewModel: self.wrappedValue,
            keyPath: keyPath
        )
    }

    #if canImport(CasePaths)
        /// Accesses the case payloads of an enum state for creating bindings.
        ///
        /// Enum case bindings go through the `@CasePathable` mirror `F.State.ViewState`, never
        /// the raw enum, so `@Domain` members of a payload stay hidden.
        public subscript<F: FeatureProtocol, CaseProjection>(
            dynamicMember keyPath: KeyPath<
                F.State.ViewState.AllCasePaths, AnyCasePath<F.State.ViewState, CaseProjection>
            >
        ) -> _ViewModelCaseBinding<F, CaseProjection>
        where
            Value == ViewModel<F>,
            F.State.ViewState: CasePathable
        {
            _ViewModelCaseBinding(
                viewModel: self.wrappedValue,
                casePath: F.State.ViewState.allCasePaths[keyPath: keyPath]
            )
        }
    #endif
}

extension Binding {
    /// Accesses ViewModel state properties for creating bindings from a Binding<ViewModel>.
    public subscript<F: FeatureProtocol, Member>(
        dynamicMember keyPath: KeyPath<F.State.ViewState, Member>
    ) -> _ViewModelBinding<F, Member>
    where
        Value == ViewModel<F>
    {
        _ViewModelBinding(
            viewModel: self.wrappedValue,
            keyPath: keyPath
        )
    }

    #if canImport(CasePaths)
        /// Accesses the case payloads of an enum state for creating bindings from a
        /// Binding<ViewModel>. Goes through the `@CasePathable` mirror `F.State.ViewState`.
        public subscript<F: FeatureProtocol, CaseProjection>(
            dynamicMember keyPath: KeyPath<
                F.State.ViewState.AllCasePaths, AnyCasePath<F.State.ViewState, CaseProjection>
            >
        ) -> _ViewModelCaseBinding<F, CaseProjection>
        where
            Value == ViewModel<F>,
            F.State.ViewState: CasePathable
        {
            _ViewModelCaseBinding(
                viewModel: self.wrappedValue,
                casePath: F.State.ViewState.allCasePaths[keyPath: keyPath]
            )
        }
    #endif
}

#if canImport(CasePaths)
    /// A wrapper that enables creating SwiftUI bindings from the associated value of an enum
    /// state case, as projected by the state's `@CasePathable` mirror `F.State.ViewState`.
    @dynamicMemberLookup
    public struct _ViewModelCaseBinding<F: FeatureProtocol, CaseProjection>
    where F.State.ViewState: CasePathable {
        private let viewModel: ViewModel<F>
        private let casePath: AnyCasePath<F.State.ViewState, CaseProjection>

        init(
            viewModel: ViewModel<F>,
            casePath: AnyCasePath<F.State.ViewState, CaseProjection>
        ) {
            self.viewModel = viewModel
            self.casePath = casePath
        }

        /// Accesses nested properties of the case's associated value.
        public subscript<Member>(
            dynamicMember keyPath: KeyPath<CaseProjection, Member>
        ) -> _ViewModelCaseMemberBinding<F, CaseProjection, Member> {
            _ViewModelCaseMemberBinding(
                viewModel: viewModel,
                casePath: casePath,
                memberKeyPath: keyPath
            )
        }
    }

    /// A wrapper for accessing members of an enum case's associated value.
    @dynamicMemberLookup
    public struct _ViewModelCaseMemberBinding<F: FeatureProtocol, CaseProjection, Member>
    where F.State.ViewState: CasePathable {
        private let viewModel: ViewModel<F>
        private let casePath: AnyCasePath<F.State.ViewState, CaseProjection>
        private let memberKeyPath: KeyPath<CaseProjection, Member>

        init(
            viewModel: ViewModel<F>,
            casePath: AnyCasePath<F.State.ViewState, CaseProjection>,
            memberKeyPath: KeyPath<CaseProjection, Member>
        ) {
            self.viewModel = viewModel
            self.casePath = casePath
            self.memberKeyPath = memberKeyPath
        }

        /// Accesses nested properties of the current member.
        public subscript<NestedMember>(
            dynamicMember keyPath: KeyPath<Member, NestedMember>
        ) -> _ViewModelCaseMemberBinding<F, CaseProjection, NestedMember> {
            _ViewModelCaseMemberBinding<F, CaseProjection, NestedMember>(
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
                        fatalError("Attempted to access \(CaseProjection.self) but viewState is not in that case")
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
