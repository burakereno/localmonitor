import AppKit
import SwiftUI

@MainActor
final class WorkspaceImportWindowController: NSWindowController {
    init(workspace: WorkspaceImport, onAdd: @escaping ([ProjectLaunchProfile]) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 340),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Workspace Apps"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: WorkspaceImportView(
            workspace: workspace,
            onAdd: { [weak window] profiles in onAdd(profiles); window?.close() },
            onCancel: { [weak window] in window?.close() }
        ))
        window.center()
    }

    required init?(coder: NSCoder) { return nil }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
