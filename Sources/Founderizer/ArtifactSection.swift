import AppKit
import FleetCore
import ImageIO
import Observation
import SwiftUI

@MainActor @Observable
private final class ArtifactPreview {
    var files: [CheckedArtifact] = []
    var selected: CheckedArtifact?
    var text: String?
    var image: NSImage?
    var error: String?
    var loading: String?
    var listed = false
    private let client = HubClient()
    private var operation: Task<Void, Never>?
    private var identity = UUID()

    func clear(message: String? = nil) {
        identity = UUID()
        operation?.cancel()
        operation = nil
        files = []
        selected = nil
        text = nil
        image = nil
        loading = nil
        listed = false
        error = message
    }

    func list(_ context: ArtifactContext) {
        clear()
        let token = identity
        loading = "Loading checked outputs…"
        operation = Task {
            do {
                let result = try await client.artifacts(in: context)
                guard token == identity, !Task.isCancelled else { return }
                files = result.artifacts
                listed = true
                loading = nil
            } catch {
                guard token == identity, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                loading = nil
            }
        }
    }

    func view(_ file: CheckedArtifact, context: ArtifactContext) {
        operation?.cancel()
        identity = UUID()
        let token = identity
        selected = nil
        text = nil
        image = nil
        error = nil
        loading = "Loading and verifying output…"
        operation = Task {
            do {
                let content = try await client.artifact(file, in: context)
                guard token == identity, !Task.isCancelled else { return }
                switch content {
                case .text(let value): text = value
                case .image(let data):
                    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: 2048,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceShouldCacheImmediately: true
                          ] as CFDictionary) else { throw ArtifactError.image }
                    image = NSImage(cgImage: thumbnail, size: .zero)
                }
                selected = file
                loading = nil
            } catch {
                guard token == identity, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                loading = nil
                if case ArtifactError.stale = error { files = []; listed = false }
                if case ArtifactError.identity = error { files = []; listed = false }
            }
        }
    }
}

struct ArtifactSection: View {
    let context: ArtifactContext
    let isFresh: Bool
    @State private var preview = ArtifactPreview()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Checked outputs", systemImage: "doc.text").font(FormMetrics.detailTitle)
                Spacer()
                Button(preview.listed ? "Reload outputs" : "View outputs") { preview.list(context) }
                    .buttonStyle(FleetOutlineButtonStyle()).controlSize(.small).disabled(!isFresh || preview.loading != nil)
                    .accessibilityIdentifier("view-checked-outputs")
            }
            if !isFresh {
                Text("Connection required. Reload outputs after the hub reconnects.")
                    .font(FormMetrics.detail).foregroundStyle(.orange)
            }
            if let loading = preview.loading {
                HStack {
                    Text(loading).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    Spacer()
                    Button("Cancel") { preview.clear() }.buttonStyle(FleetOutlineButtonStyle()).controlSize(.small)
                }
            }
            if let error = preview.error {
                Text(error).font(FormMetrics.detail).foregroundStyle(.orange).textSelection(.enabled)
                    .accessibilityIdentifier("artifact-error")
            }
            if preview.listed && preview.files.isEmpty {
                Text("No supported output files are listed for this checked task.")
                    .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
            }
            ForEach(preview.files) { file in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: file.isImage ? "photo" : "doc.text").foregroundStyle(FleetStyle.muted)
                    Text(file.path).font(FormMetrics.detail).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("View") { preview.view(file, context: context) }
                        .buttonStyle(FleetOutlineButtonStyle()).controlSize(.small).disabled(!isFresh || preview.loading != nil)
                        .accessibilityLabel("View \(file.path)")
                }
            }
            if let selected = preview.selected {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(selected.path).font(FormMetrics.detailTitle).textSelection(.enabled)
                        Spacer()
                        Button("Close") { preview.clear() }.buttonStyle(FleetOutlineButtonStyle()).controlSize(.small)
                            .accessibilityIdentifier("close-artifact")
                    }
                    if let image = preview.image {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 340)
                            .accessibilityLabel("Verified image: \(selected.path)")
                            .accessibilityIdentifier("artifact-image")
                    }
                    if let text = preview.text {
                        if text.isEmpty {
                            Text("Empty text file").foregroundStyle(FleetStyle.muted)
                        } else {
                            let lines = text.lazy.filter { $0 == "\n" }.prefix(17).count + 1
                            ScrollView {
                                Text(verbatim: text).font(FormMetrics.code)
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }.frame(height: min(320, max(80, CGFloat(lines) * 18 + 16)))
                                .accessibilityIdentifier("artifact-text")
                        }
                    }
                    FoldRow(title: "Verified download · \(ByteCountFormatter.string(fromByteCount: Int64(selected.bytes), countStyle: .file))", symbol: "checkmark.shield") {
                        VStack(alignment: .leading, spacing: 8) {
                            DetailField(title: "Snapshot commit", value: selected.commit)
                            DetailField(title: "SHA-256", value: selected.sha256)
                            DetailField(title: "Type", value: selected.mime)
                        }
                    }
                }.padding(12).background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
            }
        }
        .onChange(of: isFresh) { _, fresh in
            if !fresh { preview.clear(message: "Output discarded because the hub state is stale.") }
        }
        .onDisappear { preview.clear() }
    }
}
