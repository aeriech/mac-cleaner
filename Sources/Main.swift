import SwiftUI

@main
struct MacCleanerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Mac Cleaner") {
            RootView(app: model)
                .frame(minWidth: 940, minHeight: 640)
        }
        .defaultSize(width: 1100, height: 740)
    }
}
