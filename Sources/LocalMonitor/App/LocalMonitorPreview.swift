import AppKit
import SwiftUI

/// An opt-in debug window uses isolated fixture data; release builds ignore this environment variable.
@MainActor
enum LocalMonitorPreview {
    private static var window: NSWindow?

    static func makeModel() -> LocalMonitorModel {
        #if DEBUG
        if let directory = directory {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: AppPreference.scanExternalPortsKey)
            defaults.set(false, forKey: AppPreference.notificationsKey)
            let manager = ProjectProcessManager(userDefaults: defaults, storageDirectoryURL: directory.appendingPathComponent("Logs"))
            var checker = PreflightChecker()
            checker.dependencyInstallation.storageRoot = directory.appendingPathComponent("Installs")
            checker.packageRuntimeResolver.shimRoot = directory.appendingPathComponent("Tools")
            let model = LocalMonitorModel(store: ProjectStore(storageDirectoryURL: directory), preflightChecker: checker,
                                           healthChecksEnabled: false, processManager: manager, userDefaults: defaults)
            model.dependencyInstallation = checker.dependencyInstallation
            return model
        }
        #endif
        return LocalMonitorModel()
    }

    static func showIfRequested(model: LocalMonitorModel) -> Bool {
        #if DEBUG
        guard directory != nil else { return false }
        model.selectedLogProjectID = model.projects.first?.id
        let root = StatusPanelView(model: model, onAddProject: {}).frame(width: 420, height: 840)
        let preview = NSWindow(contentViewController: NSHostingController(rootView: root))
        preview.title = "Local Monitor — Local Preview"
        preview.setContentSize(NSSize(width: 420, height: 840))
        preview.styleMask = [.titled, .closable, .miniaturizable]
        preview.isReleasedWhenClosed = false
        window = preview
        NSApp.setActivationPolicy(.regular)
        preview.center(); preview.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let project = model.projects.first { Task { await model.checkRequirements(for: project) } }
        return true
        #else
        return false
        #endif
    }

    private static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["LOCALMONITOR_PREVIEW_DIRECTORY"], path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
