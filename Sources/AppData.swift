// App Data: what apps keep in ~/Library (macOS counts it as "System Data"), and the part that is
// only regenerable cache: downloaded media, web/code/GPU caches. Only that part can be cleared.
import AppKit
import SwiftUI

struct CacheDir: Sendable {
    let path: String
    let label: String
    let size: Int64
}

struct AppDataEntry: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String?
    let appPath: String?
    let place: String
    var size: Int64
    var caches: [CacheDir]
    var hint: String?
    var selected = false
    var cacheSize: Int64 { caches.reduce(0) { $0 + $1.size } }
}

/// Cache folder names Chromium and Electron apps (VS Code, Slack, Discord, browsers…) rebuild on their own.
let chromiumCacheNames: Set<String> = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
                                       "GrShaderCache", "ShaderCache", "CachedData", "CachedExtensionVSIXs"]

/// Advice for big app data that has no safe cache to clear here.
let appDataHints: [String: String] = [
    "com.docker.docker": "Docker images and containers. Clear unused ones in Docker: docker system prune",
    "mobilesync": "iPhone and iPad backups. Manage them in Finder → your device → Manage Backups",
]

/// Regenerable cache folders inside one app's data folder.
func findCaches(in root: String) -> [CacheDir] {
    var found: [(path: String, label: String)] = []
    // Telegram (App Store): every downloaded photo, video and file lives in postbox/media.
    if root.lowercased().hasSuffix("ru.keepcoder.telegram") {
        let store = join(root, "appstore")
        for account in listDir(store) where account.hasPrefix("account-") {
            let media = join(store, "\(account)/postbox/media")
            if isDirectory(media) { found.append((media, "downloaded photos, videos and files")) }
        }
    }
    // Sandboxed apps keep their cache inside their container.
    let containerCache = join(root, "Data/Library/Caches")
    if isDirectory(containerCache) { found.append((containerCache, "cache")) }
    // Chromium/Electron caches, a few levels down (e.g. Google/Chrome/Default/GPUCache).
    if let walker = FileManager.default.enumerator(atPath: root) {
        while autoreleasepool(invoking: {
            guard let rel = walker.nextObject() as? String else { return false }
            let path = join(root, rel)
            if found.contains(where: { $0.path == path }) { walker.skipDescendants(); return true }
            if chromiumCacheNames.contains(fileName(rel)), isDirectory(path) {
                found.append((path, "web and app cache"))
                walker.skipDescendants()
            } else if walker.level >= 4 {
                walker.skipDescendants()
            }
            return true
        }) {}
    }
    return found.map { CacheDir(path: $0.path, label: $0.label, size: diskUsage($0.path)) }.filter { $0.size > 0 }
}

/// Third-party app data in ~/Library of at least `minSize`, largest first, plus how many app folders
/// macOS wouldn't let us read (no Full Disk Access). Apple's own data is left out.
func scanAppData(library lib: String = homePath("Library"), minSize: Int64 = 50_000_000) -> (entries: [AppDataEntry], blocked: Int) {
    let places = [("Group Containers", "Shared data"), ("Containers", "Sandbox data"), ("Application Support", "App data")]
    var entries: [AppDataEntry] = []
    var blocked = 0
    for (dir, place) in places {
        for name in listDir(join(lib, dir)) {
            let id = canonicalID(name)
            guard !id.lowercased().hasPrefix("com.apple."), !name.hasPrefix(".") else { continue }
            let path = join(join(lib, dir), name)
            guard (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil else {
                if isDirectory(path) { blocked += 1 }   // protected by macOS: count it rather than hide it silently
                continue
            }
            let size = diskUsage(path)
            guard size >= minSize else { continue }
            let bundleID = looksLikeBundleID(id.lowercased()) ? id : nil
            let appURL = bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            var display = appURL.map { FileManager.default.displayName(atPath: $0.path) } ?? name
            if display.hasSuffix(".app") { display = String(display.dropLast(4)) }
            entries.append(AppDataEntry(path: path, name: display, bundleID: bundleID, appPath: appURL?.path,
                                        place: place, size: size, caches: findCaches(in: path),
                                        hint: appDataHints[id.lowercased()] ?? appDataHints[name.lowercased()]))
        }
    }
    return (entries.sorted { $0.size > $1.size }, blocked)
}

@MainActor
final class AppDataModel: ObservableObject {
    @Published var entries: [AppDataEntry] = []
    @Published var blocked = 0
    @Published var scanning = false
    @Published var scanned = false
    @Published var working = false
    @Published var confirming = false
    @Published var notice: Notice?

    var chosen: [AppDataEntry] { entries.filter { $0.selected && $0.cacheSize > 0 } }
    var chosenSize: Int64 { chosen.reduce(0) { $0 + $1.cacheSize } }
    var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
    var totalCache: Int64 { entries.reduce(0) { $0 + $1.cacheSize } }
    /// Apps that have to quit before their cache can be cleared.
    var appsToQuit: [String] { chosen.filter { !running($0).isEmpty }.map(\.name) }

    func running(_ e: AppDataEntry) -> [NSRunningApplication] {
        if let id = e.bundleID {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            if !apps.isEmpty { return apps }
        }
        // Electron apps name their Application Support folder after themselves ("Code", "Postman").
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.localizedName?.caseInsensitiveCompare(e.name) == .orderedSame
        }
    }

    func scan() async {
        scanning = true
        notice = nil
        let result = await offMain { scanAppData() }
        entries = result.entries
        blocked = result.blocked
        scanning = false
        scanned = true
    }

    func clean() async {
        working = true
        notice = nil
        // Quit each app first: deleting the cache under a running app can corrupt what it has open.
        var ready: [AppDataEntry] = [], stillOpen: [String] = []
        for e in chosen {
            let apps = running(e)
            apps.forEach { $0.terminate() }
            var waits = 0
            while apps.contains(where: { !$0.isTerminated }) && waits < 15 {
                try? await Task.sleep(for: .milliseconds(200))
                waits += 1
            }
            if apps.contains(where: { !$0.isTerminated }) { stillOpen.append(e.name) } else { ready.append(e) }
        }
        let lib = homePath("Library") + "/"
        let dirs = ready.flatMap(\.caches).map(\.path).filter { $0.hasPrefix(lib) }
        let before = ready.reduce(0) { $0 + $1.cacheSize }
        let stuck = await offMain {
            // Empty each cache folder but keep the folder itself, which apps expect to exist.
            dirs.flatMap { dir in listDir(dir).map { join(dir, $0) } }.filter { !forceRemove($0) }.count
        }
        let readyPaths = Set(ready.map(\.path))
        working = false
        await scan()
        let after = entries.filter { readyPaths.contains($0.path) }.reduce(0) { $0 + $1.cacheSize }
        var text = "Freed \(fmt(max(0, before - after)))"
        if !stillOpen.isEmpty { text += ". Skipped \(stillOpen.joined(separator: ", ")) because it is still open" }
        if stuck > 0 { text += ". \(stuck) item\(stuck == 1 ? " was" : "s were") in use and left in place" }
        notice = Notice(text: text, ok: stillOpen.isEmpty && stuck == 0)
    }
}

