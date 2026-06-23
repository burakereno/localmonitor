import AppKit
import Combine

extension Notification.Name {
    static let localMonitorDockSettingsChanged = Notification.Name("LocalMonitorDockSettingsChanged")
}

enum DockIconPreference {
    static var showDockIcon: Bool {
        UserDefaults.standard.object(forKey: AppPreference.showDockIconKey) as? Bool ?? false
    }

    static var showDockValues: Bool {
        UserDefaults.standard.object(forKey: AppPreference.showDockValuesKey) as? Bool ?? false
    }
}

@MainActor
final class DockIconController {
    static let shared = DockIconController()

    private var cancellables = Set<AnyCancellable>()
    private var currentActivationPolicy: NSApplication.ActivationPolicy?
    private var latestTitle = MenuBarTitle(
        runningCount: 0,
        totalCount: 0,
        externalCount: 0,
        displayMode: .count
    )
    private var lastDockState: DockState?

    private init() {}

    func start(model: LocalMonitorModel) {
        latestTitle = model.menuBarTitle
        applyActivationPolicy()
        updateDockTile(force: true)

        model.$menuBarTitle
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                Task { @MainActor in
                    self?.latestTitle = title
                    self?.updateDockTile()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.settingsChanged()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .localMonitorDockSettingsChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.settingsChanged()
                }
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        clearDockTile()
    }

    func settingsChanged() {
        applyActivationPolicy()
        updateDockTile(force: true)
    }

    private func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = DockIconPreference.showDockIcon ? .regular : .accessory
        guard currentActivationPolicy != policy else { return }

        NSApp.setActivationPolicy(policy)
        currentActivationPolicy = policy

        if policy == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func updateDockTile(force: Bool = false) {
        guard DockIconPreference.showDockIcon, DockIconPreference.showDockValues else {
            clearDockTile()
            return
        }

        let state = DockState(label: latestTitle.countText)
        guard force || lastDockState != state else { return }

        lastDockState = state
        NSApp.dockTile.badgeLabel = state.label
        NSApp.dockTile.display()
    }

    private func clearDockTile() {
        guard lastDockState != nil || NSApp.dockTile.badgeLabel != nil else { return }
        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.display()
        lastDockState = nil
    }
}

private struct DockState: Equatable {
    let label: String
}
