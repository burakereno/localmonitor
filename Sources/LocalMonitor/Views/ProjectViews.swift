import AppKit
import SwiftUI

struct ProjectCardView: View {
    let project: LocalProject
    let state: ProjectRuntimeState
    let identity: ProjectIdentity?
    let preflight: PreflightResult?
    let conflict: DiscoveredPort?
    let cleanRestartState: CleanRestartState?
    let cacheState: ProjectCacheState?
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    let onCleanRestart: () -> Void
    let onOpen: () -> Void
    let onCopyURL: () -> Void
    let onLogs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                ProjectAvatarView(project: project, tint: kindTint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.displayName)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)

                    Text(project.compactPath)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    ProjectStartButton(
                        status: state.status,
                        disabled: startDisabled,
                        action: onStart
                    )

                    IconActionButton(
                        systemName: "stop.fill",
                        help: "Stop",
                        tint: .red,
                        disabled: stopDisabled,
                        action: onStop
                    )

                    IconActionButton(
                        systemName: "arrow.clockwise",
                        help: "Restart",
                        tint: .orange,
                        disabled: state.status == .starting || cleanRestartState?.isActive == true,
                        action: onRestart
                    )
                }
            }

            HStack(spacing: 6) {
                ProjectKindChip(kind: project.kind)
                MetadataChip(icon: "number", text: "\(project.port)")
                if let branch = identity?.branch {
                    MetadataChip(icon: "arrow.triangle.branch", text: branch)
                }
                if let startedAt = state.startedAt, showsUptime {
                    UptimeChipView(startedAt: startedAt, kind: project.kind, status: state.status)
                }
                Spacer()

                IconActionButton(systemName: "safari", help: "Open Localhost", action: onOpen)
                IconActionButton(systemName: "link", help: "Copy Localhost URL", action: onCopyURL)
                IconActionButton(systemName: "doc.text.magnifyingglass", help: "Show Logs", action: onLogs)
            }

            if project.kind.supportsCleanRestart {
                CacheControlRowView(
                    cacheState: cacheState,
                    operationState: cacheOperationState,
                    action: onCleanRestart
                )
            }

            if let preflight, !preflight.issues.isEmpty {
                Text(preflight.summary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(preflight.isClear ? .orange : .red)
                    .lineLimit(2)
            }

            if let conflict {
                Text("Port \(project.port) is used by \(conflict.displayOwner).")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(9)
                    .background {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.orange.opacity(0.08))
                    }
            }

            if state.status == .portMismatch, let observedPort = state.observedPort {
                Text("Expected \(project.port), running on \(observedPort).")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(9)
                    .background {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.orange.opacity(0.08))
                    }
            }

            if state.status == .noResponse {
                Text(state.lastMessage ?? "Port is open, but localhost is not responding.")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(9)
                    .background {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.red.opacity(0.08))
                    }
            }

        }
        .padding(12)
        .localCardBackground()
    }

    private var kindTint: Color {
        switch project.kind {
        case .nextjs:
            return .primary
        case .hono:
            return .orange
        case .vite, .supabase:
            return .green
        case .astro, .storybook:
            return .purple
        case .remix, .sveltekit, .nuxt:
            return .blue
        case .expo:
            return .cyan
        case .prisma:
            return .indigo
        case .unknown:
            return .blue
        }
    }

    private var startDisabled: Bool {
        switch state.status {
        case .running, .starting, .portMismatch, .noPort, .noResponse:
            return true
        case .stopped, .portBusy, .crashed:
            return cleanRestartState?.isActive == true
        }
    }

    private var stopDisabled: Bool {
        switch state.status {
        case .stopped, .portBusy:
            return true
        case .starting, .running, .portMismatch, .noPort, .noResponse, .crashed:
            return false
        }
    }

    private var showsUptime: Bool {
        switch state.status {
        case .running, .starting, .portMismatch, .noPort, .noResponse:
            return true
        case .stopped, .portBusy, .crashed:
            return false
        }
    }

    private var cacheOperationState: CleanRestartState? {
        guard cleanRestartState?.operation == .cacheClean else { return nil }
        return cleanRestartState
    }
}

