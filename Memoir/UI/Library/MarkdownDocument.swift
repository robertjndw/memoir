import SwiftUI
import UniformTypeIdentifiers

nonisolated struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [markdownType] }
    static var writableContentTypes: [UTType] { [markdownType] }

    static var markdownType: UTType {
        UTType("net.daringfireball.markdown") ?? .plainText
    }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else { throw CocoaError(.fileReadCorruptFile) }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
