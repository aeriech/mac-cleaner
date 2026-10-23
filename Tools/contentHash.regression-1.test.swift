// Regression: ISSUE-001 — hashing a large file kept every read chunk in memory until the scan ended
// Found by /qa on 2026-10-20
// Report: .gstack/qa-reports/qa-report-mac-cleaner-2026-10-20.md
//   swiftc -parse-as-library $(ls Sources/*.swift | grep -v Main.swift) Tools/contentHash.regression-1.test.swift -o build/contentHash-regression && build/contentHash-regression
import Foundation

func peakFootprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(kr == KERN_SUCCESS)
    return info.ledger_phys_footprint_peak
}

@main
struct ContentHashRegression {
    static func main() {
        // 1 GB sparse file: costs no disk space, reads back as zeros.
        let path = NSTemporaryDirectory() + "maccleaner-qa-hash-\(UUID().uuidString).bin"
        precondition(FileManager.default.createFile(atPath: path, contents: nil))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let handle = FileHandle(forWritingAtPath: path)!
        try! handle.truncate(atOffset: 1_000_000_000)
        try! handle.close()

        let before = peakFootprint()
        precondition(contentHash(path) != nil)
        let grew = peakFootprint() - before
        precondition(grew < 200_000_000, "hashing a 1 GB file raised peak memory by \(grew / 1_000_000) MB")
        print("contentHash regression OK (+\(grew / 1_000_000) MB peak for 1 GB)")
    }
}
