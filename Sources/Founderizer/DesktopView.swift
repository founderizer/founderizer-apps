import AppKit
import FleetCore
import SwiftUI

struct DesktopView: View {
    let context: DesktopContext
    let isFresh: Bool
    @State private var viewing = false
    @State private var image: NSImage?
    @State private var status = String(l10n: "Open the view to watch this task.")
    @State private var captured: Double?
    @Environment(\.scenePhase) private var scenePhase
    private var running: Bool { viewing && isFresh && scenePhase != .background }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Live desktop", systemImage: "desktopcomputer").font(FormMetrics.detailTitle)
                Spacer()
                Button(viewing ? "Close view" : "Watch desktop") { viewing.toggle() }
                    .buttonStyle(FleetOutlineButtonStyle()).disabled(!isFresh)
                    .accessibilityIdentifier("watch-desktop")
            }
            if viewing {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 440)
                        .accessibilityLabel("Live desktop of this task").accessibilityIdentifier("live-desktop-image")
                } else {
                    RoundedRectangle(cornerRadius: FormMetrics.inner).fill(FleetStyle.canvas).frame(height: 180)
                        .overlay(Image(systemName: "desktopcomputer").font(IconMetrics.symbol(28)).foregroundStyle(FleetStyle.muted))
                }
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let age = captured.map { max(0, Int(timeline.date.timeIntervalSince1970 - $0)) }
                    Text(!isFresh ? String(l10n: "Connection lost. View stopped.") : age.map { $0 > 5 ? String(l10n: "No fresh frame · \($0)s ago") : String(l10n: "Live · \($0)s ago · view only") } ?? status)
                        .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                        .accessibilityIdentifier("desktop-status")
                }
            }
        }.padding(12).background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
            .task(id: running) {
                image = nil; captured = nil
                guard running else { return }
                status = String(l10n: "Connecting to the worker…")
                let client = HubClient()
                while !Task.isCancelled {
                    do {
                        let frame = try await client.desktop(in: context)
                        let data = try frame.validatedImage(in: context)
                        try Task.checkCancellation()
                        image = data.flatMap(NSImage.init(data:))
                        captured = frame.captured_at
                        status = switch frame.status {
                        case "permission_required": String(l10n: "On the agent's Mac, allow “Fleet Worker”, as System Settings names it, in Privacy & Security → Screen & System Audio Recording.")
                        case "locked": String(l10n: "The worker desktop is locked. Unlock it to continue.")
                        case "unavailable": String(l10n: "Desktop capture is unavailable. Check the worker installer and screen permission.")
                        default: String(l10n: "Waiting for a fresh frame…")
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        image = nil; captured = nil
                        status = HubError.said(error) ?? String(l10n: "View stopped or connection unavailable.")
                    }
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
            .onDisappear { image = nil; captured = nil; viewing = false }
    }
}
