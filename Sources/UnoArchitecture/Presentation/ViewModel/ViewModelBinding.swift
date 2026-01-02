import CasePaths
import SwiftUI

/// A wrapper that enables creating SwiftUI bindings from ViewModel state properties.
///
/// This type is not created directly. Instead, use the `@Bindable` property wrapper
/// with a ViewModel and access properties via dynamic member lookup:
///
/// ```swift
/// @Bindable var viewModel: ViewModel<Action, State, ViewState>
///
/// TextField("Name", text: $viewModel.name.sending(\.updateName))
/// ```
@dynamicMemberLookup
public struct _ViewModelBinding<Action, DomainState, ViewState, Value>
where Action: Sendable, DomainState: Sendable, ViewState: ObservableState {

    private let viewModel: ViewModel<Action, DomainState, ViewState>
    private let keyPath: KeyPath<ViewState, Value>

    init(
        viewModel: ViewModel<Action, DomainState, ViewState>,
        keyPath: KeyPath<ViewState, Value>
    ) {
        self.viewModel = viewModel
        self.keyPath = keyPath
    }

    /// Accesses nested properties of the current value.
    ///
    /// This allows chaining property access:
    /// ```swift
    /// $viewModel.user.name.sending(\.updateUserName)
    /// ```
    public subscript<Member>(
        dynamicMember keyPath: KeyPath<Value, Member>
    ) -> _ViewModelBinding<Action, DomainState, ViewState, Member> {
        _ViewModelBinding<Action, DomainState, ViewState, Member>(
            viewModel: viewModel,
            keyPath: self.keyPath.appending(path: keyPath)
        )
    }

    /// Creates a SwiftUI binding that sends the specified action when the value changes.
    ///
    /// - Parameter action: A case key path to an action case that takes the new value.
    /// - Returns: A binding suitable for use with SwiftUI controls.
    ///
    /// Example:
    /// ```swift
    /// enum Action {
    ///     case updateName(String)
    /// }
    ///
    /// TextField("Name", text: $viewModel.name.sending(\.updateName))
    /// ```
    @MainActor
    public func sending(_ action: CaseKeyPath<Action, Value>) -> Binding<Value> {
        Binding(
            get: { self.viewModel.viewState[keyPath: self.keyPath] },
            set: { newValue in
                self.viewModel.sendViewEvent(action(newValue))
            }
        )
    }
}

extension Bindable {
    /// Accesses ViewModel state properties for creating bindings.
    ///
    /// Use this with the `@Bindable` property wrapper to create bindings:
    ///
    /// ```swift
    /// @Bindable var viewModel: ViewModel<Action, State, ViewState>
    ///
    /// TextField("Query", text: $viewModel.searchQuery.sending(\.search.query))
    /// ```
    @_disfavoredOverload
    public subscript<Action, DomainState, ViewState, Member>(
        dynamicMember keyPath: KeyPath<ViewState, Member>
    ) -> _ViewModelBinding<Action, DomainState, ViewState, Member>
    where
        Value == ViewModel<Action, DomainState, ViewState>,
        Action: Sendable,
        DomainState: Sendable,
        ViewState: ObservableState
    {
        _ViewModelBinding(
            viewModel: self.wrappedValue,
            keyPath: keyPath
        )
    }

    /// Accesses ViewModel state case properties for CasePathable enums.
    ///
    /// Use this with the `@Bindable` property wrapper to create bindings to enum case values:
    ///
    /// ```swift
    /// @Bindable var viewModel: ViewModel<Action, State, ViewState>
    ///
    /// TextField("Query", text: $viewModel.loaded.query.sending(\.search.query))
    /// ```
    public subscript<Action, DomainState, ViewState, Case>(
        dynamicMember keyPath: KeyPath<ViewState.AllCasePaths, AnyCasePath<ViewState, Case>>
    ) -> _ViewModelCaseBinding<Action, DomainState, ViewState, Case>
    where
        Value == ViewModel<Action, DomainState, ViewState>,
        Action: Sendable,
        DomainState: Sendable,
        ViewState: ObservableState & CasePathable
    {
        _ViewModelCaseBinding(
            viewModel: self.wrappedValue,
            casePath: ViewState.allCasePaths[keyPath: keyPath]
        )
    }
}

/// A wrapper that enables creating SwiftUI bindings from ViewModel enum case associated values.
@dynamicMemberLookup
public struct _ViewModelCaseBinding<Action, DomainState, ViewState, Case>
where Action: Sendable, DomainState: Sendable, ViewState: ObservableState & CasePathable {

    private let viewModel: ViewModel<Action, DomainState, ViewState>
    private let casePath: AnyCasePath<ViewState, Case>

    init(
        viewModel: ViewModel<Action, DomainState, ViewState>,
        casePath: AnyCasePath<ViewState, Case>
    ) {
        self.viewModel = viewModel
        self.casePath = casePath
    }

    /// Accesses nested properties of the case's associated value.
    public subscript<Member>(
        dynamicMember keyPath: KeyPath<Case, Member>
    ) -> _ViewModelCaseMemberBinding<Action, DomainState, ViewState, Case, Member> {
        _ViewModelCaseMemberBinding(
            viewModel: viewModel,
            casePath: casePath,
            memberKeyPath: keyPath
        )
    }
}

/// A wrapper for accessing members of an enum case's associated value.
@dynamicMemberLookup
public struct _ViewModelCaseMemberBinding<Action, DomainState, ViewState, Case, Member>
where Action: Sendable, DomainState: Sendable, ViewState: ObservableState & CasePathable {

    private let viewModel: ViewModel<Action, DomainState, ViewState>
    private let casePath: AnyCasePath<ViewState, Case>
    private let memberKeyPath: KeyPath<Case, Member>

    init(
        viewModel: ViewModel<Action, DomainState, ViewState>,
        casePath: AnyCasePath<ViewState, Case>,
        memberKeyPath: KeyPath<Case, Member>
    ) {
        self.viewModel = viewModel
        self.casePath = casePath
        self.memberKeyPath = memberKeyPath
    }

    /// Accesses nested properties of the current member.
    public subscript<NestedMember>(
        dynamicMember keyPath: KeyPath<Member, NestedMember>
    ) -> _ViewModelCaseMemberBinding<Action, DomainState, ViewState, Case, NestedMember> {
        _ViewModelCaseMemberBinding<Action, DomainState, ViewState, Case, NestedMember>(
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
    public func sending(_ action: CaseKeyPath<Action, Member>) -> Binding<Member> {
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
    ///
    /// Use this when the binding may be accessed while the viewState is in a different case.
    /// The default value is returned by the getter, and the setter is a no-op when not in the expected case.
    ///
    /// Example:
    /// ```swift
    /// // Safe to use even when viewState might be .none
    /// TextField("Query", text: $viewModel.loaded.query.sending(\.search.query, default: ""))
    /// ```
    @MainActor
    public func sending(_ action: CaseKeyPath<Action, Member>, default defaultValue: Member) -> Binding<Member> {
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
