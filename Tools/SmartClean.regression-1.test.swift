// Regression: ISSUE-009 — Clean silently skipped items it couldn't delete (locked, read-only, system-owned),
// so the Trash looked "not emptied" while the app reported success.
// Found while debugging a user report on 2026-10-20.
//   swiftc -parse-as-library $(ls Sources/*.swift | grep -v Main.swift) Tools/SmartClean.regression-1.test.swift -o build/smartclean-regression && build/smartclean-regression
import Foundation

@main
struct SmartCleanRegression {
    @MainActor static func main() async {
        let fm = FileManager.default
        // Must live under home: clean() refuses to touch anything outside it.
        let dir = homePath(".maccleaner-qa-test-\(UUID().uuidString)")
        try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer {
            _ = runTool("/usr/bin/chflags", ["-R", "nouchg", dir])
            _ = runTool("/bin/chmod", ["-R", "u+w", dir])
            try? fm.removeItem(atPath: dir)
        }

        fm.createFile(atPath: join(dir, "normal.bin"), contents: Data(repeating: 1, count: 50_000))
        let locked = join(dir, "locked.bin")                       // Finder "Locked" checkbox
        fm.createFile(atPath: locked, contents: Data(repeating: 2, count: 50_000))
        try! fm.setAttributes([.immutable: true], ofItemAtPath: locked)
        let readOnly = join(dir, "read-only-folder")                // e.g. Go module cache, trashed app bundles
        try! fm.createDirectory(atPath: readOnly, withIntermediateDirectories: true)
        fm.createFile(atPath: join(readOnly, "inside.bin"), contents: Data(repeating: 3, count: 50_000))
        try! fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly)

        let model = CleanModel()
        model.cats = [JunkCategory(id: "qa", name: "QA", detail: "", icon: "trash", kind: .contents(dir))]
        await model.scan()
        await model.clean()

        let left = listDir(dir)
        precondition(left.isEmpty, "Clean left \(left.sorted()) behind; notice said: \(model.notice?.text ?? "nil")")
        precondition(model.notice?.ok == true, "notice should report success: \(model.notice?.text ?? "nil")")
        print("SmartClean regression OK (\(model.notice!.text))")
    }
}
