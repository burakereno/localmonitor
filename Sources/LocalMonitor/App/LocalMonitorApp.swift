import AppKit
import SwiftUI

@main
struct LocalMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusBarController?
    private let model = LocalMonitorPreview.makeModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        DockIconController.shared.settingsChanged()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if LocalMonitorPreview.showIfRequested(model: model) {
            model.start()
            return
        }
        NotificationService.shared.prepare()
        statusController = StatusBarController(model: model)
        DockIconController.shared.start(model: model)
        model.start()
        UpdateChecker.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DockIconController.shared.stop()
        UpdateChecker.shared.stop()
        model.shutdown()
    }
}
