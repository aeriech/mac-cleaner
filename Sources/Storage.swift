// Storage overview: how full the disk is and which folders use the space.
import SwiftUI

struct VolumeInfo: Sendable {
    var name = "Macintosh HD"
    var total: Int64 = 0
    var free: Int64 = 0
    var used: Int64 { max(0, total - free) }
}

func volumeInfo() -> VolumeInfo {
    let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                     .volumeAvailableCapacityForImportantUsageKey]
    guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return VolumeInfo() }
    return VolumeInfo(name: v.volumeLocalizedName ?? "Macintosh HD",
                      total: Int64(v.volumeTotalCapacity ?? 0),
                      free: v.volumeAvailableCapacityForImportantUsage ?? 0)
}

struct StorageSlice: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let icon: String
    var size: Int64 = 0
    var scanning = true
}

@MainActor
final class StorageModel: ObservableObject {
    @Published var volume = VolumeInfo()
    @Published var slices: [StorageSlice] = []
    @Published var scanning = false

    static let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .green, .yellow]

    var measured: Int64 { slices.reduce(0) { $0 + $1.size } }
    var other: Int64 { scanning ? 0 : max(0, volume.used - measured) }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        volume = volumeInfo()
        slices = [
            StorageSlice(id: "apps", name: "Applications", path: "/Applications", icon: "square.grid.2x2"),
            StorageSlice(id: "docs", name: "Documents", path: homePath("Documents"), icon: "doc"),
            StorageSlice(id: "desktop", name: "Desktop", path: homePath("Desktop"), icon: "menubar.dock.rectangle"),
            StorageSlice(id: "downloads", name: "Downloads", path: homePath("Downloads"), icon: "arrow.down.circle"),
            StorageSlice(id: "pictures", name: "Pictures", path: homePath("Pictures"), icon: "photo"),
            StorageSlice(id: "movies", name: "Movies", path: homePath("Movies"), icon: "film"),
            StorageSlice(id: "music", name: "Music", path: homePath("Music"), icon: "music.note"),
            StorageSlice(id: "library", name: "App data & caches", path: homePath("Library"), icon: "building.columns"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        for i in slices.indices {
            let path = slices[i].path
            slices[i].size = await offMain { diskUsage(path) }
            slices[i].scanning = false
        }
        scanning = false
    }
}

struct StorageView: View {
    @ObservedObject var m: StorageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Storage", subtitle: "See what's taking up space on \(m.volume.name)", icon: "internaldrive") {
                Button { Task { await m.scan() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(m.scanning)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(fmt(m.volume.used)).font(.system(size: 34, weight: .bold, design: .rounded))
                Text("used of \(fmt(m.volume.total))").foregroundStyle(.secondary)
                Spacer()
                Text("\(fmt(m.volume.free)) available").font(.title3.weight(.semibold)).foregroundStyle(.green)
            }
            bar
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(m.slices.enumerated()), id: \.element.id) { i, slice in
                        sliceRow(slice, color: StorageModel.palette[i % StorageModel.palette.count])
                    }
                    otherRow
                }
            }
        }
        .task { if m.slices.isEmpty { await m.scan() } }
    }

    private var bar: some View {
        GeometryReader { g in
            let total = Double(max(1, m.volume.total))
            HStack(spacing: 0) {
                ForEach(Array(m.slices.enumerated()), id: \.element.id) { i, slice in
                    Rectangle()
                        .fill(StorageModel.palette[i % StorageModel.palette.count].gradient)
                        .frame(width: g.size.width * Double(slice.size) / total)
                }
                Rectangle().fill(Color.gray.opacity(0.5)).frame(width: g.size.width * Double(m.other) / total)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 26)
        .background(Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(.easeOut, value: m.measured)
    }

    private func sliceRow(_ s: StorageSlice, color: Color) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: s.icon, tint: color)
            Text(s.name).fontWeight(.medium)
            Spacer()
            if s.scanning {
                ProgressView().controlSize(.small)
            } else {
                Text(fmt(s.size)).monospacedDigit().foregroundStyle(.secondary)
                Text(percent(s.size)).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    .frame(width: 40, alignment: .trailing)
            }
            RevealButton(path: s.path)
        }
        .card()
    }

    private var otherRow: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "gearshape.2", tint: .gray)
            VStack(alignment: .leading, spacing: 2) {
                Text("System & other").fontWeight(.medium)
                Text("macOS, other folders in your home, snapshots and purgeable space")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(m.scanning ? "…" : fmt(m.other)).monospacedDigit().foregroundStyle(.secondary)
        }
        .card()
    }

    private func percent(_ bytes: Int64) -> String {
        m.volume.total > 0 ? String(format: "%.0f%%", Double(bytes) / Double(m.volume.total) * 100) : ""
    }
}
