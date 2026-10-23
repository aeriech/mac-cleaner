// Shared helpers and building-block views used by every page.
import AppKit
import SwiftUI

// MARK: - Files & processes

let home = NSHomeDirectory()
func homePath(_ rel: String) -> String { (home as NSString).appendingPathComponent(rel) }
func join(_ dir: String, _ name: String) -> String { (dir as NSString).appendingPathComponent(name) }
func tilde(_ path: String) -> String { path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path }
func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }
func fmt(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
/// RAM in binary units, matching Activity Monitor and About This Mac (16 GB, not 17.18 GB).
func fmtMemory(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory) }
func listDir(_ path: String) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] }
func isDirectory(_ path: String) -> Bool {
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
}

/// Runs a command-line tool and returns its stdout (nil if it couldn't start).
@discardableResult
func runTool(_ tool: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Size on disk of a file or folder via `du`: fast, and tolerant of unreadable subfolders.
func diskUsage(_ path: String) -> Int64 {
    guard let out = runTool("/usr/bin/du", ["-sk", path]),
          let field = out.split(whereSeparator: { $0 == "\t" || $0 == "\n" }).first,
          let kb = Int64(field.trimmingCharacters(in: .whitespaces)) else { return 0 }
    return kb * 1024
}

/// Runs blocking work off the main thread.
func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .userInitiated, operation: work).value
}

/// Deletes a file or folder permanently. Finder-locked files and read-only folders block deletion,
/// so on failure those flags are cleared (only works on items the user owns) and it retries.
/// Returns false if the item is still there, e.g. because the system owns it.
func forceRemove(_ path: String) -> Bool {
    let fm = FileManager.default
    if (try? fm.removeItem(atPath: path)) != nil { return true }
    runTool("/usr/bin/chflags", ["-R", "nouchg", path])
    runTool("/bin/chmod", ["-R", "u+w", path])
    try? fm.removeItem(atPath: path)
    return (try? fm.attributesOfItem(atPath: path)) == nil   // doesn't follow symlinks
}

/// Moves items to the Trash (recoverable). Returns the paths that couldn't be moved.
func moveToTrash(_ paths: [String]) -> [String] {
    paths.filter { (try? FileManager.default.trashItem(at: URL(fileURLWithPath: $0), resultingItemURL: nil)) == nil }
}

/// Walks folders for regular files ≥ minSize, skipping ~/Library, hidden folders, packages
/// (apps, photo libraries) and node_modules. iCloud placeholders are skipped so nothing downloads.
func walkFiles(in roots: [String], minSize: Int64, _ visit: (URL, URLResourceValues, Int64) -> Void) {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                                  .contentAccessDateKey, .contentModificationDateKey, .creationDateKey]
    let skip: Set<String> = [homePath("Library"), homePath(".Trash")]
    var seen = Set<String>()
    for root in roots {
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
        // One autorelease pool per file, so memory stays flat across hundreds of thousands of files.
        while autoreleasepool(invoking: {
            guard let url = walker.nextObject() as? URL else { return false }
            if skip.contains(url.path) || url.lastPathComponent == "node_modules" { walker.skipDescendants(); return true }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  (v.totalFileAllocatedSize ?? 0) > 0,
                  Int64(v.fileSize ?? 0) >= minSize,
                  seen.insert(url.path).inserted else { return true }
            visit(url, v, Int64(v.fileSize ?? 0))
            return true
        }) {}
    }
}

func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
func openSettings(_ url: String) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
let fullDiskAccessURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

@MainActor func chooseFolders() -> [String] {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Add"
    return panel.runModal() == .OK ? panel.urls.map(\.path) : []
}

func relative(_ date: Date) -> String {
    guard date != .distantPast else { return "Never opened" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f.localizedString(for: date, relativeTo: Date())
}

/// Checkbox-style selection over file paths, shared by the file-finding pages.
@MainActor protocol Picking: AnyObject {
    var picked: Set<String> { get set }
}

extension Picking {
    func pick(_ id: String) -> Binding<Bool> {
        Binding(get: { self.picked.contains(id) },
                set: { on in if on { self.picked.insert(id) } else { self.picked.remove(id) } })
    }
    func toggle(_ id: String) { if picked.contains(id) { picked.remove(id) } else { picked.insert(id) } }
}

// MARK: - Look & feel

let brandGradient = LinearGradient(
    colors: [Color(red: 0.42, green: 0.24, blue: 0.96), Color(red: 0.18, green: 0.42, blue: 1.0),
             Color(red: 0.07, green: 0.81, blue: 0.75)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

struct Notice: Equatable {
    let text: String
    var ok = true
}

struct NoticeView: View {
    let notice: Notice
    var body: some View {
        Label(notice.text, systemImage: notice.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(notice.ok ? Color.green : Color.orange)
            .transition(.opacity)
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(brandGradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .shadow(color: .blue.opacity(0.25), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String, icon: String) {
        self.init(title: title, subtitle: subtitle, icon: icon) { EmptyView() }
    }
}

struct IconTile: View {
    let symbol: String
    var tint: Color = .blue
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct Ring<Center: View>: View {
    let value: Double
    var lineWidth: CGFloat = 14
    var size: CGFloat = 150
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, value)))
                .stroke(brandGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: value)
            center()
        }
        .frame(width: size, height: size)
    }
}

/// Big centred call-to-action shown before a page has scanned anything.
struct ScanPrompt: View {
    let icon: String
    let title: String
    let message: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 92, height: 92)
                .background(brandGradient, in: Circle())
                .shadow(color: .blue.opacity(0.3), radius: 16, y: 6)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Working: View {
    let text: String
    var progress: Double? = nil
    var body: some View {
        VStack(spacing: 14) {
            if let progress { ProgressView(value: progress).frame(width: 260) } else { ProgressView() }
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyResult: View {
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 46))
                .foregroundStyle(brandGradient)
            Text(text).font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Summary text on the left, one prominent action on the right.
struct ActionBar: View {
    let summary: String
    let title: String
    let enabled: Bool
    var busy = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(summary).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(action: action) {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(title).fontWeight(.semibold)
                }
                .frame(minWidth: 150)
                .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!enabled || busy)
        }
        .padding(.top, 4)
    }
}

struct FolderChips: View {
    let folders: Binding<[String]>
    let add: @MainActor () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Search in").font(.callout).foregroundStyle(.secondary)
                ForEach(folders.wrappedValue, id: \.self) { folder in
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                        Text(fileName(folder))
                        Button { folders.wrappedValue.removeAll { $0 == folder } } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Stop searching \(fileName(folder))")
                    }
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }
                Button { add() } label: { Label("Add Folder", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
        }
    }
}

struct RevealButton: View {
    let path: String
    var body: some View {
        Button { reveal(path) } label: { Image(systemName: "magnifyingglass") }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show \(fileName(path)) in Finder")
    }
}

extension View {
    func card() -> some View {
        padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