struct ProjectStartButton: View {
    let status: ProjectRunStatus
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    @ViewBuilder
    private var content: some View {
        if showsStatusPill {
            HStack(spacing: 5) {
                if status == .starting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 10, height: 10)
                } else if status == .running {
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 9, weight: .bold))
                }

                Text(status.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(tint.opacity(0.10))
            }
        } else {
            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.45) : Color.green)
                .frame(width: 24, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(disabled ? 0.035 : 0.065))
                }
        }
    }

    private var showsStatusPill: Bool {
        switch status {
        case .starting, .running, .portMismatch, .noPort, .noResponse:
            return true
        case .stopped, .portBusy, .crashed:
            return false
        }
    }

    private var tint: Color {
        switch status {
        case .running:
            return .green
        case .starting, .portMismatch, .noPort:
            return .orange
        case .noResponse:
            return .red
        case .crashed:
            return .red
        case .stopped, .portBusy:
            return .secondary
        }
    }

    private var iconName: String {
        switch status {
        case .portMismatch:
            return "arrow.left.arrow.right"
        case .noPort:
            return "network.slash"
        case .noResponse:
            return "wifi.exclamationmark"
        case .starting:
            return "hourglass"
        case .running:
            return "checkmark.circle"
        case .stopped:
            return "play.fill"
        case .portBusy:
            return "exclamationmark.triangle"
        case .crashed:
            return "xmark.octagon"
        }
    }

    private var helpText: String {
        showsStatusPill ? status.displayName : "Start"
    }
}

struct ProjectInlineStatusChip: View {
    let status: ProjectRunStatus

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .font(.system(size: 9, weight: .bold))

            Text(status.displayName)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(tint.opacity(0.10))
        }
        .help(status.displayName)
    }

    private var tint: Color {
        switch status {
        case .starting, .portMismatch, .noPort:
            return .orange
        case .running:
            return .green
        case .noResponse, .crashed:
            return .red
        case .stopped, .portBusy:
            return .secondary
        }
    }

    private var iconName: String {
        switch status {
        case .portMismatch:
            return "arrow.left.arrow.right"
        case .noPort:
            return "network.slash"
        case .noResponse:
            return "wifi.exclamationmark"
        case .starting:
            return "hourglass"
        case .running:
            return "checkmark.circle"
        case .stopped:
            return "stop.circle"
        case .portBusy:
            return "exclamationmark.triangle"
        case .crashed:
            return "xmark.octagon"
        }
    }
}

struct UptimeChipView: View {
    let startedAt: Date
    let kind: ProjectKind
    let status: ProjectRunStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusTint)
                .frame(width: 7, height: 7)
                .overlay {
                    Circle()
                        .stroke(statusTint.opacity(0.35), lineWidth: 2)
                }
                .accessibilityHidden(true)

            Text(uptimeText)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(uptimeTint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(uptimeTint.opacity(0.10))
        }
        .help(helpText)
    }

    private var elapsed: TimeInterval {
        max(0, Date().timeIntervalSince(startedAt))
    }

    private var uptimeText: String {
        let minutes = Int(elapsed / 60)
        let hours = Int(elapsed / 3_600)
        let days = Int(elapsed / 86_400)
        let limitDays = Int(kind.uptimeLimit / 86_400)

        if elapsed >= kind.uptimeLimit {
            return "\(limitDays)d+"
        }

        if minutes < 60 {
            return "\(max(minutes, 1))m"
        }

        if hours < 24 {
            return "\(hours)h"
        }

        let remainingHours = (hours % 24)
        return remainingHours == 0 ? "\(days)d" : "\(days)d \(remainingHours)h"
    }

    private var uptimeTint: Color {
        let ratio = min(max(elapsed / kind.uptimeLimit, 0), 1)

        switch ratio {
        case 0..<0.25:
            return .green
        case 0.25..<0.55:
            return .yellow
        case 0.55..<0.85:
            return .orange
        default:
            return .red
        }
    }

    private var statusTint: Color {
        switch status {
        case .running:
            return .green
        case .starting, .portBusy, .portMismatch, .noPort:
            return .orange
        case .noResponse, .crashed:
            return .red
        case .stopped:
            return .secondary.opacity(0.75)
        }
    }

    private var helpText: String {
        let limitDays = Int(kind.uptimeLimit / 86_400)
        if elapsed >= kind.uptimeLimit * 0.85 {
            return "Running for \(uptimeText). Cache clean recommended near \(limitDays)d."
        }

        return "Running for \(uptimeText). Recommended max: \(limitDays)d."
    }
}

