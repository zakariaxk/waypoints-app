import SwiftUI
import VisionKit

/// Reads a VIN from a barcode or printed text with the camera (plan 11.1 "Use VIN").
struct VINScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(), .text()], qualityLevel: .accurate,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in allItems {
                let raw: String? = switch item {
                case let .barcode(b): b.payloadStringValue
                case let .text(t): t.transcript
                @unknown default: nil
                }
                if let vin = raw.flatMap(Self.vin), !done {
                    done = true
                    scanner.stopScanning()
                    found(vin)
                    return
                }
            }
        }

        /// A 17-character VIN: letters and digits, never I, O, or Q.
        static func vin(in text: String) -> String? {
            let cleaned = text.uppercased().filter { $0.isLetter || $0.isNumber }
            guard cleaned.count >= 17 else { return nil }
            for start in 0...(cleaned.count - 17) {
                let s = String(cleaned.dropFirst(start).prefix(17))
                if !s.contains(where: { "IOQ".contains($0) }) && s.contains(where: \.isNumber) { return s }
            }
            return nil
        }
    }
}
