import Foundation
import SwiftUI
import UIKit

struct RemoteFile: Identifiable, Hashable, Sendable {
    let name: String
    let mode: UInt32
    let size: UInt64
    let modifiedAt: Date

    var id: String { name }
    var isDirectory: Bool { mode & 0o170000 == 0o040000 }

    var formattedSize: String {
        guard !isDirectory else { return L10n.string("text.folder") }
        let byteCount = Int64(min(size, UInt64(Int64.max)))
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

struct FileExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct FileExportPicker: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}