struct CacheControlRowView: View {
    let cacheState: ProjectCacheState?
    let operationState: CleanRestartState?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: buttonIconName)
                        .font(.system(size: 9, weight: .bold))

                    Text("Cache")
                        .font(.system(size: 10, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundStyle(buttonDisabled ? Color.secondary : tint)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(tint.opacity(buttonDisabled ? 0.07 : 0.14))
                }
            }
            .buttonStyle(.plain)
            .disabled(buttonDisabled)
            .help(buttonHelp)
            .accessibilityLabel("Cache")

            Text(sizeText)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(textTint)
                .lineLimit(1)
                .frame(minWidth: 56, alignment: .leading)

            CacheUsageBarView(ratio: barRatio, tint: tint)

            Text(limitText)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(trailingTint)
                .lineLimit(1)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(tint.opacity(0.065))
        }
        .help(helpText)
    }

    private var sizeText: String {
        if let operationState {
            switch operationState.phase {
            case .done:
                return operationState.message
            case .failed:
                return "Failed"
            case .stopping, .cleaning, .starting, .checking:
                return operationState.message
            }
        }

        guard let cacheState else { return "Measuring" }
        return Self.formatter.string(fromByteCount: cacheState.bytes)
    }

    private var limitText: String {
        if let operationState {
            switch operationState.phase {
            case .done:
                return "Done"
            case .failed:
                return "Error"
            case .stopping, .cleaning, .starting, .checking:
                return "\(Int((operationState.progress * 100).rounded()))%"
            }
        }

        guard let cacheState else { return "" }
        return Self.formatter.string(fromByteCount: cacheState.limitBytes)
    }

    private var helpText: String {
        if let operationState {
            return operationState.message
        }

        guard let cacheState else {
            return "Measuring cache size"
        }

        let percent = Int((cacheState.fillRatio * 100).rounded())
        return "\(sizeText) cache, \(percent)% of \(limitText) scale"
    }

    private var tint: Color {
        if let operationState {
            switch operationState.phase {
            case .done:
                return .green
            case .failed:
                return .red
            case .stopping, .cleaning, .starting, .checking:
                return .orange
            }
        }

        guard let cacheState else { return .green }

        switch cacheState.fillRatio {
        case 0..<0.55:
            return .green
        case 0.55..<0.85:
            return .orange
        default:
            return .red
        }
    }

    private var textTint: Color {
        guard let operationState else { return .secondary }

        switch operationState.phase {
        case .done:
            return .green
        case .failed:
            return .red
        case .stopping, .cleaning, .starting, .checking:
            return .orange
        }
    }

    private var trailingTint: Color {
        operationState == nil ? Color.secondary.opacity(0.55) : tint.opacity(0.85)
    }

    private var barRatio: Double {
        if let operationState {
            return operationState.progress
        }

        return cacheState?.fillRatio ?? 0
    }

    private var buttonDisabled: Bool {
        operationState?.isActive == true
    }

    private var buttonIconName: String {
        guard let operationState else { return "sparkles" }

        switch operationState.phase {
        case .stopping:
            return "stop.fill"
        case .cleaning:
            return "sparkles"
        case .starting:
            return "play.fill"
        case .checking:
            return "wifi"
        case .done:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var buttonHelp: String {
        if let operationState, operationState.isActive {
            return "Cache cleanup is running"
        }

        return "Clean cache"
    }

    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()
}

struct CacheUsageBarView: View {
    let ratio: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.075))

                if clampedRatio > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, proxy.size.width * clampedRatio))
                }
            }
        }
        .frame(height: 5)
        .frame(maxWidth: .infinity)
    }

    private var clampedRatio: Double {
        min(max(ratio, 0), 1)
    }
}

