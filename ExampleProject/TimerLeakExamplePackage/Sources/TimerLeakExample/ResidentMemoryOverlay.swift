import SwiftUI

#if canImport(Darwin)
import Darwin
#endif

/// Samples resident memory once per second so the A/B leak profile can be done
/// without Instruments. Reads `mach_task_basic_info().resident_size`.
struct ResidentMemoryOverlay: View {
    @State private var residentMB: Double = 0

    var body: some View {
        HStack {
            Image(systemName: "memorychip")
            Text("Resident: \(residentMB, specifier: "%.1f") MB")
                .font(.system(.headline, design: .monospaced))
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .task {
            let clock = ContinuousClock()
            while !Task.isCancelled {
                residentMB = Self.residentMemoryBytes().map { Double($0) / 1_048_576 } ?? 0
                try? await clock.sleep(for: .seconds(1))
            }
        }
    }

    private static func residentMemoryBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : nil
        #else
        return nil
        #endif
    }
}
