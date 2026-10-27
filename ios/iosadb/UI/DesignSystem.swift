import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum TVADBTheme {
    // A single cool spectrum keeps TVADB recognisable without the generic
    // blue/green/purple mix that made adjacent controls feel unrelated.
    static let accent = Color(red: 0.08, green: 0.45, blue: 0.97)
    static let deepBlue = Color(red: 0.04, green: 0.28, blue: 0.70)
    static let cyan = Color(red: 0.00, green: 0.66, blue: 0.88)
    static let status = cyan
    static let cornerRadius: CGFloat = 22

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, cyan],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct TVADBPressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct TVADBPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: TVADBTheme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: TVADBTheme.cornerRadius, style: .continuous)
                    .strokeBorder(TVADBTheme.accent.opacity(0.10), lineWidth: 0.8)
            }
            .shadow(color: TVADBTheme.deepBlue.opacity(0.07), radius: 16, y: 7)
    }
}

struct TVADBBlockingProgressOverlay: View {
    let message: String
    var progress: Double?

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)

            TVADBPanel {
                VStack(spacing: 13) {
                    if let progress {
                        ProgressView(value: progress)
                            .frame(width: 128)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                    }
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                .frame(minWidth: 190)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .padding(32)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(message))
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

/// Uses UIKit's document-picker import path instead of SwiftUI's
/// `fileImporter`. `asCopy: true` asks Files/iCloud/third-party providers to
/// finish downloading and copy the selected items locally before the delegate
/// callback fires.
struct TVADBFileImportPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let allowsMultipleSelection: Bool
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(
        context: Context
    ) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void
        private let onCancel: () -> Void

        init(
            onPick: @escaping ([URL]) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard !urls.isEmpty else {
                onCancel()
                return
            }
            onPick(urls)
        }

        func documentPickerWasCancelled(
            _ controller: UIDocumentPickerViewController
        ) {
            onCancel()
        }
    }
}

struct TVADBInstallPackagePicker: View {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    var body: some View {
        TVADBFileImportPicker(
            contentTypes: [.data],
            allowsMultipleSelection: false,
            onPick: { urls in
                guard let url = urls.first else {
                    onCancel()
                    return
                }
                onPick(url)
            },
            onCancel: onCancel
        )
    }
}

struct TVADBDisconnectToolbarItem: ToolbarContent {
    @EnvironmentObject private var model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("text.disconnect", role: .destructive) {
                model.disconnect()
            }
        }
    }
}

struct TVADBStatusBanner: View {
    let message: String
    let isError: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(isError ? Color.red : TVADBTheme.status)
            Text(message)
                .font(.subheadline.weight(.medium))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .frame(width: 30, height: 30)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(TVADBPressableStyle())
            .accessibilityLabel("text.close")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder((isError ? Color.red : TVADBTheme.status).opacity(0.2))
        }
        .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
    }
}
