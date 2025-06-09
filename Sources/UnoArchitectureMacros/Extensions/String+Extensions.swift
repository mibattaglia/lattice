extension [String] {
    var moduleQualified: Self {
        self.flatMap { [$0, "UnoArchitecture.\($0)"] }
    }
}
