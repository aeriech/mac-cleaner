// Checks which Library items Leftovers reports, and which it marks "Check first". Build & run:
//   swiftc -parse-as-library $(ls Sources/*.swift | grep -v Main.swift) Tools/Leftovers.test.swift -o build/leftovers-test && build/leftovers-test
import Foundation

@main
struct LeftoversTest {
    static func main() {
        let fm = FileManager.default
        let lib = homePath("Library/Caches/maccleaner-leftovers-test-\(UUID().uuidString)")   // a fake Library
        defer { try? fm.removeItem(atPath: lib) }
        func put(_ rel: String) {
            let path = join(lib, rel)
            try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            precondition(fm.createFile(atPath: path, contents: Data(repeating: 1, count: 20_000)))
        }
        // A removed app with helpers: one ticked row (like Teams' five containers + helper prefs).
        put("Containers/com.qa-orphan.app/Data/x")
        put("Containers/com.qa-orphan.app.agent/Data/x")
        put("Preferences/com.qa-orphan.app.helper.plist")
        // A shared container from a removed app: Group Containers are scanned too.
        put("Group Containers/AB12CD34EF.com.qa-orphan.shared/x")
        // Same developer as an installed app: possibly shared, so "Check first" and unticked (Teams vs VS Code).
        put("Containers/com.qa-vendor.otherapp/Data/x")
        // A helper of the installed app itself: owned, never reported.
        put("Caches/com.qa-vendor.installedapp.ShipIt/x")
        // An Electron app's data folder + its update download, named after the app (Polly Teach).
        put("Application Support/qa-fixture-electron-client/Preferences")
        put("Application Support/qa-fixture-electron-client/GPUCache/data_0")
        put("Application Support/Caches/qa-fixture-electron-client-updater/pending/update.zip")
        // Not reported: a folder without Electron's layout, and Apple's own data.
        put("Application Support/qa-fixture-plain-folder/data.bin")
        put("Group Containers/group.com.apple.qa-fixture/x")

        let found = findLeftovers(alsoInstalled: ["com.qa-vendor.installedapp"], library: lib)
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.identifier, $0) })
        precondition(Set(byID.keys) == ["com.qa-orphan.app", "com.qa-orphan.shared", "com.qa-vendor.otherapp", "qa-fixture-electron-client"],
                     "reported: \(byID.keys.sorted())")
        let orphan = byID["com.qa-orphan.app"]!
        precondition(orphan.paths.count == 3 && orphan.note == nil && orphan.selected, "orphan app: \(orphan)")
        precondition(byID["com.qa-orphan.shared"]!.note == nil, "shared container should be a sure leftover")
        let vendorItem = byID["com.qa-vendor.otherapp"]!
        precondition(vendorItem.note != nil && !vendorItem.selected, "same-developer item must be 'Check first' and unticked")
        let electron = byID["qa-fixture-electron-client"]!
        precondition(electron.paths.count == 2 && electron.note != nil && !electron.selected, "Electron leftover: \(electron)")
        precondition(found.first?.note == nil, "sure leftovers should be listed before ones to check")
        print("Leftovers test OK (\(found.count) reported, \(found.filter { $0.note != nil }.count) to check)")
    }
}
