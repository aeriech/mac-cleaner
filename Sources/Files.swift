// Large & old files, exact duplicates (SHA-256), and visually similar images (Vision).
// All removals go to the Trash.
import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import Vision

// MARK: - Large & Old Files

struct FoundFile: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let size: Int64
    let lastUsed: Date
}

@MainActor
final class LargeFilesModel: ObservableObject, Picking {
    @Published var files: [FoundFile] = []
    @Published var picked: Set<String> = []
    @Published var minSize: Int64 = 100_000_000
    @Published var minAgeDays = 0
    @Published var scanning = false
    @Published var scanned = false
    @Published var working = false
    @Published var confirming = false
    @Published var notice: Notice?

    var visible: [FoundFile] {
        let cutoff = Date().addingTimeInterval(-Double(minAgeDays) * 86_400)
        return files.filter { $0.size >= minSize && (minAgeDays == 0 || $0.lastUsed < cutoff) }
    }
    var chosen: [FoundFile] { visible.filter { picked.contains($0.id) } }

    func scan() async {
        scanning = true
        notice = nil
        picked = []
        files = await offMain {
            var out: [FoundFile] = []
            walkFiles(in: [home], minSize: 50_000_000) { url, v, size in
                let used = max(v.contentAccessDate ?? .distantPast, v.contentModificationDate ?? .distantPast)
                out.append(FoundFile(path: url.path, size: size, lastUsed: used))
            }
            return out.sorted { $0.size > $1.size }
        }
        scanning = false
        scanned = true
    }

    func trashChosen() async {
        working = true
        let paths = chosen.map(\.path)
        let failed = await offMain { moveToTrash(paths) }
        let gone = Set(paths).subtracting(failed)
        let freed = files.filter { gone.contains($0.path) }.reduce(0) { $0 + $1.size }
        files.removeAll { gone.contains($0.path) }
        picked.subtract(gone)
        working = false
        notice = failed.isEmpty
            ? Notice(text: "Moved \(gone.count) files (\(fmt(freed))) to the Trash. Empty it in Smart Clean to get the space back.")
            : Notice(text: "\(failed.count) file(s) couldn't be moved", ok: false)
    }
}

