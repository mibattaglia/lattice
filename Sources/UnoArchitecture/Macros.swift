@attached(
    member,
    names:
        named(body),
    named(Action),
    named(DomainState)
)
@attached(memberAttribute)
@attached(extension, conformances: Interactor)
public macro Interactor() = #externalMacro(module: "UnoArchitectureMacros", type: "InteractorMacro")

@attached(
    member,
    names:
        named(body),
    named(DomainState),
    named(ViewState)
)
@attached(memberAttribute)
@attached(extension, conformances: ViewStateReducer)
public macro ViewStateReducer() = #externalMacro(module: "UnoArchitectureMacros", type: "ViewStateReducerMacro")

@attached(
    member,
    names:
        named(viewState),
    named(viewEvents),
    named(sendViewEvent)
)
@attached(extension, conformances: ViewModel)
public macro ViewModel<ViewStateType, ViewEventType>() =
    #externalMacro(module: "UnoArchitectureMacros", type: "ViewModelMacro")

@freestanding(expression)
public macro subscribe<SchedulerType, I: Interactor, V: ViewStateReducer>(
    _ scheduler: SchedulerType,
    _ interactor: I,
    _ viewStateReducer: V
) = #externalMacro(module: "UnoArchitectureMacros", type: "SubscribeMacro")

@freestanding(expression)
public macro subscribeSimple<SchedulerType, I: Interactor>(
    _ scheduler: SchedulerType,
    _ interactor: I
) = #externalMacro(module: "UnoArchitectureMacros", type: "SubscribeSimpleMacro")
