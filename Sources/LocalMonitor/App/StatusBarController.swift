import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let model: LocalMonitorModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var statusSymbolCache: [String: NSImage] = [:]
    private let statusSymbolConfig = NSImage.SymbolConfiguration(
        pointSize: LocalMenuBarDisplay.iconPointSize,
        weight: .medium
    )

    init(model: LocalMonitorModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentSize = NSSize(width: 420, height: 620)
        popover.contentViewController = NSHostingController(
            rootView: StatusPanelView(model: model) { [weak self] in
                self?.chooseAndAddProject()
            }
                .frame(width: 420, height: 620)
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        model.$menuBarTitle
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                self?.updateMenuBarButton(title)
            }
            .store(in: &cancellables)

        updateMenuBarButton(model.menuBarTitle)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                window.makeKey()
            }
            Task { await model.refresh() }
        }
    }

    private func chooseAndAddProject() {
        popover.performClose(nil)
        DispatchQueue.main.async { [weak self] in
            self?.model.chooseAndAddProject()
        }
    }

    private func updateMenuBarButton(_ title: MenuBarTitle) {
        guard let button = statusItem.button else { return }

        let image = renderStatusImage(title)
        statusItem.length = image.size.width
        button.image = image
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.title = ""
        button.toolTip = title.tooltip
    }

    private func renderStatusImage(_ title: MenuBarTitle) -> NSImage {
        let text = title.displayMode == .count ? title.countText : nil
        let width = LocalMenuBarDisplay.contentWidth(text: text)
        let height = LocalMenuBarDisplay.statusHeight
        let image = NSImage(size: NSSize(width: width, height: height))

        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let symbolName = title.runningCount > 0 ? "server.rack" : "terminal"
        drawSymbol(symbolName, x: LocalMenuBarDisplay.horizontalPadding, canvasHeight: height)

        if let text {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: LocalMenuBarDisplay.textFont,
                .foregroundColor: NSColor.black
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let textX = LocalMenuBarDisplay.horizontalPadding
                + LocalMenuBarDisplay.iconWidth
                + LocalMenuBarDisplay.iconTextSpacing
            let textY = floor((height - textSize.height) / 2)

            (text as NSString).draw(
                at: NSPoint(x: textX, y: textY),
                withAttributes: attributes
            )
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func drawSymbol(_ symbolName: String, x: CGFloat, canvasHeight: CGFloat) {
        let symbol: NSImage
        if let cached = statusSymbolCache[symbolName] {
            symbol = cached
        } else if let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Local Monitor"
        )?.withSymbolConfiguration(statusSymbolConfig) {
            statusSymbolCache[symbolName] = image
            symbol = image
        } else {
            return
        }

        let symbolSize = symbol.size
        let rect = NSRect(
            x: x + (LocalMenuBarDisplay.iconWidth - symbolSize.width) / 2,
            y: floor((canvasHeight - symbolSize.height) / 2),
            width: symbolSize.width,
            height: symbolSize.height
        )
        symbol.draw(in: rect)
    }
}

private enum LocalMenuBarDisplay {
    static let statusHeight: CGFloat = 22
    static let horizontalPadding: CGFloat = 2
    static let iconWidth: CGFloat = 14
    static let iconTextSpacing: CGFloat = 4
    static let iconPointSize: CGFloat = 13
    static let textPointSize: CGFloat = 12
    static let textFont = NSFont.monospacedSystemFont(ofSize: textPointSize, weight: .bold)

    static func contentWidth(text: String?) -> CGFloat {
        guard let text, !text.isEmpty else {
            return ceil(statusHeight)
        }

        let textWidth = (text as NSString).size(withAttributes: [.font: textFont]).width
        return ceil(horizontalPadding * 2 + iconWidth + iconTextSpacing + textWidth)
    }
}
