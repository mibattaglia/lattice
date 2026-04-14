import Foundation

struct RootSendOrigin<Action: Sendable>: Sendable {
    let action: Action
    let fileID: StaticString
    let filePath: StaticString
    let line: UInt
    let column: UInt
}