struct LargeFilesView: View {
    @ObservedObject var m: LargeFilesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Large & Old Files", subtitle: "Big files in your home folder you may have forgotten", icon: "doc.text.magnifyingglass") {
                if m.scanned {
                    Picker("Size", selection: $m.minSize) {
                        Text("50 MB+").tag(Int64(50_000_000))
                        Text("100 MB+").tag(Int64(100_000_000))
                        Text("500 MB+").tag(Int64(500_000_000))
                        Text("1 GB+").tag(Int64(1_000_000_000))
                    }
                    .labelsHidden().fixedSize()
                    Picker("Age", selection: $m.minAgeDays) {
                        Text("Any age").tag(0)
                        Text("Unused 1 month+").tag(30)
                        Text("Unused 3 months+").tag(90)
                        Text("Unused 6 months+").tag(180)
                        Text("Unused 1 year+").tag(365)
                    }
                    .labelsHidden().fixedSize()
                    Button { Task { await m.scan() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Rescan")
                        .accessibilityLabel("Rescan")
                        .disabled(m.scanning || m.working)
                }
            }
            if let n = m.notice { NoticeView(notice: n) }
            if m.scanning {
                Working(text: "Scanning your home folder…")
            } else if !m.scanned {
                ScanPrompt(icon: "doc.text.magnifyingglass", title: "Find large & old files",
                           message: "Looks through your home folder (not system or app data) for big files and shows when you last opened them.",
                           button: "Scan Home Folder") { Task { await m.scan() } }
            } else if m.visible.isEmpty {
                EmptyResult(text: "No files match these filters.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(m.visible) { f in row(f) }
                    }
                }
                ActionBar(summary: "\(m.visible.count) files · \(fmt(m.visible.reduce(0) { $0 + $1.size }))",
                          title: "Move \(m.chosen.count) to Trash · \(fmt(m.chosen.reduce(0) { $0 + $1.size }))",
                          enabled: !m.chosen.isEmpty,
                          busy: m.working) { m.confirming = true }
            }
        }
        .alert("Move \(m.chosen.count) files to the Trash?", isPresented: $m.confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { Task { await m.trashChosen() } }
        } message: {
            Text("You can put them back from the Trash until it's emptied.")
        }
    }

    private func row(_ f: FoundFile) -> some View {
        HStack(spacing: 10) {
            Toggle(fileName(f.path), isOn: m.pick(f.id)).labelsHidden().toggleStyle(.checkbox)
            Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(fileName(f.path)).lineLimit(1).truncationMode(.middle)
                Text(tilde((f.path as NSString).deletingLastPathComponent))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(relative(f.lastUsed)).font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
            Text(fmt(f.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
            RevealButton(path: f.path)
        }
        .card()
    }
}

// MARK: - Duplicates

struct DupeGroup: Identifiable, Sendable {
    let id: String          // SHA-256 of the content
    let size: Int64
    let paths: [String]     // oldest first: that copy is kept by default
}

func contentHash(_ path: String, limit: Int = .max) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    var remaining = limit
    while remaining > 0 {
        // Drain each 1 MB chunk; without the pool every chunk stays alive until the scan ends.
        let more: Bool = autoreleasepool {
            guard let chunk = try? handle.read(upToCount: min(1 << 20, remaining)), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            remaining -= chunk.count
            return true
        }
        if !more { break }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Groups byte-identical files: same size, then same first 64 KB, then same full SHA-256.
func findDuplicates(in roots: [String], minSize: Int64 = 100_000) -> [DupeGroup] {
    var bySize: [Int64: [(path: String, created: Date)]] = [:]
    walkFiles(in: roots, minSize: minSize) { url, v, size in
        bySize[size, default: []].append((url.path, v.creationDate ?? .distantFuture))
    }
    var groups: [DupeGroup] = []
    for (size, files) in bySize where files.count > 1 {
        let byHead = Dictionary(grouping: files) { contentHash($0.path, limit: 65_536) ?? UUID().uuidString }
        for candidates in byHead.values where candidates.count > 1 {
            let byFull = Dictionary(grouping: candidates) { contentHash($0.path) ?? UUID().uuidString }
            for (hash, same) in byFull where same.count > 1 {
                let ordered = same.sorted { ($0.created, $0.path.count) < ($1.created, $1.path.count) }.map { $0.path }
                groups.append(DupeGroup(id: hash, size: size, paths: ordered))
            }
        }
    }
    return groups.sorted { $0.size * Int64($0.paths.count - 1) > $1.size * Int64($1.paths.count - 1) }
}

@MainActor
final class DuplicatesModel: ObservableObject, Picking {
    @Published var folders = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"].map(homePath).filter(isDirectory)
    @Published var groups: [DupeGroup] = []
    @Published var picked: Set<String> = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var working = false
    @Published var confirming = false
    @Published var notice: Notice?

    var wasted: Int64 { groups.reduce(0) { $0 + $1.size * Int64($1.paths.count - 1) } }
    var pickedSize: Int64 { groups.reduce(0) { total, g in total + g.size * Int64(g.paths.filter(picked.contains).count) } }

    func addFolder() { folders += chooseFolders().filter { !folders.contains($0) } }

    func scan() async {
        scanning = true
        notice = nil
        let roots = folders
        groups = await offMain { findDuplicates(in: roots) }
        picked = Set(groups.flatMap { $0.paths.dropFirst() })   // keep the oldest copy of each
        scanning = false
        scanned = true
    }

    func trashPicked() async {
        working = true
        // Never remove every copy: if a whole group is ticked, the oldest copy stays.
        let paths = groups.flatMap { g in
            g.paths.allSatisfy(picked.contains) ? Array(g.paths.dropFirst()) : g.paths.filter(picked.contains)
        }
        let freed = groups.reduce(Int64(0)) { total, g in total + g.size * Int64(g.paths.filter(paths.contains).count) }
        let failed = await offMain { moveToTrash(paths) }
        let gone = Set(paths).subtracting(failed)
        groups = groups.compactMap { g in
            let rest = g.paths.filter { !gone.contains($0) }
            return rest.count > 1 ? DupeGroup(id: g.id, size: g.size, paths: rest) : nil
        }
        picked.subtract(gone)
        working = false
        notice = failed.isEmpty
            ? Notice(text: "Moved \(gone.count) duplicates (\(fmt(freed))) to the Trash")
            : Notice(text: "\(failed.count) file(s) couldn't be moved", ok: false)
    }
}

struct DuplicatesView: View {
    @ObservedObject var m: DuplicatesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Duplicates", subtitle: "Identical files, compared byte for byte", icon: "doc.on.doc") {
                if m.scanned {
                    Button { Task { await m.scan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .disabled(m.scanning || m.working || m.folders.isEmpty)
                }
            }
            FolderChips(folders: $m.folders) { m.addFolder() }
            if let n = m.notice { NoticeView(notice: n) }
            if m.scanning {
                Working(text: "Comparing files. Big folders can take a minute…")
            } else if !m.scanned {
                ScanPrompt(icon: "doc.on.doc", title: "Find duplicate files",
                           message: "Files are matched by size and then a SHA-256 checksum, so only true copies are grouped. The oldest copy of each is kept by default.",
                           button: "Scan for Duplicates") { Task { await m.scan() } }
            } else if m.groups.isEmpty {
                EmptyResult(text: "No duplicates in these folders.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(m.groups) { g in group(g) }
                    }
                }
                ActionBar(summary: "\(m.groups.count) sets of duplicates · \(fmt(m.wasted)) wasted",
                          title: "Move \(m.picked.count) to Trash · \(fmt(m.pickedSize))",
                          enabled: !m.picked.isEmpty,
                          busy: m.working) { m.confirming = true }
            }
        }
        .alert("Move \(m.picked.count) duplicates to the Trash?", isPresented: $m.confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { Task { await m.trashPicked() } }
        } message: {
            Text("At least one copy of every file is always kept.")
        }
    }

    private func group(_ g: DupeGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: g.paths[0])).resizable().frame(width: 24, height: 24)
                Text(fileName(g.paths[0])).fontWeight(.semibold).lineLimit(1)
                Text("\(g.paths.count) copies · \(fmt(g.size)) each").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(Array(g.paths.enumerated()), id: \.element) { i, path in
                HStack(spacing: 8) {
                    Toggle(tilde(path), isOn: m.pick(path)).labelsHidden().toggleStyle(.checkbox)
                    Text(tilde(path)).font(.callout).lineLimit(1).truncationMode(.middle)
                    if i == 0 { Badge(text: "Oldest", color: .green) }
                    Spacer()
                    RevealButton(path: path)
                }
                .padding(.leading, 32)
            }
        }
        .card()
    }
}