struct CleanRestartProgressView: View {
    let state: CleanRestartState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 12)

                Text(state.message)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)

                Spacer()
            }

            ProgressView(value: state.progress)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(tint)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(tint.opacity(0.08))
        }
    }

    private var iconName: String {
        switch state.phase {
        case .stopping:
            return "stop.fill"
        case .cleaning:
            return "sparkles"
        case .starting:
            return "play.fill"
        case .checking:
            return "wifi"
        case .done:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch state.phase {
        case .failed:
            return .red
        case .done:
            return .green
        case .stopping, .cleaning, .starting, .checking:
            return .orange
        }
    }
}

struct ProjectAvatarView: View {
    let project: LocalProject
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundFill)

            if let favicon = ProjectIconCache.shared.favicon(for: project) {
                Image(nsImage: favicon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: project.kind.symbolName)
                    .font(.system(size: 14, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 24, height: 24)
    }

    private var backgroundFill: Color {
        if ProjectIconCache.shared.hasFavicon(for: project) {
            return Color.primary.opacity(0.08)
        }

        return tint.opacity(0.13)
    }
}

struct ProjectKindChip: View {
    let kind: ProjectKind

    var body: some View {
        HStack(spacing: 4) {
            if let logoName = kind.logoResourceName {
                FrameworkLogoView(resourceName: logoName, height: 10)
            } else {
                Image(systemName: "shippingbox")
                    .font(.system(size: 9, weight: .semibold))

                Text(kind.shortName)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.055))
        }
    }
}

struct FrameworkLogoView: View {
    let resourceName: String
    let height: CGFloat

    var body: some View {
        if let image = ProjectIconCache.shared.frameworkLogo(named: resourceName) {
            let aspectRatio = max(image.size.width / max(image.size.height, 1), 1)

            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: ceil(height * aspectRatio), height: height)
                .foregroundStyle(.primary)
        }
    }
}

@MainActor
private final class ProjectIconCache {
    static let shared = ProjectIconCache()

    private var faviconCache: [String: NSImage?] = [:]
    private var frameworkLogoCache: [String: NSImage] = [:]

    func favicon(for project: LocalProject) -> NSImage? {
        let key = project.path
        if let cached = faviconCache[key] {
            return cached
        }

        let image = faviconURLs(for: project)
            .lazy
            .compactMap(loadFavicon)
            .first
        faviconCache[key] = image
        return image
    }

    func hasFavicon(for project: LocalProject) -> Bool {
        favicon(for: project) != nil
    }

    func frameworkLogo(named name: String) -> NSImage? {
        if let cached = frameworkLogoCache[name] {
            return cached
        }

        guard
            let url = Bundle.module.url(forResource: name, withExtension: "svg"),
            let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        image.isTemplate = true
        frameworkLogoCache[name] = image
        return image
    }

    private func loadFavicon(from url: URL) -> NSImage? {
        guard
            let image = NSImage(contentsOf: url),
            image.size.width > 0,
            image.size.height > 0
        else {
            return nil
        }

        return image
    }

