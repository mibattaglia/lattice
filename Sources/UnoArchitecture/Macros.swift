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
