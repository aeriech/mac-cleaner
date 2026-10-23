// Checks the logic that decides what gets deleted. Build & run:
//   swiftc -parse-as-library $(ls Sources/*.swift | grep -v Main.swift) Tools/SelfTest.swift -o build/selftest && build/selftest
import Foundation

@main
struct SelfTest {
    static func main() {
        // Leftover matching relies on these.
        precondition(bundleStem("com.Foo.App.plist") == "com.foo.app")
        precondition(bundleStem("com.foo.app.savedState") == "com.foo.app")
        precondition(looksLikeBundleID("com.foo.app"))
        precondition(!looksLikeBundleID("com.foo"))
        precondition(!looksLikeBundleID(".GlobalPreferences"))
        precondition(!looksLikeBundleID("My App Data"))
        precondition(vendor("com.google.chrome") == "com.google")
        precondition(!looksLikeBundleID("classpod-rtc-com.liteav.storage"))
        precondition(canonicalID("group.com.apple.mail") == "com.apple.mail")
        precondition(canonicalID("s8ex82njp6.com.macpaw.cleanmymac") == "com.macpaw.cleanmymac")
        precondition(canonicalID("243lu875e5.groups.com.apple.podcasts") == "com.apple.podcasts")
        precondition(canonicalID("salesforce.com.app") == "salesforce.com.app")   // 10 letters, no digits: not a team ID

        // Regression: ISSUE-003 — RAM showed as "17.18 GB" on a 16 GB Mac (disk units). Found by /qa on 2026-10-20.
        precondition(fmtMemory(17_179_869_184) == "16 GB", "RAM shown as \(fmtMemory(17_179_869_184))")
        precondition(fmt(245_107_195_904) == "245.11 GB")   // disks keep Finder's decimal units

        // Duplicates must be byte-identical: same size but one differing byte is not a duplicate.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("maccleaner-selftest-\(UUID().uuidString)")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let same = Data(repeating: 7, count: 300_000)
        var different = same
        different[different.count - 1] = 8
        try! same.write(to: dir.appendingPathComponent("a.bin"))
        try! same.write(to: dir.appendingPathComponent("b.bin"))
        try! different.write(to: dir.appendingPathComponent("c.bin"))
        let groups = findDuplicates(in: [dir.path])
        precondition(groups.count == 1, "expected 1 duplicate group, got \(groups.count)")
        precondition(Set(groups[0].paths.map(fileName)) == ["a.bin", "b.bin"], "wrong files grouped: \(groups[0].paths)")

        print("selftest OK")
    }
}