    private func faviconURLs(for project: LocalProject) -> [URL] {
        let root = URL(fileURLWithPath: project.path, isDirectory: true)
        let exactCandidates = [
            "public/favicon.png",
            "public/favicon512.png",
            "public/favicon64.png",
            "public/apple-touch-icon.png",
            "public/icon.png",
            "src/app/icon.png",
            "src/app/favicon.ico",
            "app/icon.png",
            "app/favicon.ico",
            "favicon.png",
            "favicon.ico",
            "public/favicon.svg",
            "public/icon.svg",
            "src/app/icon.svg",
            "app/icon.svg",
            "favicon.svg",
            "favicon.ico"
        ]

        let exactURLs = exactCandidates
            .map { root.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        return exactURLs + discoveredFaviconURLs(in: root)
    }

    private func discoveredFaviconURLs(in root: URL) -> [URL] {
        let searchRoots = [
            root.appendingPathComponent("public", isDirectory: true),
            root.appendingPathComponent("src/app", isDirectory: true),
            root.appendingPathComponent("app", isDirectory: true),
            root
        ]

        var seen = Set<String>()
        var urls: [URL] = []

        for directory in searchRoots {
            guard
                let contents = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
            else {
                continue
            }

            for url in contents where isFaviconCandidate(url) {
                guard !seen.contains(url.path) else { continue }
                seen.insert(url.path)
                urls.append(url)
            }
        }

        return urls.sorted { lhs, rhs in
            faviconPriority(lhs) < faviconPriority(rhs)
        }
    }

    private func isFaviconCandidate(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        let supportedExtensions = ["png", "jpg", "jpeg", "ico", "svg"]

        return supportedExtensions.contains(ext)
            && (name.contains("favicon") || name == "icon" || name.contains("apple-touch-icon"))
    }

    private func faviconPriority(_ url: URL) -> Int {
        switch url.pathExtension.lowercased() {
        case "png":
            return 0
        case "jpg", "jpeg":
            return 1
        case "ico":
            return 2
        case "svg":
            return 3
        default:
            return 4
        }
    }
}

private extension ProjectKind {
    var logoResourceName: String? {
        switch self {
        case .astro:
            return "astro-white"
        case .nextjs:
            return "nextjs-white"
        case .hono, .vite, .remix, .sveltekit, .nuxt, .expo, .supabase, .prisma, .storybook, .unknown:
            return nil
        }
    }
}

struct ExternalPortRowView: View {
    let port: DiscoveredPort
    let isPendingKill: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onIgnore: () -> Void
    let onKill: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: port.isManaged ? "checkmark.circle.fill" : "network")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(port.isManaged ? .green : .orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(port.displayOwner)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)

                    Text("|")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)

                    Text(verbatim: String(port.port))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }

                Text(port.detailText)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            IconActionButton(systemName: "safari", help: "Open", action: onOpen)
            IconActionButton(systemName: "link", help: "Copy URL", action: onCopy)
            IconActionButton(systemName: port.pinnedName == nil ? "pin" : "pin.fill", help: "Pin Port", action: onPin)
            IconActionButton(systemName: "eye.slash", help: "Ignore Port", action: onIgnore)
            IconActionButton(
                systemName: isPendingKill ? "exclamationmark.triangle.fill" : "xmark",
                help: killHelp,
                tint: port.safety == .protected ? .orange : .red,
                action: onKill
            )
        }
        .padding(.vertical, 5)
    }

    private var killHelp: String {
        if port.isManaged { return "Stop Project" }
        if isPendingKill { return "Confirm Kill" }
        return port.safety.displayName
    }
}

struct ExternalPortGroupView: View {
    let group: DiscoveredPortGroup
    let isExpanded: Bool
    let pendingKillPortID: String?
    let onToggle: () -> Void
    let onOpen: (DiscoveredPort) -> Void
    let onCopy: (DiscoveredPort) -> Void
    let onPin: (DiscoveredPort) -> Void
    let onIgnore: (DiscoveredPort) -> Void
    let onKill: (DiscoveredPort) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button(action: onToggle) {
                    Image(systemName: group.secondaryPorts.isEmpty ? "circle.fill" : (isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(group.primaryPort.isManaged ? .green : .orange)
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .disabled(group.secondaryPorts.isEmpty)
                .help(group.secondaryPorts.isEmpty ? "Single Port" : "Toggle Group")

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(group.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)

                        Text("|")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)

                        Text(verbatim: String(group.primaryPort.port))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))

