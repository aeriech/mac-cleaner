// Window layout: sidebar of tools on the left, the selected tool on the right.
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case smartClean, appData, largeFiles, duplicates, similarImages, uninstaller, leftovers, performance, backgroundItems, storage
    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartClean: "Smart Clean"
        case .appData: "App Data"
        case .largeFiles: "Large & Old Files"
        case .duplicates: "Duplicates"
        case .similarImages: "Similar Images"
        case .uninstaller: "Uninstaller"
        case .leftovers: "Leftovers"
        case .performance: "Performance"
        case .backgroundItems: "Background Items"
        case .storage: "Storage"
        }
    }

    var icon: String {
        switch self {
        case .smartClean: "sparkles"
        case .appData: "square.stack.3d.up"
        case .largeFiles: "doc.text.magnifyingglass"
        case .duplicates: "doc.on.doc"
        case .similarImages: "photo.on.rectangle.angled"
        case .uninstaller: "xmark.app"
        case .leftovers: "folder.badge.minus"
        case .performance: "gauge.with.dots.needle.50percent"
        case .backgroundItems: "checkmark.shield"
        case .storage: "internaldrive"
        }
    }
}

/// Owns one model per page so scan results survive switching pages.
@MainActor
final class AppModel: ObservableObject {
    @Published var page: Page? = .smartClean
    @Published var volume = volumeInfo()
    let clean = CleanModel()
    let appData = AppDataModel()
    let large = LargeFilesModel()
    let duplicates = DuplicatesModel()
    let similar = SimilarImagesModel()
    let uninstaller = UninstallerModel()
    let leftovers = LeftoversModel()
    let performance = PerformanceModel()
    let background = BackgroundItemsModel()
    let storage = StorageModel()
}

struct RootView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $app.page) {
                Section("Cleanup") { item(.smartClean); item(.appData); item(.largeFiles); item(.duplicates); item(.similarImages) }
                Section("Applications") { item(.uninstaller); item(.leftovers) }
                Section("Speed & Safety") { item(.performance); item(.backgroundItems) }
                Section("Overview") { item(.storage) }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
            .safeAreaInset(edge: .top, spacing: 0) { brandHeader }
            .safeAreaInset(edge: .bottom, spacing: 0) { diskFooter }
        } detail: {
            detail
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .toolbar(removing: .title)
        .task {
            // Keep the sidebar's free-space meter current while cleaning elsewhere.
            while !Task.isCancelled {
                app.volume = volumeInfo()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func item(_ page: Page) -> some View {
        Label(page.title, systemImage: page.icon).tag(page)
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 0) {
                Text("Mac Cleaner").font(.headline)
                Text("Keep your Mac tidy").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var diskFooter: some View {
        let v = app.volume
        return VStack(alignment: .leading, spacing: 6) {
            Label(v.name, systemImage: "internaldrive").font(.caption.weight(.semibold))
            ProgressView(value: v.total > 0 ? Double(v.used) / Double(v.total) : 0)
                .tint(v.free < v.total / 10 ? .orange : .blue)
            Text("\(fmt(v.free)) free of \(fmt(v.total))").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    @ViewBuilder private var detail: some View {
        switch app.page ?? .smartClean {
        case .smartClean: SmartCleanView(m: app.clean)
        case .appData: AppDataView(m: app.appData)
        case .largeFiles: LargeFilesView(m: app.large)
        case .duplicates: DuplicatesView(m: app.duplicates)
        case .similarImages: SimilarImagesView(m: app.similar)
        case .uninstaller: UninstallerView(m: app.uninstaller)
        case .leftovers: LeftoversView(m: app.leftovers)
        case .performance: PerformanceView(m: app.performance)
        case .backgroundItems: BackgroundItemsView(m: app.background)
        case .storage: StorageView(m: app.storage)
        }
    }
}
