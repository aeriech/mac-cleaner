// Checks App Data's scan (cache detection, Apple exclusion, protected folders) and that clearing keeps
// everything that isn't cache. Build & run:
//   swiftc -parse-as-library $(ls Sources/*.swift | grep -v Main.swift) Tools/AppData.test.swift -o build/appdata-test && build/appdata-test
import Foundation

@main
struct AppDataTest {
    @MainActor static func main() async {
        let fm = FileManager.default
        // A fake Library, inside the real ~/Library on purpose: clearing refuses anything outside it.
        let lib = homePath("Library/Caches/maccleaner-appdata-test-\(UUID().uuidString)")
        let locked = join(lib, "Containers/com.example.qa-locked")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
            try? fm.removeItem(atPath: lib)
        }
        func put(_ rel: String) {
            let path = join(lib, rel)
            try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            precondition(fm.createFile(atPath: path, contents: Data(repeating: 1, count: 20_000)))
        }

        // Telegram (App Store): downloaded media is cache, the message database is not.
        put("Group Containers/AB12CD34EF.ru.keepcoder.Telegram/appstore/account-1/postbox/media/video.mp4")
        put("Group Containers/AB12CD34EF.ru.keepcoder.Telegram/appstore/account-1/postbox/db/db_sqlite")
        // Electron app: Chromium caches are cache, user settings are not.
        put("Application Support/FakeElectronApp/Cache/Cache_Data/data_0")
        put("Application Support/FakeElectronApp/Code Cache/js/index")
        put("Application Support/FakeElectronApp/GPUCache/data_1")
        put("Application Support/FakeElectronApp/User/settings.json")
        // Sandboxed app: its Library/Caches is cache, its documents are not.
        put("Containers/com.example.qa-sandboxed/Data/Library/Caches/blob")
        put("Containers/com.example.qa-sandboxed/Data/Documents/notes.txt")
        // No cache at all; Apple's own data (left out); a folder macOS won't let us read.
        put("Application Support/PlainApp/data.bin")
        put("Group Containers/group.com.apple.qa-fixture/data.bin")
        put("Containers/com.example.qa-locked/Data/data.bin")
        try! fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)

        let scan = scanAppData(library: lib, minSize: 0)
        let byFolder = Dictionary(uniqueKeysWithValues: scan.entries.map { (fileName($0.path), $0) })
        func caches(_ folder: String) -> Set<String> {
            Set(byFolder[folder]!.caches.map { String($0.path.dropFirst(byFolder[folder]!.path.count + 1)) })
        }
        precondition(Set(byFolder.keys) == ["AB12CD34EF.ru.keepcoder.Telegram", "FakeElectronApp", "com.example.qa-sandboxed", "PlainApp"],
                     "listed: \(byFolder.keys.sorted())")
        precondition(scan.blocked == 1, "protected folders counted: \(scan.blocked)")
        precondition(caches("AB12CD34EF.ru.keepcoder.Telegram") == ["appstore/account-1/postbox/media"], "Telegram")
        precondition(caches("FakeElectronApp") == ["Cache", "Code Cache", "GPUCache"], "Electron")
        precondition(caches("com.example.qa-sandboxed") == ["Data/Library/Caches"], "Sandboxed")
        precondition(caches("PlainApp").isEmpty, "Plain app")

        // Clearing empties the cache folders (keeping them) and leaves every other file alone.
        // bundleID is cleared so the test can never quit a real app (e.g. your Telegram).
        let model = AppDataModel()
        model.entries = scan.entries.map { e in
            AppDataEntry(path: e.path, name: fileName(e.path), bundleID: nil, appPath: nil, place: e.place,
                         size: e.size, caches: e.caches, hint: nil, selected: true)
        }
        await model.clean()
        for cache in ["Group Containers/AB12CD34EF.ru.keepcoder.Telegram/appstore/account-1/postbox/media",
                      "Application Support/FakeElectronApp/Cache", "Application Support/FakeElectronApp/Code Cache",
                      "Application Support/FakeElectronApp/GPUCache", "Containers/com.example.qa-sandboxed/Data/Library/Caches"] {
            precondition(isDirectory(join(lib, cache)) && listDir(join(lib, cache)).isEmpty, "\(cache) not emptied")
        }
        for kept in ["Group Containers/AB12CD34EF.ru.keepcoder.Telegram/appstore/account-1/postbox/db/db_sqlite",
                     "Application Support/FakeElectronApp/User/settings.json",
                     "Containers/com.example.qa-sandboxed/Data/Documents/notes.txt",
                     "Application Support/PlainApp/data.bin"] {
            precondition(fm.fileExists(atPath: join(lib, kept)), "\(kept) was deleted but isn't cache")
        }
        precondition(model.notice?.ok == true, "notice: \(model.notice?.text ?? "nil")")
        print("AppData test OK (\(model.notice!.text))")
    }
}
