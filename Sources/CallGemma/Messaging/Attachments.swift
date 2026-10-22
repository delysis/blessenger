import Foundation
import PDFKit
import UniformTypeIdentifiers

struct MessageAttachment: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable { case image, audio, document }
    var id: UUID
    var name: String
    var kind: Kind
    var file: String
    var extractedText: String?
    var url: URL { AttachmentLibrary.root.appending(path: file) }
}

actor AttachmentLibrary {
    static let root = URL.applicationSupportDirectory.appending(path: "Blessenger/Media/Attachments")
    func importFile(_ source: URL) throws -> MessageAttachment {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentTypeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 128 * 1_024 * 1_024 else {
            throw GemmaError(message: "Choose a regular file smaller than 128 MiB.")
        }
        let type = values.contentType ?? UTType(filenameExtension: source.pathExtension) ?? .data
        let kind: MessageAttachment.Kind
        var extracted: String?
        if type.conforms(to: .image) { kind = .image }
        else if type.conforms(to: .audio) { kind = .audio }
        else if type.conforms(to: .pdf) {
            kind = .document
            guard let document = PDFDocument(url: source), !document.isLocked else {
                throw GemmaError(message: "The PDF could not be read or is locked.")
            }
            var text = ""
            for index in 0..<document.pageCount {
                text += (document.page(at: index)?.string ?? "") + "\n"
                guard text.utf8.count <= 64 * 1_024 else { throw GemmaError(message: "The document exceeds the current 64 KiB text limit.") }
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GemmaError(message: "This PDF needs OCR before it can be read.")
            }
            extracted = text
        } else if type.conforms(to: .text) {
            kind = .document
            guard size <= 64 * 1_024 else { throw GemmaError(message: "The document exceeds the current 64 KiB text limit.") }
            extracted = try String(contentsOf: source, encoding: .utf8)
        } else { throw GemmaError(message: "This file type is not supported.") }
        let id = UUID()
        let name = id.uuidString + "." + source.pathExtension.lowercased()
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = Self.root.appending(path: name)
        try FileManager.default.copyItem(at: source, to: target)
        let handle = try FileHandle(forWritingTo: target)
        try handle.synchronize(); try handle.close()
        try syncDirectory(Self.root)
        return MessageAttachment(id: id, name: source.lastPathComponent, kind: kind, file: name, extractedText: extracted)
    }
}

extension ChatMessage {
    func inputJSON() throws -> String {
        var content: [[String: String]] = []
        if !text.isEmpty { content.append(["type": "text", "text": text]) }
        for attachment in attachments {
            switch attachment.kind {
            case .document:
                content.append(["type": "text", "text": "Attached document: \(attachment.name)\n\(attachment.extractedText ?? "")"])
            case .image, .audio:
                content.append(["type": attachment.kind.rawValue, "path": attachment.url.path])
            }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["role": "user", "content": content]), as: UTF8.self)
    }
}
