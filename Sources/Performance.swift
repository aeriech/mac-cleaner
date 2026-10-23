// Performance: live CPU/memory/thermal plus the apps using them.
// Background Items: what launches automatically, with code-signature checks.
import AppKit
import Security
import SwiftUI

// MARK: - System stats

func cpuTicks() -> (busy: UInt64, total: UInt64) {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    let t = info.cpu_ticks   // user, system, idle, nice
    let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
    return (busy, busy + UInt64(t.2))
}

/// "Memory Used" as Activity Monitor defines it: app memory + wired + compressed.
func memoryUsed() -> Int64 {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    let pages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
    return pages * Int64(getpagesize())
}

/// One row per app (helpers folded into their .app) or standalone process, for the current user.
struct ProcGroup: Identifiable, Sendable {
    var id: String { key }
    let key: String           // .app bundle path, or executable path
    let name: String
    var cpu: Double
    var memory: Int64
    var pids: [Int32]
    var isApp: Bool { key.hasSuffix(".app") }
    var quittable: Bool {
        key.hasPrefix("/") && !["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains { key.hasPrefix($0) }
            && name != "loginwindow"
    }
}

func processGroups() -> [ProcGroup] {
    guard let out = runTool("/bin/ps", ["-axo", "pid=,uid=,pcpu=,rss=,comm="]) else { return [] }
    let uid = getuid(), me = getpid()
    var groups: [String: ProcGroup] = [:]
    for line in out.split(separator: "\n") {
        var rest = line[...]
        func field() -> Substring {
            rest = rest.drop(while: { $0 == " " })
            let f = rest.prefix(while: { $0 != " " })
            rest = rest.dropFirst(f.count)
            return f
        }
        guard let pid = Int32(field()), let owner = UInt32(field()), owner == uid, pid != me,
              let cpu = Double(field()), let rssKB = Int64(field()) else { continue }
        let exe = String(rest.drop(while: { $0 == " " }))
        let key = exe.range(of: ".app/").map { String(exe[..<$0.lowerBound]) + ".app" } ?? exe
        let name = key.hasSuffix(".app") ? String(fileName(key).dropLast(4)) : fileName(exe)
        var g = groups[key] ?? ProcGroup(key: key, name: name, cpu: 0, memory: 0, pids: [])
        g.cpu += cpu
        g.memory += rssKB * 1024
        g.pids.append(pid)
        groups[key] = g
    }
    return Array(groups.values)
}

@MainActor
final class PerformanceModel: ObservableObject {
    @Published var cpu: Double = 0
    @Published var history: [Double] = Array(repeating: 0, count: 60)
    @Published var memUsed: Int64 = 0
    @Published var thermal: ProcessInfo.ThermalState = .nominal
    @Published var groups: [ProcGroup] = []
    @Published var sortByMemory = false
    @Published var quitTarget: ProcGroup?
    @Published var confirming = false
    let memTotal = Int64(ProcessInfo.processInfo.physicalMemory)
    private var last: (busy: UInt64, total: UInt64)?

    var top: [ProcGroup] {
        Array(groups.sorted { sortByMemory ? $0.memory > $1.memory : $0.cpu > $1.cpu }.prefix(40))
    }

    /// Samples every 2 s while the page is visible (the .task cancels it on leave).
    func monitor() async {
        while !Task.isCancelled {
            await sample()
            try? await Task.sleep(for: .seconds(last == nil ? 0.4 : 2))
        }
    }

    private func sample() async {
        let ticks = cpuTicks()
        if let l = last, ticks.total > l.total {
            cpu = Double(ticks.busy - l.busy) / Double(ticks.total - l.total)
            history = Array((history + [cpu]).suffix(60))
        }
        last = ticks
        memUsed = memoryUsed()
        thermal = ProcessInfo.processInfo.thermalState
        groups = await offMain { processGroups() }
    }

    func quit(_ g: ProcGroup, force: Bool) {
        if g.isApp, let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == g.key }) {
            _ = force ? app.forceTerminate() : app.terminate()
        } else {
            for pid in g.pids { kill(pid, force ? SIGKILL : SIGTERM) }
        }
        groups.removeAll { $0.key == g.key }   // the next sample corrects this if it didn't quit
    }
}

struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { g in
            let step = g.size.width / CGFloat(max(1, values.count - 1))
            let points = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * step, y: g.size.height * (1 - CGFloat(min(1, max(0, v)))))
            }
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: g.size.height))
                    p.addLines(points)
                    p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [.blue.opacity(0.25), .blue.opacity(0)], startPoint: .top, endPoint: .bottom))
                Path { p in p.addLines(points) }
                    .stroke(brandGradient, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            }
        }
    }
}