                        if !group.secondaryPorts.isEmpty {
                            Text("+\(group.secondaryPorts.count)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background {
                                    Capsule().fill(Color.primary.opacity(0.06))
                                }
                        }
                    }

                    Text(group.detailText)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                IconActionButton(systemName: "safari", help: "Open Primary Port") {
                    onOpen(group.primaryPort)
                }
                IconActionButton(systemName: "link", help: "Copy Primary URL") {
                    onCopy(group.primaryPort)
                }
                IconActionButton(systemName: group.primaryPort.pinnedName == nil ? "pin" : "pin.fill", help: "Pin Primary Port") {
                    onPin(group.primaryPort)
                }
                IconActionButton(systemName: "eye.slash", help: "Ignore Primary Port") {
                    onIgnore(group.primaryPort)
                }
                IconActionButton(
                    systemName: pendingKillPortID == group.primaryPort.id ? "exclamationmark.triangle.fill" : "xmark",
                    help: pendingKillPortID == group.primaryPort.id ? "Confirm Kill" : group.primaryPort.safety.displayName,
                    tint: group.primaryPort.safety == .protected ? .orange : .red
                ) {
                    onKill(group.primaryPort)
                }
            }
            .padding(.vertical, 6)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.secondaryPorts) { port in
                        Divider().opacity(0.25)

                        ExternalPortRowView(
                            port: port,
                            isPendingKill: pendingKillPortID == port.id
                        ) {
                            onOpen(port)
                        } onCopy: {
                            onCopy(port)
                        } onPin: {
                            onPin(port)
                        } onIgnore: {
                            onIgnore(port)
                        } onKill: {
                            onKill(port)
                        }
                        .padding(.leading, 24)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct LogPreviewCardView: View {
    let project: LocalProject
    let logs: [String]
    let onClose: () -> Void
    let onClear: () -> Void
    let onCopy: () -> Void
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(project.name, systemImage: "doc.text")
                    .font(.system(size: 12, weight: .bold))

                Spacer()

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy Logs")

                Button(action: onClear) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Logs")

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Logs")
            }

            TextField("Search logs", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, weight: .medium))

            if filteredLogs.isEmpty {
                Text("No logs yet.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(filteredLogs.suffix(12).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .localCardBackground()
    }

    private var filteredLogs: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return logs }
        return logs.filter { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct ProjectSettingsEditorView: View {
    let project: LocalProject
    let port: Binding<Int>
    let autoRestart: Binding<Bool>
    let openAfterStart: Binding<Bool>
    let onReveal: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: project.kind.symbolName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)

                    Text(project.kind.displayName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                IconActionButton(systemName: "folder", help: "Reveal Folder", action: onReveal)
                IconActionButton(systemName: "trash", help: "Remove Project", tint: .red, action: onRemove)
            }

            Stepper(value: port, in: 1_024...65_535, step: 1) {
                HStack {
                    Label("Port", systemImage: "number")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(port.wrappedValue)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
            }
            .controlSize(.small)

            Toggle("Auto-restart after crash", isOn: autoRestart)
                .font(.system(size: 11, weight: .medium))
                .toggleStyle(.checkbox)

            Toggle("Open browser after start", isOn: openAfterStart)
                .font(.system(size: 11, weight: .medium))
                .toggleStyle(.checkbox)
        }
        .padding(.vertical, 5)
    }
}

struct WorkspaceGroupCardView: View {
    let group: WorkspaceGroup
    let projects: [LocalProject]
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(group.name, systemImage: "square.stack.3d.up.fill")
                    .font(.system(size: 12, weight: .bold))

                Spacer()

                MetadataChip(icon: "shippingbox", text: "\(group.projectIDs.count)")
            }

            Text(projects.map(\.displayName).joined(separator: " · "))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 7) {
                IconActionButton(systemName: "play.fill", help: "Start Group", tint: .green, action: onStart)
                IconActionButton(systemName: "stop.fill", help: "Stop Group", tint: .red, action: onStop)
            }
        }
        .padding(12)
        .localCardBackground()
    }
}

struct WorkspaceGroupSettingsView: View {
    let group: WorkspaceGroup
    let projects: [LocalProject]
    let name: Binding<String>
    let membership: (LocalProject) -> Binding<Bool>
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Group name", text: name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, weight: .semibold))

                IconActionButton(systemName: "trash", help: "Remove Group", tint: .red, action: onRemove)
            }

            ForEach(projects) { project in
                Toggle(project.displayName, isOn: membership(project))
                    .font(.system(size: 11, weight: .medium))
                    .toggleStyle(.checkbox)
            }
        }
        .padding(.vertical, 5)
    }
}
