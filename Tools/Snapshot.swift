// Dev aid: renders one page of the app to a PNG in-process (no screen-recording permission needed).
//   swiftc -parse-as-library $(ls Sources/*.swift | grep -v Main.swift) Tools/Snapshot.swift -o build/snapshot
//   build/snapshot <page> <out.png> [--dark] [--wait=6]
import AppKit
import SwiftUI

@main
struct Snapshot {
    @MainActor static func main() {
        let args = CommandLine.arguments
        let page = Page(rawValue: args.count > 1 ? args[1] : "") ?? .smartClean
        let out = args.count > 2 ? args[2] : "snapshot.png"
        let wait = Double(args.first { $0.hasPrefix("--wait=") }?.dropFirst(7) ?? "") ?? 6

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel()
        model.page = page
        let size = NSSize(width: 1100, height: 740)
        // On screen but fully transparent and click-through: offscreen windows lay out incorrectly.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: RootView(app: model).background(Color(nsColor: .windowBackgroundColor)))
        host.sizingOptions = []   // keep the window at `size` instead of growing to fit content
        window.contentView = host
        window.setContentSize(size)
        window.orderFrontRegardless()
        if args.contains("--scan") {   // start the manual scan on pages that need a click
            Task {
                switch page {
                case .leftovers: await model.leftovers.scan()
                case .largeFiles: await model.large.scan()
                default: break
                }
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        if let name = args.first(where: { $0.hasPrefix("--select=") })?.dropFirst(9) {   // pick an app in Uninstaller
            model.uninstaller.selection = model.uninstaller.apps.first { $0.name == name }?.path
            RunLoop.main.run(until: Date().addingTimeInterval(6))
            for f in model.uninstaller.related { print("related:", f.kind, tilde(f.path), fmt(f.size)) }
        }
        if page == .backgroundItems { print("background scanned:", model.background.scanned, "items:", model.background.items.count) }
        if page == .leftovers { for l in model.leftovers.items { print("leftover:", l.identifier, l.kinds, fmt(l.size)) } }

        let view = window.contentView!
        func tables(_ v: NSView) -> [NSTableView] { (v as? NSTableView).map { [$0] } ?? [] + v.subviews.flatMap(tables) }
        for t in tables(view) { print("\(type(of: t)) rows:", t.numberOfRows) }
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("wrote \(out)")
        exit(0)
    }
}
