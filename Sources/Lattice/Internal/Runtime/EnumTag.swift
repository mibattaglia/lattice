/// The tag of `value`'s enum case: payload-independent and stable per case, but not the
/// declaration order. A value that is not an enum has no tag and gets `-1`, so a non-enum `Action`
/// puts every action on one path and re-sending any action cancels all anonymous effects.
///
/// Reads the type's runtime metadata as the Swift ABI lays it out. The metadata starts with its
/// kind: `0x201` for an enum, `0x202` for `Optional`. The pointer just before it is the value
/// witness table, whose enum entries follow its 8 function pointers, `size`, `stride`, `flags` and
/// `extraInhabitantCount`; the first of them is `getEnumTag(value, metadata)`.
func enumTag<Value>(_ value: Value) -> Int {
    let metadata = unsafeBitCast(type(of: value), to: UnsafeRawPointer.self)
    let kind = metadata.load(as: Int.self)
    guard kind == 0x201 || kind == 0x202 else { return -1 }
    let valueWitnessTable = metadata.load(
        fromByteOffset: -MemoryLayout<UnsafeRawPointer>.size,
        as: UnsafeRawPointer.self
    )
    let getEnumTagOffset =
        MemoryLayout<UnsafeRawPointer>.size * 8 + MemoryLayout<Int>.size * 2 + MemoryLayout<UInt32>.size * 2
    let getEnumTag = valueWitnessTable.load(
        fromByteOffset: getEnumTagOffset,
        as: (@convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UInt32).self
    )
    return withUnsafePointer(to: value) { Int(getEnumTag($0, metadata)) }
}
