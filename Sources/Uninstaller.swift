// Uninstaller (app + every file it left in ~/Library) and Leftovers (files from apps already gone).
// Everything goes to the Trash, so any mistake can be undone from there.
import AppKit
import SwiftUI

struct InstalledApp: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String
    let version: String
    var size: Int64 = 0
}

struct RelatedFile: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let kind: String
    var size: Int64
    var selected = true
}

func appInfo(_ path: String) -> InstalledApp? {
    guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { return nil }
    var name = FileManager.default.displayName(atPath: path)
    if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
    return InstalledApp(path: path, name: name, bundleID: id,
                        version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
}

/// Apps in /Applications and ~/Applications, one folder deep (for suites like Office or Adobe).
func discoverApps() -> [InstalledApp] {
    var found: [InstalledApp] = []
    for root in ["/Applications", homePath("Applications")] {
        for name in listDir(root) {
            let path = join(root, name)
            if name.hasSuffix(".app") {
                if let app = appInfo(path) { found.append(app) }
            } else if isDirectory(path) {
                found += listDir(path).filter { $0.hasSuffix(".app") }.compactMap { appInfo(join(path, $0)) }
            }
        }
    }
    return found
}

/// "com.Foo.App.plist" → "com.foo.app": lowercased, with Library file suffixes dropped.
func bundleStem(_ entry: String) -> String {
    var s = entry.lowercased()
    for ext in [".plist", ".savedstate", ".binarycookies"] where s.hasSuffix(ext) { s = String(s.dropLast(ext.count)) }
    return s
}

func looksLikeBundleID(_ s: String) -> Bool {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 3, (2...4).contains(parts[0].count), parts[0].allSatisfy(\.isLetter) else { return false }
    return parts.allSatisfy { part in
        !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

/// "group.com.foo.app", "ABCDE12345.com.foo.app", "TEAMID.groups.com.foo" → "com.foo.app" / "com.foo"
func canonicalID(_ id: String) -> String {
    var s = id
    func drop(_ prefixes: [String]) { for p in prefixes where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) } }
    drop(["systemgroup.", "group.", "groups."])
    let first = s.prefix(while: { $0 != "." })
    if first.count == 10, first.allSatisfy({ $0.isLetter || $0.isNumber }), first.contains(where: \.isNumber) {
        s = String(s.dropFirst(11))   // Apple team ID prefix
    }
    drop(["group.", "groups."])
    return s
}

/// "com.google.chrome" → "com.google"
func vendor(_ id: String) -> String { id.split(separator: ".").prefix(2).joined(separator: ".") }

/// Files an app keeps in ~/Library, matched by bundle ID (and by exact app name in a few folders).
func relatedFiles(for app: InstalledApp) -> [RelatedFile] {
    let lib = homePath("Library")
    let id = app.bundleID.lowercased()
    let name = app.name.lowercased()
    let places: [(dir: String, kind: String, byName: Bool)] = [
        ("Application Support", "App data", true),
        ("Caches", "Cache", true),
        ("Containers", "Sandbox data", false),
        ("Group Containers", "Shared data", false),
        ("Preferences", "Preferences", false),
        ("Preferences/ByHost", "Preferences", false),
        ("Saved Application State", "Saved window state", false),
        ("Logs", "Logs", true),
        ("HTTPStorages", "Web data", false),
        ("WebKit", "Web data", false),
        ("Cookies", "Cookies", false),
        ("LaunchAgents", "Launch agent", false),
        ("Application Scripts", "Scripts", false),
    ]
    var out: [RelatedFile] = []
    for place in places {
        let dir = join(lib, place.dir)
        for entry in listDir(dir) {
            let stem = bundleStem(entry)
            let byID = stem == id || stem.hasPrefix(id + ".")
                || (place.dir == "Group Containers" && stem.hasSuffix("." + id))
            let byName = place.byName && name.count >= 4 && entry.lowercased() == name
            if byID || byName {
                let path = join(dir, entry)
                out.append(RelatedFile(path: path, kind: place.kind, size: diskUsage(path)))
            }
        }
    }
    return out.sorted { $0.size > $1.size }
}

/// Finder can remove apps we can't (root-owned App Store apps), asking for a password if needed.
@MainActor func finderDelete(_ path: String) -> Bool {
    let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    var error: NSDictionary?
    NSAppleScript(source: "tell application \"Finder\" to delete (POSIX file \"\(escaped)\")")?.executeAndReturnError(&error)
    return !FileManager.default.fileExists(atPath: path)
}

@MainActor
final class UninstallerModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var query = ""
    @Published var sortBySize = false
    @Published var selection: String?
    @Published var related: [RelatedFile] = []
    @Published var loadingRelated = false
    @Published var working = false
    @Published var confirming = false
    @Published var notice: Notice?

    var visible: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return sortBySize ? list.sorted { $0.size > $1.size } : list
    }
    var selectedApp: InstalledApp? { apps.first { $0.path == selection } }
    var removalTotal: Int64 { (selectedApp?.size ?? 0) + related.filter(\.selected).reduce(0) { $0 + $1.size } }

    func load() async {
        let own = Bundle.main.bundleIdentifier ?? "local.maccleaner"
        let found = await offMain { discoverApps() }
        apps = found
            .filter { $0.bundleID != "com.apple.Safari" && $0.bundleID != own }   // Safari is part of macOS
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for app in apps {   // sizes fill in progressively
            let path = app.path
            let size = await offMain { diskUsage(path) }
            if let i = apps.firstIndex(where: { $0.path == path }) { apps[i].size = size }
        }
    }

    func loadRelated() async {
        guard let app = selectedApp else { related = []; return }
        loadingRelated = true
        related = []
        let files = await offMain { relatedFiles(for: app) }
        if selection == app.path { related = files }
        loadingRelated = false
    }

    func uninstall() async {
        guard let app = selectedApp else { return }
        working = true
        notice = nil
        defer { working = false }

        // Ask the app to quit first so it can save its work.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        running.forEach { $0.terminate() }
        var waits = 0
        while running.contains(where: { !$0.isTerminated }) && waits < 15 {
            try? await Task.sleep(for: .milliseconds(200))
            waits += 1
        }
        if running.contains(where: { !$0.isTerminated }) {
            notice = Notice(text: "\(app.name) is still open. Quit it, then try again.", ok: false)
            return
        }

        // Remove the app first. If that fails, its settings and data must stay where they are.
        let appPath = app.path
        var appFailed = await offMain { moveToTrash([appPath]) }
        if !appFailed.isEmpty, finderDelete(appPath) { appFailed = [] }
        guard appFailed.isEmpty else {
            notice = Notice(text: "Couldn't remove \(app.name), so nothing was changed. Allow Mac Cleaner in System Settings → Privacy & Security → App Management, or drag it to the Trash.", ok: false)
            return
        }

        let relatedPaths = related.filter(\.selected).map(\.path)
        let failed = await offMain { moveToTrash(relatedPaths) }
        apps.removeAll { $0.path == appPath }
        selection = nil
        related = []
        notice = failed.isEmpty
            ? Notice(text: "\(app.name) and \(relatedPaths.count) related items moved to the Trash")
            : Notice(text: "\(app.name) removed; \(failed.count) item(s) are protected by macOS and were left in place", ok: false)
    }
}