// MARK: - Similar Images

struct ImageEdge: Sendable {
    let a: Int
    let b: Int
    let distance: Float
}

let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "bmp"]

/// On-device Vision feature prints for each image, plus every pair closer than `maxDistance`.
func similarImageEdges(in roots: [String], maxDistance: Float,
                       progress: @Sendable (Double) -> Void) -> (paths: [String], edges: [ImageEdge]) {
    var candidates: [String] = []
    walkFiles(in: roots, minSize: 20_000) { url, _, _ in
        if imageExtensions.contains(url.pathExtension.lowercased()) { candidates.append(url.path) }
    }
    // ponytail: pairwise comparison is O(n²), so cap at 3000 images; use a vector index if that's too few.
    candidates = Array(candidates.prefix(3000))
    var paths: [String] = []
    var prints: [VNFeaturePrintObservation] = []
    for (i, path) in candidates.enumerated() {
        let request = VNGenerateImageFeaturePrintRequest()
        if (try? VNImageRequestHandler(url: URL(fileURLWithPath: path)).perform([request])) != nil,
           let print = request.results?.first {
            paths.append(path)
            prints.append(print)
        }
        if i % 10 == 0 { progress(0.95 * Double(i) / Double(max(1, candidates.count))) }
    }
    var edges: [ImageEdge] = []
    for i in prints.indices {
        for j in (i + 1)..<prints.count {
            var d: Float = 0
            if (try? prints[i].computeDistance(&d, to: prints[j])) != nil, d <= maxDistance {
                edges.append(ImageEdge(a: i, b: j, distance: d))
            }
        }
    }
    progress(1)
    return (paths, edges)
}

@MainActor
final class SimilarImagesModel: ObservableObject, Picking {
    @Published var folders = ["Pictures", "Desktop", "Downloads", "Documents"].map(homePath).filter(isDirectory)
    @Published var threshold: Double = 0.3   // Vision distance: re-saves ≈0.05, crops ≈0.45, unrelated ≥0.6
    @Published var groups: [[String]] = []
    @Published var picked: Set<String> = []
    @Published var progress: Double = 0
    @Published var scanning = false
    @Published var scanned = false
    @Published var working = false
    @Published var confirming = false
    @Published var notice: Notice?
    private var paths: [String] = []
    private var edges: [ImageEdge] = []

    nonisolated static let maxThreshold: Double = 0.6

    func addFolder() { folders += chooseFolders().filter { !folders.contains($0) } }

    func scan() async {
        scanning = true
        progress = 0
        notice = nil
        picked = []
        let roots = folders
        let report: @Sendable (Double) -> Void = { [weak self] value in Task { @MainActor in self?.progress = value } }
        let result = await offMain { similarImageEdges(in: roots, maxDistance: Float(Self.maxThreshold), progress: report) }
        paths = result.paths
        edges = result.edges
        regroup()
        scanning = false
        scanned = true
    }