struct PerformanceView: View {
    @ObservedObject var m: PerformanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Performance", subtitle: "Live CPU and memory, and the apps using them",
                       icon: "gauge.with.dots.needle.50percent")
            HStack(spacing: 14) {
                statCard("CPU", icon: "cpu", value: String(format: "%.0f%%", m.cpu * 100),
                         detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores") {
                    Sparkline(values: m.history).frame(height: 34)
                }
                statCard("Memory", icon: "memorychip", value: fmtMemory(m.memUsed),
                         detail: "of \(fmtMemory(m.memTotal)) used") {
                    ProgressView(value: Double(m.memUsed), total: Double(max(1, m.memTotal)))
                        .tint(Double(m.memUsed) / Double(max(1, m.memTotal)) > 0.85 ? .orange : .blue)
                }
                statCard("Temperature", icon: "thermometer.medium", value: thermal.text,
                         detail: thermal.detail, tint: thermal.color) { EmptyView() }
            }
            HStack {
                Text("Apps & processes").font(.headline)
                Spacer()
                Picker("Sort", selection: $m.sortByMemory) {
                    Text("By CPU").tag(false)
                    Text("By Memory").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
            HStack {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("CPU").frame(width: 70, alignment: .trailing)
                Text("Memory").frame(width: 80, alignment: .trailing)
                Color.clear.frame(width: 64, height: 1)
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(m.top) { g in row(g) }
                }
            }
        }
        .task { await m.monitor() }
        .alert("Quit \(m.quitTarget?.name ?? "")?", isPresented: $m.confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Quit") { if let g = m.quitTarget { m.quit(g, force: false) } }
            Button("Force Quit", role: .destructive) { if let g = m.quitTarget { m.quit(g, force: true) } }
        } message: {
            Text("Quit lets the app save first. Force Quit stops it immediately and unsaved work is lost.")
        }
    }

    private var thermal: (text: String, detail: String, color: Color) {
        switch m.thermal {
        case .nominal: ("Normal", "Running cool", .green)
        case .fair: ("Warm", "Fans may spin up", .yellow)
        case .serious: ("Hot", "macOS is slowing things to cool down", .orange)
        case .critical: ("Critical", "Quit heavy apps now", .red)
        @unknown default: ("Unknown", "", .gray)
        }
    }

    private func statCard<Extra: View>(_ title: String, icon: String, value: String, detail: String,
                                       tint: Color = .primary, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            extra()
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132, alignment: .topLeading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(_ g: ProcGroup) -> some View {
        HStack(spacing: 10) {
            if g.isApp {
                Image(nsImage: NSWorkspace.shared.icon(forFile: g.key)).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 22, height: 22)
            }
            Text(g.name).lineLimit(1)
            if g.pids.count > 1 {
                Text("\(g.pids.count) processes").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(String(format: "%.1f%%", g.cpu)).monospacedDigit()
                .foregroundStyle(g.cpu > 50 ? Color.orange : Color.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(fmtMemory(g.memory)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            Button("Quit") { m.quitTarget = g; m.confirming = true }
                .controlSize(.small)
                .frame(width: 64)
                .opacity(g.quittable ? 1 : 0)
                .disabled(!g.quittable)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - Background Items

enum SignatureStatus: Sendable, Equatable {
    case apple, developer(String), adHoc, unsigned, invalid, script, missing, unknown

    var label: String {
        switch self {
        case .apple: "Apple"
        case .developer(let who): "Signed · \(who)"
        case .adHoc: "Not from an identified developer"
        case .unsigned: "Unsigned"
        case .invalid: "Signature broken"
        case .script: "Runs a script"
        case .missing: "App is gone"
        case .unknown: "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .apple, .developer: .green
        case .adHoc, .unsigned, .script: .orange
        case .invalid: .red
        case .missing, .unknown: .gray
        }
    }

    var flagged: Bool { [.adHoc, .unsigned, .invalid, .script, .missing].contains(self) }
}

struct BackgroundItem: Identifiable, Sendable {
    var id: String { plist }
    let plist: String
    let label: String
    let program: String?
    let scope: String
    let userOwned: Bool
    let status: SignatureStatus
}

func codeSignature(_ path: String) -> SignatureStatus {
    guard FileManager.default.fileExists(atPath: path) else { return .missing }
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
          let code = staticCode else { return .unknown }
    let validity = SecStaticCodeCheckValidity(code, [], nil)
    if validity == errSecCSUnsigned { return .unsigned }
    if validity != errSecSuccess { return .invalid }
    var requirement: SecRequirement?
    if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
       let req = requirement, SecStaticCodeCheckValidity(code, [], req) == errSecSuccess { return .apple }
    var info: CFDictionary?
    SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
    guard let dict = info as? [String: Any],
          let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certs.first,
          let summary = SecCertificateCopySubjectSummary(leaf) as String? else { return .adHoc }
    // "Developer ID Application: Acme Inc (TEAMID)" → "Acme Inc"
    var who = summary
    if let r = who.range(of: ": ") { who = String(who[r.upperBound...]) }
    if let r = who.range(of: " (", options: .backwards) { who = String(who[..<r.lowerBound]) }
    return .developer(who)
}

let scriptInterpreters: Set<String> = ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/env", "/usr/bin/osascript",
                                        "/usr/bin/python3", "/usr/bin/perl", "/usr/bin/ruby"]

func findBackgroundItems() -> [BackgroundItem] {
    let places: [(dir: String, scope: String, userOwned: Bool)] = [
        (homePath("Library/LaunchAgents"), "Your account", true),
        ("/Library/LaunchAgents", "All users", false),
        ("/Library/LaunchDaemons", "System-wide", false),
    ]
    var items: [BackgroundItem] = []
    for place in places {
        for entry in listDir(place.dir) where entry.hasSuffix(".plist") {
            let path = join(place.dir, entry)
            let dict = NSDictionary(contentsOfFile: path)
            let args = dict?["ProgramArguments"] as? [String] ?? []
            let program = dict?["Program"] as? String ?? args.first
            var status = SignatureStatus.unknown
            if let program, program.hasPrefix("/") {
                status = scriptInterpreters.contains(program) && args.count > 1 ? .script : codeSignature(program)
            }
            items.append(BackgroundItem(plist: path, label: dict?["Label"] as? String ?? bundleStem(entry),
                                        program: program, scope: place.scope, userOwned: place.userOwned, status: status))
        }
    }
    return items.sorted { ($0.status.flagged ? 0 : 1, $0.label.lowercased()) < ($1.status.flagged ? 0 : 1, $1.label.lowercased()) }
}

@MainActor
final class BackgroundItemsModel: ObservableObject {
    @Published var items: [BackgroundItem] = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var removeTarget: BackgroundItem?
    @Published var confirming = false
    @Published var notice: Notice?

    func scan() async {
        scanning = true
        items = await offMain { findBackgroundItems() }
        scanning = false
        scanned = true
    }

    func remove(_ item: BackgroundItem) async {
        guard item.userOwned else { return }
        let plist = item.plist
        let failed = await offMain {
            runTool("/bin/launchctl", ["bootout", "gui/\(getuid())", plist])   // stop it if loaded
            return moveToTrash([plist])
        }
        if failed.isEmpty {
            items.removeAll { $0.id == item.id }
            notice = Notice(text: "Stopped \(item.label) and moved it to the Trash")
        } else {
            notice = Notice(text: "Couldn't remove \(item.label)", ok: false)
        }
    }
}

struct BackgroundItemsView: View {
    @ObservedObject var m: BackgroundItemsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Background Items", subtitle: "Everything that starts automatically, checked for a valid signature",
                       icon: "checkmark.shield") {
                Button("Login Items…") { openSettings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension") }
                Button { Task { await m.scan() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan")
                    .accessibilityLabel("Rescan")
                    .disabled(m.scanning)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(.blue)
                Text("This isn't an antivirus: macOS's built-in XProtect already blocks known malware. Items that are unsigned, run scripts or belong to deleted apps are listed first so you can review them.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let n = m.notice { NoticeView(notice: n) }
            if m.scanning && m.items.isEmpty {
                Working(text: "Checking signatures…")
            } else {
                let flagged = m.items.filter(\.status.flagged).count
                Text(flagged == 0 ? "\(m.items.count) items, all signed" : "\(m.items.count) items · \(flagged) worth a look")
                    .font(.headline)
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(m.items) { item in row(item) }
                    }
                }
            }
        }
        .task { if !m.scanned { await m.scan() } }
        .alert("Remove \(m.removeTarget?.label ?? "")?", isPresented: $m.confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { if let item = m.removeTarget { Task { await m.remove(item) } } }
        } message: {
            Text("It will stop running and its launch file is moved to the Trash.")
        }
    }

    private func row(_ item: BackgroundItem) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: item.status.flagged ? "exclamationmark.shield" : "checkmark.shield", tint: item.status.color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.label).fontWeight(.medium).lineLimit(1)
                    Badge(text: item.status.label, color: item.status.color)
                }
                Text("\(item.scope) · \(item.program.map(tilde) ?? "No program")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            RevealButton(path: item.plist)
            if item.userOwned {
                Button("Remove") { m.removeTarget = item; m.confirming = true }.controlSize(.small)
            } else {
                Text("Needs admin").font(.caption).foregroundStyle(.tertiary)
                    .help("Remove system-wide items in Finder; macOS will ask for your password")
            }
        }
        .card()
    }
}
