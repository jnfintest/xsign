import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// UIKit document picker in copy mode. More reliable than `.fileImporter`
/// when presented from a sheet. iOS copies the chosen files (downloading
/// iCloud files first) into our tmp inbox, so there's no security-scoped
/// access to manage and the files can be read at any time.
/// A single tap picks a file.
struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    var allowsMultipleSelection = false
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

extension View {
    /// Presents `DocumentPicker` as a sheet.
    func documentPicker(isPresented: Binding<Bool>, contentTypes: [UTType], allowsMultipleSelection: Bool = false,
                        onPick: @escaping ([URL]) -> Void) -> some View {
        sheet(isPresented: isPresented) {
            DocumentPicker(contentTypes: contentTypes, allowsMultipleSelection: allowsMultipleSelection) { urls in
                isPresented.wrappedValue = false
                onPick(urls)
            }
            .ignoresSafeArea()
        }
    }
}
