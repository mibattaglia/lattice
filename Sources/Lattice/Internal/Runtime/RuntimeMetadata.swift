// Copied from TCA 2 (`ComposableArchitecture2/Internal/Runtime/RuntimeMetadata.swift`), re-indented.

enum MetadataKind {
    static let structure = 0x200
    static let `enum` = 0x201
    static let optional = 0x202
}

struct FieldDescriptor {
    let ptr: UnsafeRawPointer

    var recordSize: Int {
        Int(ptr.advanced(by: 2 * 4 + 2).load(as: UInt16.self))
    }

    var numberOfFields: Int {
        Int(ptr.advanced(by: 2 * 4 + 2 * 2).load(as: UInt32.self))
    }

    func field(atIndex index: Int) -> FieldRecord {
        FieldRecord(
            ptr: ptr.advanced(by: 2 * 4 + 2 * 2 + 4).advanced(by: Int(index) * recordSize)
        )
    }
}

struct FieldRecord {
    let ptr: UnsafeRawPointer

    var typeName: MangledTypeName? {
        ptr.advanced(by: 4).loadRelativePointer().map {
            MangledTypeName(ptr: $0.assumingMemoryBound(to: UInt8.self))
        }
    }

    var name: String? {
        ptr.advanced(by: 8).loadRelativePointer().map {
            String(cString: $0.assumingMemoryBound(to: CChar.self))
        }
    }
}

struct MangledTypeName {
    let ptr: UnsafePointer<UInt8>

    var length: Int {
        var ptr = self.ptr
        while true {
            switch ptr.pointee {
            case 0:
                return ptr - self.ptr
            case 0x01...0x17:
                ptr = ptr.advanced(by: 5)
            case 0x18...0x1f:
                ptr = ptr.advanced(by: 1 + pointerSize)
            default:
                ptr = ptr.advanced(by: 1)
            }
        }
    }
}

struct GenericArgumentVector {
    let ptr: UnsafeRawPointer
}

extension UnsafeRawPointer {
    func loadRelativePointer() -> UnsafeRawPointer? {
        let offset = Int(load(as: Int32.self))
        return offset == 0 ? nil : self + offset
    }
}

let pointerSize = MemoryLayout<UnsafeRawPointer>.size
