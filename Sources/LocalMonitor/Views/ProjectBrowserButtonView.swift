import SwiftUI

struct ProjectBrowserButtonView: View {
    let hostnames: [String]
    let port: Int
    let onOpen: () -> Void
    let onOpenHostname: (String) -> Void

    var body: some View {
        if hostnames.count > 1 {
            Menu {
                ForEach(hostnames, id: \.self) { host in
                    Button("\(host == "::1" ? "[::1]" : host):\(port)") {
                        onOpenHostname(host)
                    }
                }
            } label: {
                Image(systemName: "safari")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background {
                        RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.065))
                    }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open Browser Address")
            .accessibilityLabel("Open Browser Address")
        } else {
            IconActionButton(systemName: "safari", help: "Open in Browser", action: onOpen)
        }
    }
}