struct AppDataView: View {
    @ObservedObject var m: AppDataModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "App Data", subtitle: "What's inside System Data, and the cache that's safe to clear",
                       icon: "square.stack.3d.up") {
                if m.scanned {
                    Button { Task { await m.scan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .disabled(m.scanning || m.working)
                }
            }
            if let n = m.notice { NoticeView(notice: n) }
            if m.scanned && m.blocked > 0 && !m.scanning {
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    Text("\(m.blocked) app\(m.blocked == 1 ? "'s" : "s'") data is protected by macOS and isn't shown, so the totals are incomplete. Allow Full Disk Access, then rescan.")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Allow Access…") { openSettings(fullDiskAccessURL) }
                }
                .padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if m.scanning {
                Working(text: "Measuring what apps store in your Library…")
            } else if !m.scanned {
                ScanPrompt(icon: "square.stack.3d.up", title: "See what apps are storing",
                           message: "Measures the data apps keep in your Library, which macOS counts as System Data, and finds the part that's only cache: downloaded media plus web and app caches. Apps re-download or rebuild those when needed. Everything else is left alone.",
                           button: "Scan App Data") { Task { await m.scan() } }
            } else if m.entries.isEmpty {
                EmptyResult(text: "No app is storing much data.")
            } else {
                Text("\(fmt(m.totalSize)) of app data · \(fmt(m.totalCache)) of it is cache you can clear")
                    .font(.headline)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach($m.entries) { $e in row($e) }
                    }
                }
                ActionBar(summary: "Apps are quit before their cache is cleared",
                          title: "Clear \(fmt(m.chosenSize))",
                          enabled: m.chosenSize > 0,
                          busy: m.working) { m.confirming = true }
            }
        }
        .alert("Clear \(fmt(m.chosenSize)) of cache?", isPresented: $m.confirming) {
            Button("Cancel", role: .cancel) {}
            Button(m.appsToQuit.isEmpty ? "Clear" : "Quit Apps & Clear", role: .destructive) { Task { await m.clean() } }
        } message: {
            Text((m.appsToQuit.isEmpty ? "" : "\(m.appsToQuit.joined(separator: ", ")) will be quit first. ")
                 + "The cache is deleted permanently; apps re-download or rebuild what they need. Media from Telegram Secret Chats can't be re-downloaded.")
        }
    }

    private func row(_ entry: Binding<AppDataEntry>) -> some View {
        let e = entry.wrappedValue
        let detail = e.caches.isEmpty
            ? (e.hint ?? "Data the app needs; nothing here is safe to clear")
            : "\(fmt(e.cacheSize)) is \(Set(e.caches.map(\.label)).sorted().joined(separator: ", "))"
        return HStack(spacing: 12) {
            Toggle(e.name, isOn: entry.selected).labelsHidden().toggleStyle(.checkbox).disabled(e.caches.isEmpty)
            if let app = e.appPath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable().frame(width: 32, height: 32)
            } else {
                IconTile(symbol: "folder", tint: .gray)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(e.name).fontWeight(.medium).lineLimit(1)
                    Badge(text: e.place, color: .gray)
                }
                Text(detail).font(.caption).foregroundStyle(e.caches.isEmpty ? Color.secondary : Color.green).lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(fmt(e.size)).monospacedDigit()
                if e.cacheSize > 0 {
                    Text("\(Int((Double(e.cacheSize) / Double(max(1, e.size)) * 100).rounded()))% cache")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            RevealButton(path: e.path)
        }
        .card()
    }
}
