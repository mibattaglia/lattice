// Overload resolution of `_$project` is the leaf/child classification used by `@FeatureState`
// generated code; the macro never inspects types. The constrained overloads are preferred
// whenever they apply.

@inlinable public func _$project<T>(_ value: T) -> T { value }
public func _$project<T: FeatureState>(_ value: T) -> T.ViewState { .init(value) }
public func _$project<T: FeatureState>(_ value: T?) -> T.ViewState? { value.map(T.ViewState.init) }
public func _$project<C: RandomAccessCollection>(_ value: C) -> ViewStateCollection<C>
where C.Element: FeatureState { .init(value) }

/// Inverse of `_$project`, used by enum mirrors to rebuild `_state`. The explicit target type
/// makes exactly one overload viable even when a payload is itself some `X.ViewState`.
@inlinable public func _$unproject<T>(_ value: T, to _: T.Type) -> T { value }
public func _$unproject<P: ViewStateProjection>(_ value: P, to _: P.State.Type) -> P.State { value._state }
public func _$unproject<P: ViewStateProjection>(_ value: P?, to _: P.State?.Type) -> P.State? { value?._state }
public func _$unproject<C: RandomAccessCollection>(_ value: ViewStateCollection<C>, to _: C.Type) -> C
where C.Element: FeatureState { value._base }

/// Type witness for associated-type inference in generated code. Never executed.
public func _$placeholder<T>(_: T.Type) -> T { fatalError("_$placeholder is a type witness and must not be called") }
