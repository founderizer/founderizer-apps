import AppKit
import FleetCore
import SwiftUI

struct MachineAccessButtons: View {
    let reading: MachineStatus
    let fresh: Bool
    @State private var error: String?
    private var screen: ScreenSharingSession { .shared }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let url = reading.sshURL {
                    Button("Terminal", systemImage: "terminal") { open(url) }
                        .help(availability(reading.access?.ssh?.available, name: "SSH"))
                }
                if let request = reading.screenSharingConnection {
                    Button(screen.busy.contains(request) ? "Connecting…" : "Screen Sharing", systemImage: "display") {
                        Task { await screen.open(request) }
                    }
                    .disabled(screen.busy.contains(request))
                    .help("Open Screen Sharing through this server's SSH connection.")
                    .accessibilityIdentifier("screen-sharing-\(reading.agent)")
                    if screen.opened.contains(request) {
                        Button("Disconnect Screen Sharing", systemImage: "xmark.circle") {
                            Task { await screen.close(request) }
                        }.labelStyle(.iconOnly).disabled(screen.busy.contains(request))
                            .help("Close Founderizer's SSH connection for this screen.")
                    }
                } else if let url = reading.screenSharingURL {
                    Button("Screen Sharing", systemImage: "display") { open(url) }
                        .help(availability(reading.access?.screen_sharing?.available, name: String(l10n: "Screen Sharing")))
                }
            }.buttonStyle(.plain).font(FormMetrics.detail)
            if let error { Text(error).font(FormMetrics.detail).foregroundStyle(.orange) }
            if let request = reading.screenSharingConnection, let detail = screen.errors[request] {
                Text(detail).font(FormMetrics.detail).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func availability(_ value: Bool?, name: String) -> String {
        guard fresh, let value else { return String(l10n: "Open \(name) · Service status not confirmed") }
        return value ? String(l10n: "Open \(name) · Service on at last server check. Connection from this Mac is not checked.")
            : String(l10n: "Open \(name) · Service off at last server check. Connection from this Mac is not checked.")
    }
    private func open(_ url: URL) {
        error = NSWorkspace.shared.open(url) ? nil : url.scheme.map { String(l10n: "No app opened this connection. Check the default app for \($0.uppercased()) links.") }
            ?? String(l10n: "No app opened this connection. Check the default app for remote links.")
    }
}
