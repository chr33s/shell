//
//  ControlPairingScanner.swift
//  shell
//
//  In-app QR scanner for the `shell-control setup` pairing QR and the
//  `shell-control route` route-update QR.
//

#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import VisionKit
import ShellControlClient

struct ControlPairingScanner: UIViewControllerRepresentable {
    var onBroker: (String) -> Void
    var onFailed: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .fast,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        do {
            try scanner.startScanning()
        } catch {
            context.coordinator.onFailed(error.localizedDescription)
        }
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBroker: onBroker, onFailed: onFailed)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onBroker: (String) -> Void
        let onFailed: (String) -> Void
        private var handled = false

        init(onBroker: @escaping (String) -> Void, onFailed: @escaping (String) -> Void) {
            self.onBroker = onBroker
            self.onFailed = onFailed
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            handle(item)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            addedItems.forEach(handle)
        }

        private func handle(_ item: RecognizedItem) {
            guard !handled else { return }
            guard case .barcode(let barcode) = item, let payload = barcode.payloadStringValue,
                  ControlScannedPayload(payload) != nil
            else { return }
            handled = true
            onBroker(payload)
        }
    }
}

struct ControlPairingScannerSheet: View {
    var onBroker: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let failure {
                    ContentUnavailableView(
                        String(localized: "Camera unavailable"),
                        systemImage: "qrcode.viewfinder",
                        description: Text(failure)
                    )
                } else if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    ControlPairingScanner(
                        onBroker: { payload in
                            onBroker(payload)
                            dismiss()
                        },
                        onFailed: { failure = $0 }
                    )
                    .ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        String(localized: "Camera unavailable"),
                        systemImage: "qrcode.viewfinder",
                        description: Text(String(localized: "Paste the shell-control:// link from the terminal instead."))
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close")) { dismiss() }
                }
            }
            .navigationTitle(String(localized: "Scan pairing QR"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
