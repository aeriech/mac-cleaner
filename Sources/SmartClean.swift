// Smart Clean: caches, logs, broken downloads, mail attachments, dev caches and Trash.
import SwiftUI

struct JunkCategory: Identifiable, Sendable {
    enum Kind: Sendable {
        case contents(String)                 // empty this folder (folder itself stays)
        case matching(String, [String])       // files in folder with these extensions
    }

    let id: String
    let name: String
    let detail: String
    let icon: String
    let kind: Kind
    var size: Int64 = 0
    var items: [String] = []
    var selected = true
    var scanning = false
    var restricted = false                    // macOS privacy blocked reading it

    var root: String {
        switch kind { case .contents(let p), .matching(let p, _): p }
    }
}

@MainActor
final class CleanModel: ObservableObject {
    @Published var cats: [JunkCategory] = []
    @Published var scanning = false
    @Published var cleaning = false
    @Published var confirming = false
    @Published var notice: Notice?

    var found: Int64 { cats.filter { !$0.restricted }.reduce(0) { $0 + $1.size } }
    var selectedTotal: Int64 { cats.filter { $0.selected && !$0.restricted }.reduce(0) { $0 + $1.size } }

    static func catalog() -> [JunkCategory] {
        let lib = homePath("Library")
        let all: [JunkCategory] = [
            .init(id: "caches", name: "App caches", detail: "Temporary files apps rebuild on their own",
                  icon: "shippingbox", kind: .contents("\(lib)/Caches")),
            .init(id: "logs", name: "Logs & crash reports", detail: "Diagnostic logs nobody reads",
                  icon: "doc.text", kind: .contents("\(lib)/Logs")),
            .init(id: "crash", name: "Crash reporter data", detail: "Leftover crash-reporting state",
                  icon: "exclamationmark.triangle", kind: .contents("\(lib)/Application Support/CrashReporter")),
            .init(id: "state", name: "Saved app state", detail: "Window layouts restored when apps reopen",
                  icon: "macwindow", kind: .contents("\(lib)/Saved Application State")),
            .init(id: "downloads", name: "Broken downloads", detail: "Unfinished downloads in your Downloads folder",
                  icon: "arrow.down.circle",
                  kind: .matching(homePath("Downloads"), ["crdownload", "part", "partial", "download", "opdownload"])),
            .init(id: "mail", name: "Mail attachments", detail: "Downloaded copies; originals stay in Mail",
                  icon: "paperclip", kind: .contents("\(lib)/Containers/com.apple.mail/Data/Library/Mail Downloads")),
            .init(id: "derived", name: "Xcode build data", detail: "DerivedData, rebuilt on the next build",
                  icon: "hammer", kind: .contents("\(lib)/Developer/Xcode/DerivedData")),
            .init(id: "devsupport", name: "Xcode device support", detail: "Debug symbols for older iOS versions",
                  icon: "iphone", kind: .contents("\(lib)/Developer/Xcode/iOS DeviceSupport")),
            .init(id: "sim", name: "Simulator caches", detail: "iOS Simulator caches",
                  icon: "ipad.and.iphone", kind: .contents("\(lib)/Developer/CoreSimulator/Caches")),
            .init(id: "npm", name: "npm cache", detail: "Re-downloaded on the next install",
                  icon: "cube.box", kind: .contents(homePath(".npm/_cacache"))),
            .init(id: "bun", name: "Bun cache", detail: "Re-downloaded on the next install",
                  icon: "cube.box", kind: .contents(homePath(".bun/install/cache"))),
            .init(id: "gradle", name: "Gradle cache", detail: "Re-downloaded on the next build",
                  icon: "cube.box", kind: .contents(homePath(".gradle/caches"))),
            .init(id: "trash", name: "Trash", detail: "Empties the Trash for good",
                  icon: "trash", kind: .contents(homePath(".Trash"))),
        ]
        return all.filter { FileManager.default.fileExists(atPath: $0.root) }
    }