    /// Regroups from the stored pairs, so the strictness slider updates instantly. An image joins a group
    /// only if it is similar to *every* member; chaining (A≈B, B≈C ⇒ A,C together) built groups of unrelated images.
    func regroup() {
        var near: [Int: [Int: Float]] = [:]
        for e in edges where Double(e.distance) <= threshold {
            near[e.a, default: [:]][e.b] = e.distance
            near[e.b, default: [:]][e.a] = e.distance
        }
        // Seed from the images with the most close matches so dense clusters form around their centre.
        let seeds = near.keys.sorted { (near[$0]!.count, $1) > (near[$1]!.count, $0) }
        var assigned = Set<Int>()
        var result: [[String]] = []
        for seed in seeds where !assigned.contains(seed) {
            var members = [seed]
            for (candidate, _) in near[seed]!.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) })
            where !assigned.contains(candidate) && members.allSatisfy({ near[candidate]?[$0] != nil }) {
                members.append(candidate)
            }
            guard members.count > 1 else { continue }
            assigned.formUnion(members)
            result.append(members.map { paths[$0] })
        }
        groups = result.sorted { $0.count > $1.count }
        picked = picked.intersection(groups.flatMap { $0 })
    }

    func trashPicked() async {
        working = true
        let chosen = Array(picked)
        let failed = await offMain { moveToTrash(chosen) }
        let gone = Set(chosen).subtracting(failed)
        let keep = paths.indices.filter { !gone.contains(paths[$0]) }
        let remap = Dictionary(uniqueKeysWithValues: keep.enumerated().map { ($1, $0) })
        edges = edges.compactMap { e in
            guard let a = remap[e.a], let b = remap[e.b] else { return nil }
            return ImageEdge(a: a, b: b, distance: e.distance)
        }
        paths = keep.map { paths[$0] }
        picked.subtract(gone)
        regroup()
        working = false
        notice = failed.isEmpty
            ? Notice(text: "Moved \(gone.count) images to the Trash")
            : Notice(text: "\(failed.count) image(s) couldn't be moved", ok: false)
    }
}

@MainActor
final class ThumbLoader: ObservableObject {
    @Published var image: NSImage?

    func load(_ path: String, pixels: Int) async {
        guard image == nil else { return }
        let cg = await offMain { () -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceThumbnailMaxPixelSize: pixels,
                                         kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        if let cg { image = NSImage(cgImage: cg, size: .zero) }
    }
}

struct Thumb: View {
    let path: String
    var side: CGFloat = 132
    @StateObject var loader = ThumbLoader()

    var body: some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let image = loader.image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: path) { await loader.load(path, pixels: Int(side * 2)) }
    }
}

struct SimilarImagesView: View {
    @ObservedObject var m: SimilarImagesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Similar Images", subtitle: "Near-identical photos and screenshots, found on-device", icon: "photo.on.rectangle.angled") {
                if m.scanned {
                    Button { Task { await m.scan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .disabled(m.scanning || m.working || m.folders.isEmpty)
                }
            }
            FolderChips(folders: $m.folders) { m.addFolder() }
            if let n = m.notice { NoticeView(notice: n) }
            if m.scanning {
                Working(text: "Analyzing images…", progress: m.progress)
            } else if !m.scanned {
                ScanPrompt(icon: "photo.on.rectangle.angled", title: "Find similar images",
                           message: "Uses Apple's Vision framework on your Mac to find bursts, edits and re-saved copies. Nothing leaves your Mac, and nothing is selected for you.",
                           button: "Scan Images") { Task { await m.scan() } }
            } else {
                HStack(spacing: 10) {
                    Text("Strict").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $m.threshold, in: 0.05...SimilarImagesModel.maxThreshold).frame(width: 220)
                        .accessibilityLabel("Match strictness")
                    Text("Loose").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(m.groups.count) groups").font(.callout).foregroundStyle(.secondary)
                }
                if m.groups.isEmpty {
                    EmptyResult(text: "No similar images at this setting.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(m.groups, id: \.self) { g in groupView(g) }
                        }
                    }
                    ActionBar(summary: "Click a photo to select it",
                              title: "Move \(m.picked.count) to Trash",
                              enabled: !m.picked.isEmpty,
                              busy: m.working) { m.confirming = true }
                }
            }
        }
        .onChange(of: m.threshold) { m.regroup() }
        .alert("Move \(m.picked.count) images to the Trash?", isPresented: $m.confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { Task { await m.trashPicked() } }
        } message: {
            Text("You can put them back from the Trash until it's emptied.")
        }
    }

    private func groupView(_ g: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(g.count) similar images").font(.callout.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(g, id: \.self) { path in
                        let on = m.picked.contains(path)
                        VStack(spacing: 4) {
                            Thumb(path: path)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(on ? Color.red : Color.clear, lineWidth: 3))
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: on ? "trash.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(on ? Color.red : Color.white)
                                        .shadow(radius: 2)
                                        .padding(6)
                                }
                                .onTapGesture { m.toggle(path) }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(fileName(path))
                                .accessibilityValue(on ? "Selected for Trash" : "Not selected")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { m.toggle(path) }
                                .contextMenu {
                                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                                    Button("Show in Finder") { reveal(path) }
                                }
                            Text(fileName(path)).font(.caption).lineLimit(1).truncationMode(.middle).frame(width: 132)
                        }
                    }
                }
            }
        }
        .card()
    }
}