struct UninstallerView: View {
    @ObservedObject var m: UninstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Uninstaller", subtitle: "Remove apps completely, including the files they leave behind", icon: "xmark.app") {
                Picker("Sort", selection: $m.sortBySize) {
                    Text("Name").tag(false)
                    Text("Size").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }
            if let n = m.notice { NoticeView(notice: n) }
            HStack(spacing: 0) {
                appList.frame(width: 300)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
        .task { if m.apps.isEmpty { await m.load() } }
        .onChange(of: m.selection) { Task { await m.loadRelated() } }
        .alert("Uninstall \(m.selectedApp?.name ?? "app")?", isPresented: $m.confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { Task { await m.uninstall() } }
        } message: {
            Text("The app and \(m.related.filter(\.selected).count) related items (\(fmt(m.removalTotal))) will be moved to the Trash. You can put them back from there.")
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(m.apps.count) apps", text: $m.query).textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(10)
            List(m.visible, selection: $m.selection) { app in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).lineLimit(1)
                        if !app.version.isEmpty {
                            Text(app.version).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(app.size > 0 ? fmt(app.size) : "…").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var detail: some View {
        if let app = m.selectedApp {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.title2.weight(.semibold))
                        Text([app.version.isEmpty ? nil : "Version \(app.version)", app.bundleID]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text("Everything that will be removed").font(.headline).padding(.top, 4)
                ScrollView {
                    VStack(spacing: 6) {
                        fileRow(path: app.path, kind: "Application", size: app.size, isOn: .constant(true), locked: true)
                        ForEach($m.related) { $file in
                            fileRow(path: file.path, kind: file.kind, size: file.size, isOn: $file.selected, locked: false)
                        }
                        if m.loadingRelated {
                            ProgressView().padding()
                        } else if m.related.isEmpty {
                            Text("No other files found. This app keeps things tidy.")
                                .font(.callout).foregroundStyle(.secondary).padding(.top, 6)
                        }
                    }
                }
                ActionBar(summary: "Moved to the Trash, so you can undo",
                          title: "Uninstall · \(fmt(m.removalTotal))",
                          enabled: !m.loadingRelated,
                          busy: m.working) { m.confirming = true }
            }
            .padding(18)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "app.dashed").font(.system(size: 42)).foregroundStyle(.tertiary)
                Text("Select an app").font(.title3.weight(.semibold))
                Text("You'll see the app plus every cache, preference and support file it created.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fileRow(path: String, kind: String, size: Int64, isOn: Binding<Bool>, locked: Bool) -> some View {
        HStack(spacing: 10) {
            Toggle("\(kind): \(fileName(path))", isOn: isOn).labelsHidden().toggleStyle(.checkbox).disabled(locked)
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind).font(.callout.weight(.medium))
                Text(tilde(path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(fmt(size)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            RevealButton(path: path)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - Leftovers

struct Leftover: Identifiable, Sendable {
    var id: String { identifier }
    let identifier: String
    var paths: [String]
    var kinds: [String]
    var size: Int64 = 0
    var selected = true
}

/// Every bundle ID on this Mac. Spotlight also finds apps outside /Applications (dev builds, helpers).
func installedBundleIDs(_ apps: [InstalledApp]) -> Set<String> {
    var ids = Set(apps.map { $0.bundleID.lowercased() })
    let spotlight = runTool("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"]) ?? ""
    for path in spotlight.split(separator: "\n") {
        if let id = Bundle(path: String(path))?.bundleIdentifier { ids.insert(id.lowercased()) }
    }
    return ids
}

func launchProgram(_ plist: String) -> String? {
    guard let d = NSDictionary(contentsOfFile: plist) else { return nil }
    return d["Program"] as? String ?? (d["ProgramArguments"] as? [String])?.first
}

/// Library items named after a bundle ID that nothing on this Mac can own: not Apple, not any
/// installed app, not any app from the same vendor (keeps shared updaters safe), not a shared
/// framework ID, and not containing an installed app's name (e.g. "com.electron.dockerdesktop").
func findLeftovers(alsoInstalled extra: Set<String>) -> [Leftover] {
    let apps = discoverApps()
    let installed = installedBundleIDs(apps).union(extra).map(canonicalID)
    let vendors = Set(installed.map(vendor))
    let appNames = apps.map { $0.name.lowercased().filter { $0.isLetter || $0.isNumber } }.filter { $0.count >= 4 }
    let sharedFrameworks: Set<String> = ["com.electron", "com.github.electron", "org.chromium", "org.sparkle-project", "is.workflow"]
    func isOwned(_ id: String) -> Bool {
        let flat = id.filter { $0.isLetter || $0.isNumber }
        return id.hasPrefix("com.apple.") || id == "local.maccleaner" || installed.contains(id)
            || vendors.contains(vendor(id)) || sharedFrameworks.contains(vendor(id))
            || appNames.contains { flat.contains($0) }
    }

    let lib = homePath("Library")
    let places: [(String, String)] = [
        ("Application Support", "App data"), ("Caches", "Cache"), ("Containers", "Sandbox data"),
        ("Preferences", "Preferences"), ("Saved Application State", "Saved state"), ("HTTPStorages", "Web data"),
        ("WebKit", "Web data"), ("Logs", "Logs"),
    ]
    var byID: [String: Leftover] = [:]
    func add(_ id: String, _ path: String, _ kind: String) {
        var item = byID[id] ?? Leftover(identifier: id, paths: [], kinds: [])
        item.paths.append(path)
        if !item.kinds.contains(kind) { item.kinds.append(kind) }
        byID[id] = item
    }
    for (dir, kind) in places {
        let base = join(lib, dir)
        for entry in listDir(base) {
            let id = canonicalID(bundleStem(entry))
            guard looksLikeBundleID(id), !isOwned(id) else { continue }
            add(id, join(base, entry), kind)
        }
    }
    // Launch agents whose program no longer exists are leftovers (unless they're Apple's).
    let agents = join(lib, "LaunchAgents")
    for entry in listDir(agents) where entry.hasSuffix(".plist") {
        let path = join(agents, entry)
        let id = canonicalID(bundleStem(entry))
        if !id.hasPrefix("com.apple."), let program = launchProgram(path), program.hasPrefix("/"),
           !FileManager.default.fileExists(atPath: program) {
            add(id, path, "Launch agent for a missing app")
        }
    }
    var result = Array(byID.values)
    for i in result.indices { result[i].size = result[i].paths.reduce(0) { $0 + diskUsage($1) } }
    return result.filter { $0.size > 0 }.sorted { $0.size > $1.size }
}

@MainActor
final class LeftoversModel: ObservableObject {
    @Published var items: [Leftover] = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var working = false
    @Published var confirming = false
    @Published var notice: Notice?

    var chosen: [Leftover] { items.filter(\.selected) }
    var chosenSize: Int64 { chosen.reduce(0) { $0 + $1.size } }

    func scan() async {
        scanning = true
        notice = nil
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        items = await offMain { findLeftovers(alsoInstalled: running) }
        scanning = false
        scanned = true
    }

    func setAll(_ on: Bool) { for i in items.indices { items[i].selected = on } }

    func remove() async {
        working = true
        let picked = chosen
        let failed = await offMain { moveToTrash(picked.flatMap(\.paths)) }
        items.removeAll { item in item.selected && item.paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) } }
        working = false
        notice = failed.isEmpty
            ? Notice(text: "Moved \(fmt(picked.reduce(0) { $0 + $1.size })) of leftovers to the Trash")
            : Notice(text: "\(failed.count) item(s) are protected by macOS and were left in place", ok: false)
    }
}

struct LeftoversView: View {
    @ObservedObject var m: LeftoversModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Leftovers", subtitle: "Files left behind by apps you already deleted", icon: "folder.badge.minus") {
                if m.scanned && !m.items.isEmpty {
                    Button(m.chosen.count == m.items.count ? "Deselect All" : "Select All") {
                        m.setAll(m.chosen.count != m.items.count)
                    }
                }
                if m.scanned {
                    Button { Task { await m.scan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .disabled(m.scanning || m.working)
                }
            }
            if let n = m.notice { NoticeView(notice: n) }
            if m.scanning {
                Working(text: "Matching Library files against installed apps…")
            } else if !m.scanned {
                ScanPrompt(icon: "folder.badge.minus", title: "Find leftovers",
                           message: "Checks your Library for data that belongs to apps no longer on this Mac. Nothing is removed until you choose, and removed items go to the Trash.",
                           button: "Scan for Leftovers") { Task { await m.scan() } }
            } else if m.items.isEmpty {
                EmptyResult(text: "No leftovers found. Nice and tidy.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach($m.items) { $item in
                            HStack(spacing: 12) {
                                Toggle(item.identifier, isOn: $item.selected).labelsHidden().toggleStyle(.checkbox)
                                IconTile(symbol: "questionmark.app.dashed", tint: .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.identifier).fontWeight(.medium).lineLimit(1)
                                    Text(item.kinds.joined(separator: " · ") + " · \(item.paths.count) item\(item.paths.count == 1 ? "" : "s")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(fmt(item.size)).monospacedDigit().foregroundStyle(.secondary)
                                RevealButton(path: item.paths[0])
                            }
                            .card()
                        }
                    }
                }
                ActionBar(summary: "\(m.items.count) leftovers found",
                          title: "Move \(m.chosen.count) to Trash · \(fmt(m.chosenSize))",
                          enabled: !m.chosen.isEmpty,
                          busy: m.working) { m.confirming = true }
            }
        }
        .alert("Move \(m.chosen.count) leftovers to the Trash?", isPresented: $m.confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { Task { await m.remove() } }
        } message: {
            Text("\(fmt(m.chosenSize)) of files from apps that are no longer installed. You can put them back from the Trash.")
        }
    }
}