    nonisolated static func measure(_ kind: JunkCategory.Kind) -> (size: Int64, items: [String], restricted: Bool) {
        let fm = FileManager.default
        switch kind {
        case .contents(let dir):
            guard (try? fm.contentsOfDirectory(atPath: dir)) != nil else { return (0, [], true) }
            return (diskUsage(dir), [], false)
        case .matching(let dir, let exts):
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return (0, [], true) }
            let hits = names.filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }.map { join(dir, $0) }
            return (hits.reduce(0) { $0 + diskUsage($1) }, hits, false)
        }
    }

    func scan() async {
        guard !scanning, !cleaning else { return }
        scanning = true
        if cats.isEmpty { cats = Self.catalog() }
        for i in cats.indices { cats[i].scanning = true }
        for i in cats.indices {
            let kind = cats[i].kind
            let r = await offMain { CleanModel.measure(kind) }
            cats[i].size = r.size
            cats[i].items = r.items
            cats[i].restricted = r.restricted
            cats[i].scanning = false
        }
        scanning = false
    }

    func clean() async {
        guard !cleaning, !scanning else { return }
        cleaning = true
        notice = nil
        let targets = cats.filter { $0.selected && !$0.restricted && $0.size > 0 }
        let ids = Set(targets.map(\.id))
        let before = targets.reduce(0) { $0 + $1.size }
        // Items that couldn't be deleted, per category (in use, or owned by the system).
        let stuck: [String: Int] = await offMain {
            var stuck: [String: Int] = [:]
            for cat in targets {
                let paths: [String]
                switch cat.kind {
                case .contents(let dir):
                    guard dir.hasPrefix(home + "/") else { continue }
                    paths = listDir(dir).map { join(dir, $0) }
                case .matching:
                    paths = cat.items
                }
                stuck[cat.id] = paths.filter { !forceRemove($0) }.count
            }
            return stuck
        }
        var leftInPlace = stuck.values.reduce(0, +)
        // System-owned items in the Trash (e.g. App Store apps removed through Finder) need Finder,
        // which asks for an administrator password.
        if let trashLeft = stuck["trash"], trashLeft > 0, finderEmptyTrash() { leftInPlace -= trashLeft }
        cleaning = false
        await scan()
        let after = cats.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.size }
        let freed = "Freed \(fmt(max(0, before - after)))"
        notice = leftInPlace == 0
            ? Notice(text: freed)
            : Notice(text: "\(freed). \(leftInPlace) item\(leftInPlace == 1 ? " is" : "s are") in use or protected by macOS and \(leftInPlace == 1 ? "was" : "were") left in place.", ok: false)
    }
}

/// Asks Finder to empty the Trash. Unlike a plain delete it can remove system-owned items,
/// prompting for an administrator password. Returns false if it failed or was cancelled.
@MainActor func finderEmptyTrash() -> Bool {
    var error: NSDictionary?
    NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
    return error == nil
}

struct SmartCleanView: View {
    @ObservedObject var m: CleanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Smart Clean", subtitle: "Junk that's safe to remove, in one click", icon: "sparkles") {
                Button { Task { await m.scan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(m.scanning || m.cleaning)
            }
            hero
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($m.cats) { $cat in row($cat) }
                }
            }
            ActionBar(summary: m.scanning ? "Scanning…" : "\(m.cats.filter { $0.selected && !$0.restricted }.count) of \(m.cats.count) categories selected",
                      title: m.cleaning ? "Cleaning…" : "Clean \(fmt(m.selectedTotal))",
                      enabled: m.selectedTotal > 0 && !m.scanning,
                      busy: m.cleaning) { m.confirming = true }
        }
        .task { if m.cats.isEmpty { await m.scan() } }
        .alert("Clean \(fmt(m.selectedTotal))?", isPresented: $m.confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Clean", role: .destructive) { Task { await m.clean() } }
        } message: {
            Text("The selected caches, logs and Trash are deleted permanently. Apps rebuild whatever they need.")
        }
    }

    private var hero: some View {
        HStack(spacing: 28) {
            Ring(value: m.found > 0 ? Double(m.selectedTotal) / Double(m.found) : 0) {
                VStack(spacing: 2) {
                    Image(systemName: "sparkles").font(.title2).foregroundStyle(brandGradient)
                    Text(fmt(m.selectedTotal))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("selected").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(m.scanning ? "Looking for junk…" : (m.found > 0 ? "\(fmt(m.found)) of junk found" : "Your Mac is spotless"))
                    .font(.title2.weight(.semibold))
                Text("Only files that macOS and your apps regenerate automatically are included. Switch off anything you'd rather keep.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let n = m.notice { NoticeView(notice: n) }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func row(_ cat: Binding<JunkCategory>) -> some View {
        let c = cat.wrappedValue
        return HStack(spacing: 12) {
            IconTile(symbol: c.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).fontWeight(.medium)
                Text(c.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if c.scanning {
                ProgressView().controlSize(.small)
            } else if c.restricted {
                Button("Allow access…") { openSettings(fullDiskAccessURL) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("macOS needs you to grant Full Disk Access before this can be cleaned")
            } else {
                Text(c.size < 4096 ? "Empty" : fmt(c.size)).monospacedDigit().foregroundStyle(.secondary)
            }
            Toggle(c.name, isOn: cat.selected)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(c.restricted)
        }
        .card()
        .contextMenu { Button("Show in Finder") { reveal(c.root) } }
    }
}
