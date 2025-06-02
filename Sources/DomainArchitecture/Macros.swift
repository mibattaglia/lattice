@attached(
    member,
    names:
        named(body)
)
@attached(memberAttribute)
@attached(extension, conformances: Interactor)
public macro Interactor() = #externalMacro(module: "DomainArchitectureMacros", type: "InteractorMacro")
