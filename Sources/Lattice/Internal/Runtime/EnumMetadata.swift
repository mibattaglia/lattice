// Copied from TCA 2 (`ComposableArchitecture2/Internal/Runtime/EnumMetadata.swift`), re-indented.
// Removed: the CasePaths import, `_caseName(of:)`, and the `LockIsolated` case-name cache with
// `_enumCaseName(of:)` and `_enumCaseNames(of:)`. `_enumTag` reads only the metadata kind and the
// value witness table's `getEnumTag`, so no C shim is needed.

struct _EnumTag: Hashable {
    let rawValue: UInt32
}

func _enumTag<Value>(of value: Value) -> _EnumTag? {
    guard let metadata = _enumMetadata(type(of: value))
    else { return nil }
    return _EnumTag(rawValue: metadata.tag(of: value))
}

private func _enumMetadata<Root>(_ root: Root.Type) -> _EnumMetadata? {
    _EnumMetadata(root)
}

private struct _EnumMetadata {
    let ptr: UnsafeRawPointer

    init?<Root>(_ root: Root.Type) {
        let ptr = unsafeBitCast(root, to: UnsafeRawPointer.self)
        let kind = ptr.load(as: Int.self)
        guard kind == MetadataKind.`enum` || kind == MetadataKind.optional
        else { return nil }
        self.ptr = ptr
    }

    var valueWitnessTable: UnsafeRawPointer {
        ptr
            .advanced(by: -MemoryLayout<UnsafeRawPointer>.size)
            .load(as: UnsafeRawPointer.self)
    }

    var getEnumTag: @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UInt32 {
        valueWitnessTable
            .advanced(by: MemoryLayout<UnsafeRawPointer>.size * 8)
            .advanced(by: MemoryLayout<Int>.size * 2)
            .advanced(by: MemoryLayout<UInt32>.size * 2)
            .load(as: (@convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UInt32).self)
    }

    var typeDescriptor: EnumTypeDescriptor {
        EnumTypeDescriptor(
            ptr: ptr.load(fromByteOffset: pointerSize, as: UnsafeRawPointer.self)
        )
    }

    func tag<Value>(of value: Value) -> UInt32 {
        withUnsafePointer(to: value) { getEnumTag($0, ptr) }
    }
}

private struct EnumTypeDescriptor {
    let ptr: UnsafeRawPointer

    var fieldDescriptor: FieldDescriptor? {
        ptr.advanced(by: 4 * 4).loadRelativePointer().map(FieldDescriptor.init)
    }
}
