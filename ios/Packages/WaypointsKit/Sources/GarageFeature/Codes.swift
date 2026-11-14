import Core
import DesignSystem
import PerformanceModel
import SwiftUI
import UIKit
import VisionKit

// SOC-9 codes, ICN-7 earned icons, GAR-15 share build.

// MARK: Profile links

/// `waypoints://profile/<uuid>` and the universal-link form `https://…/profile/<uuid>`.
/// AppShell's `DeepLink` is not importable from a feature, so the one path Garage scans is parsed here.
enum ProfileLink {
    static func url(for user: UserID) -> URL? { URL(string: "waypoints://profile/\(user)") }

    static func userID(from string: String) -> UserID? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        var parts = url.pathComponents.filter { $0 != "/" }
        if url.scheme == "waypoints", let host = url.host(), !host.isEmpty { parts.insert(host, at: 0) }
        guard parts.count >= 2, parts[0] == "profile" else { return nil }
        return UserID(string: parts[1])
    }
}

// MARK: Scan (G11)

/// Reads a QR code with the camera (VisionKit). Hidden where the device can't scan.
struct CodeScanner: UIViewControllerRepresentable {
    let found: @MainActor (String) -> Void

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                           recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        if !vc.isScanning { try? vc.startScanning() }
    }

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: @MainActor (String) -> Void
        init(found: @escaping @MainActor (String) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case let .barcode(code) = item, let payload = code.payloadStringValue { found(payload) }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case let .barcode(code) = item, let payload = code.payloadStringValue { found(payload) }
        }
    }
}

/// The scan sheet: camera, one line of instruction, and an error line for codes that aren't profiles.
struct ScanSheet: View {
    let onProfile: (UserID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var wrongCode = false
    @State private var done = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                CodeScanner { payload in
                    guard !done else { return }
                    if let id = ProfileLink.userID(from: payload) {
                        done = true
                        onProfile(id)
                    } else {
                        wrongCode = true
                    }
                }
                .ignoresSafeArea()
                Text(wrongCode ? LocalizedStringKey("That code isn't a Waypoints profile.") : "Point the camera at a friend's code.")
                    .typeStyle(.sub)
                    .foregroundStyle(wrongCode ? Color.brake : Color.chalk)
                    .padding(Space.s12)
                    .overMapMaterial(in: RoundedRectangle(cornerRadius: Radius.r12, style: .continuous))
                    .padding(Space.margin)
            }
            .haptic(.tap, trigger: done)
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { QuietButton("Cancel") { dismiss() } } }
        }
    }
}

// MARK: ICN-7 earned icons

/// Achievement key → the vehicle silhouette it unlocks (plan 9.8; ProgressFeature holds the full
/// table including trails, which a profile does not show).
enum EarnedIcons {
    static let vehicle: [String: String] = [
        "first_meet": "lowrider", "host_3": "safety_car", "reports_10": "rally", "reports_50": "lifted_truck",
        "spots_25": "shooting_brake", "spots_100": "woody_wagon", "roads_5": "targa", "build_10": "restomod",
        "showdown_top10": "wide_body", "convoy_lead": "flatbed", "strip_12s": "drift", "strip_10s": "time_attack",
        "teams_join": "dually", "meets_5": "fastback_classic", "friends_5": "microcar", "convoy_3": "van_camper",
        "listing_1": "ute", "showdown_50": "gt_wing_hatch", "build_25": "rat_rod", "venue_5": "box_truck",
    ]

    /// Earned silhouettes, oldest first, without duplicates.
    static func names(_ achievements: [Achievement]) -> [String] {
        var seen = Set<String>()
        return achievements.sorted { $0.earnedAt < $1.earnedAt }.compactMap { vehicle[$0.key] }.filter { seen.insert($0).inserted }
    }
}

/// A horizontal strip of the marker icons a profile's owner has earned.
struct EarnedIconStrip: View {
    let names: [String]
    let paint: Color

    var body: some View {
        SectionLabel("ICONS")
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Space.s16) {
                ForEach(names, id: \.self) { name in
                    VStack(spacing: Space.s4) {
                        SilhouetteIcon(name, paint: paint)
                            .frame(width: Size.hitTarget, height: Size.hitTarget)
                        Text(verbatim: MapIconSet.title(name)).typeStyle(.foot).foregroundStyle(Color.dust)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(MapIconSet.title(name)) icon, earned"))
                }
            }
            .padding(.horizontal, Space.margin)
        }
    }
}

// MARK: GAR-15 Share build

/// The card a build shares as: lead photo, name, the four estimates marked "est." with ranges, handle.
struct BuildCard: View {
    let car: Car
    let photo: UIImage?
    let estimate: Estimate?
    let handle: String?
    let silhouette: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            ZStack(alignment: .bottom) {
                Group {
                    if let photo {
                        Image(uiImage: photo).resizable().scaledToFill()
                    } else {
                        ZStack { Color.concrete; SilhouetteIcon(silhouette, paint: car.paint).padding(Space.s48) }
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipped()
                Rectangle().fill(car.paint).frame(height: Size.paintBar)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.r20, style: .continuous))
            VStack(alignment: .leading, spacing: Space.s4) {
                Text(verbatim: car.title).typeStyle(.title).foregroundStyle(Color.chalk)
                if car.nickname != nil { Text(verbatim: car.fullLabel).typeStyle(.sub).foregroundStyle(Color.dust) }
            }
            if let e = estimate {
                HStack(alignment: .top, spacing: Space.s12) {
                    cell(e.hp, "EST. HP", fmt: "%.0f", unit: "hp")
                    cell(e.torque, "EST. TQ", fmt: "%.0f", unit: "lb-ft")
                    cell(e.zeroToSixty, "EST. 0–60", fmt: "%.1f", unit: "s")
                    cell(e.quarterET, "EST. ¼ MILE", fmt: "%.1f", unit: "s")
                }
                Text("Estimates from stock specs and listed mods.").typeStyle(.foot).foregroundStyle(Color.dust)
            }
            HStack {
                if let handle { Text(verbatim: "@\(handle)").typeStyle(.readoutS).foregroundStyle(Color.sodium) }
                Spacer()
                Text(verbatim: "Waypoints").typeStyle(.label).foregroundStyle(Color.dust)
            }
        }
        .padding(Space.margin)
        .frame(width: Size.row * 7)
        .background(Color.asphalt)
    }

    private func cell(_ r: ClosedRange<Double>, _ label: LocalizedStringKey, fmt: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(label).typeStyle(.label).foregroundStyle(Color.dust)
            Text(verbatim: "\(String(format: fmt, r.lowerBound))–\(String(format: fmt, r.upperBound))")
                .typeStyle(.readoutS).foregroundStyle(Color.chalk)
            Text(verbatim: unit).typeStyle(.readoutS).foregroundStyle(Color.dust)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A shared image, identifiable so it can drive `.sheet(item:)`.
struct SharedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// The system share sheet for an image.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

@MainActor
enum BuildShare {
    /// Downloads the lead photo first: `ImageRenderer` draws one pass and does not wait for async images.
    static func render(car: Car, photoURL: URL?, estimate: Estimate?, handle: String?, silhouette: String,
                       scale: CGFloat) async -> UIImage? {
        var photo: UIImage?
        if let photoURL, let loaded = try? await URLSession.shared.data(from: photoURL) { photo = UIImage(data: loaded.0) }
        let renderer = ImageRenderer(content: BuildCard(car: car, photo: photo, estimate: estimate, handle: handle,
                                                        silhouette: silhouette)
            .environment(\.colorScheme, .dark))
        renderer.scale = scale
        return renderer.uiImage
    }
}
