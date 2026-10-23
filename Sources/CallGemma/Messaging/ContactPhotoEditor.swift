import SwiftUI
import UniformTypeIdentifiers
import ImageIO

/// A local, bounded image import followed by an explicit circular crop.
struct ContactPhotoEditor: View {
    @Environment(\.dismiss) private var dismiss
    let current: String
    let save: (String) -> Void
    @State private var location = ""
    @State private var choosing = false
    @State private var image: CGImage?
    @State private var zoom = 1.0
    @State private var offset = CGSize.zero
    @State private var anchor = CGSize.zero
    @State private var error: String?
    @State private var loading = false
    private let side: CGFloat = 220

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                TextField("URL or file path", text: $location).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await loadLocation() } }
                Button { Task { await loadLocation() } } label: { Image(systemName: "arrow.down") }
                    .help("Load photo").accessibilityLabel("Load photo").disabled(loading || location.isEmpty)
            }
            HStack(spacing: 12) {
                Button { choosing = true } label: { Image(systemName: "folder") }
                    .help("Choose image file").accessibilityLabel("Choose image file")
                Button { paste() } label: { Image(systemName: "doc.on.clipboard") }
                    .help("Paste image").accessibilityLabel("Paste image")
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }.buttonStyle(.glass)
            if let image {
                let scale = side / CGFloat(min(image.width, image.height)) * zoom
                Image(decorative: image, scale: 1)
                    .resizable().frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    .offset(offset).frame(width: side, height: side)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.secondary.opacity(0.3), lineWidth: 1))
                    .contentShape(Circle())
                    .gesture(DragGesture().onChanged { value in
                        offset = clamped(CGSize(width: anchor.width + value.translation.width, height: anchor.height + value.translation.height))
                    }.onEnded { _ in anchor = offset })
                    .help("Drag to center the photo")
                    .accessibilityLabel("Photo crop")
                Slider(value: $zoom, in: 1...3)
                    .accessibilityLabel("Photo zoom")
                    .onChange(of: zoom) { _, _ in offset = clamped(offset); anchor = offset }
                HStack {
                    Button { zoom = 1; offset = .zero; anchor = .zero } label: { Image(systemName: "arrow.counterclockwise") }
                        .help("Reset crop").accessibilityLabel("Reset crop")
                    Spacer()
                    Button { commit() } label: { Image(systemName: "checkmark") }
                        .buttonStyle(.glassProminent).help("Use photo").accessibilityLabel("Use photo")
                }
            }
        }
        .padding(20).frame(width: 300)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            do { let url = try result.get(); Task { await load(url) } }
            catch { self.error = error.localizedDescription }
        }
        .task { if current.hasPrefix("/") { await load(URL(fileURLWithPath: current)) } }
        .alert("Photo", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func clamped(_ value: CGSize) -> CGSize {
        guard let image else { return .zero }
        let scale = side / CGFloat(min(image.width, image.height)) * zoom
        let x = max(0, (CGFloat(image.width) * scale - side) / 2)
        let y = max(0, (CGFloat(image.height) * scale - side) / 2)
        return CGSize(width: min(x, max(-x, value.width)), height: min(y, max(-y, value.height)))
    }
    private func loadLocation() async {
        let path = location.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: path), ["https", "http", "file"].contains(url.scheme?.lowercased() ?? "") { await load(url) }
        else { await load(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) }
    }
    private func load(_ url: URL) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let data: Data
            if url.isFileURL {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 20_000_000 else { throw PhotoError.tooLarge }
                data = try Data(contentsOf: url)
            } else {
                data = try await Task.detached(priority: .userInitiated) {
                    let (bytes, response) = try await URLSession.shared.bytes(from: url)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), response.expectedContentLength <= 20_000_000 else { throw PhotoError.invalid }
                    var buffer = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard buffer.count < 20_000_000 else { throw PhotoError.tooLarge }
                        buffer.append(byte)
                    }
                    return buffer
                }.value
            }
            try decode(data)
        } catch { self.error = error.localizedDescription }
    }
    private func decode(_ data: Data) throws {
        guard data.count <= 20_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else { throw PhotoError.invalid }
        image = decoded; zoom = 1; offset = .zero; anchor = .zero
    }
    private func paste() {
        do {
            #if os(macOS)
            guard let source = NSImage(pasteboard: .general), let data = source.tiffRepresentation else { throw PhotoError.invalid }
            #else
            guard let data = UIPasteboard.general.image?.pngData() else { throw PhotoError.invalid }
            #endif
            try decode(data)
        } catch { self.error = error.localizedDescription }
    }
    private func commit() {
        do {
            guard let image, let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PhotoError.invalid }
            let scale = 512 / CGFloat(min(image.width, image.height)) * zoom
            let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (512 - width) / 2 + offset.width * 512 / side,
                y: (512 - height) / 2 - offset.height * 512 / side, width: width, height: height))
            guard let result = context.makeImage() else { throw PhotoError.invalid }
            let directory = AppQualificationEnvironment.messaging.appending(path: "ContactPhotos")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: UUID().uuidString + ".png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw PhotoError.invalid }
            CGImageDestinationAddImage(destination, result, nil)
            guard CGImageDestinationFinalize(destination) else { throw PhotoError.invalid }
            save(url.path); dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private enum PhotoError: LocalizedError {
        case invalid, tooLarge
        var errorDescription: String? { self == .tooLarge ? "Choose an image smaller than 20 MB." : "The image could not be loaded." }
    }
}
