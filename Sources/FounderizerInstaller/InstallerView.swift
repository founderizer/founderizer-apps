import AppKit
import FleetCore
import SwiftUI

/// The one window of the installer: **one centered step, and only the next action** (the owner's rule for every setup,
/// 26 October 2026, and his yes to these pages on 31 October 2026): a logo, a title, one line and one button, with Back
/// at the bottom left. A wait is a spinner where the button stands (his word of 1 November 2026), and on the setup page
/// a bar of the root step's parts with its one word over it (his yes of 4 November 2026), and no list of checks.
struct InstallerView: View {
    @Bindable var model: InstallerModel

    var body: some View {
        VStack(spacing: 18) {
            mark
            Text(model.page.title).font(.system(size: 22, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 14) {
                if model.page == .link { link } else { step }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .padding(.horizontal, model.page.isSmallWindow ? 20 : 26)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            if model.canGoBack {
                Button("Back") { model.back() }.buttonStyle(.plain).foregroundStyle(.tint).font(.system(size: 15))
                    .keyboardShortcut(.cancelAction).padding(14)
            }
        }
    }

    @ViewBuilder private var mark: some View {
        if model.page.hasNoMark {
            EmptyView()
        } else if let logo = model.logo {
            logo.resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 64, height: 64)
        } else {
            Image(systemName: model.page.symbol).font(.system(size: 22)).foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// What the owner types into Founderizer on their own Mac: this Mac's address, and the link code.
    @ViewBuilder private var link: some View {
        Text(model.addresses.isEmpty ? "No network on this Mac" : model.addresses.map { "\($0):\(model.port)" }.joined(separator: "   "))
            .font(.system(size: 15)).textSelection(.enabled)
        // The code in the app's own typeface, never monospaced (the owner, 10 November 2026: no "console" font).
        Text(ClaimCode.grouped(model.code)).font(.system(size: 22, weight: .semibold)).textSelection(.enabled)
        if model.laptop {
            Text("A laptop is off when your fleet is meant to be working. Use a Mac mini or a Mac Studio.")
                .font(.system(size: 15)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        failure
    }

    /// This Mac is at it, and the owner has nothing to do.
    private var waiting: Bool { (model.page == .setup || model.working) && model.failure == nil }

    /// A page's line says what the owner does, so it goes while this Mac works. The setup's one word says what it does.
    private var line: String? {
        if model.page == .setup { return model.word }
        return waiting ? nil : model.page.line(fileVault: model.fileVault || model.missing != nil)
    }

    @ViewBuilder private var step: some View {
        if let line, !line.isEmpty {
            Text(line).font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        failure
        if model.failure != nil {
            Button("Try again") { model.tryAgain() }.buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
        } else if waiting {
            if model.page == .setup { SetupBar(ended: MacSetupParts.ended(at: model.word)) } else { ProgressView() }
        } else {
            HStack(spacing: 10) {
                ForEach(model.page == .nothingMissing ? model.addable : [], id: \.self) { ai in
                    Button("Add \(ai.title)") { model.add(ai) }.buttonStyle(.bordered).controlSize(.large)
                }
                if let action = model.page.action {
                    Button(action) { model.act() }.controlSize(.large)
                        .buttonStyle(.borderedProminent).tint(model.page.hasNext ? nil : .accentColor)
                }
                if model.page.hasNext || model.cameBack {
                    Button("Next") { model.next() }.buttonStyle(.bordered).controlSize(.large)
                }
            }
        }
    }

    @ViewBuilder private var failure: some View {
        if let failure = model.failure {
            Text(failure).font(.system(size: 15)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// The root step's parts, one segment each, where the other pages' spinner stands (the owner's yes of 4 November 2026,
/// "Steps bar"): a part that has ended is filled, and the one that runs is lighter and breathes, so that a long part
/// never looks stuck.
private struct SetupBar: View {
    let ended: Int?
    static let height: CGFloat = 6

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MacSetupParts.words.indices, id: \.self) { part in
                if part == ended {
                    Breathing()
                } else {
                    Capsule().fill(part < (ended ?? 0) ? Color.accentColor : Color.primary.opacity(0.12))
                }
            }
        }
        .frame(width: 216, height: Self.height)
        .animation(.easeOut(duration: 0.3), value: ended)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(ended ?? 0) of \(MacSetupParts.words.count)")
    }
}

/// The segment of the part that runs. It breathes in a Core Animation layer, so the window does not draw each frame,
/// and it stands still with Reduce Motion.
private struct Breathing: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { BreathingSegment() }
    func updateNSView(_ view: NSView, context: Context) {}
}

private final class BreathingSegment: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = SetupBar.height / 2
        layer?.opacity = 0.4
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 0.25
        breath.toValue = 0.7
        breath.duration = 0.9
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(breath, forKey: "breath")
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() { layer?.backgroundColor = NSColor.controlAccentColor.cgColor }  // in this appearance
}
