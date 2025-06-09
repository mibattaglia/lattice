extension [String] {
    var moduleQualified: Self {
        self.flatMap { [$0, "DomainArchitecture.\($0)"] }
    }
}
