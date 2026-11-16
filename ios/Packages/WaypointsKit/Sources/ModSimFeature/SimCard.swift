import Core
import DesignSystem
import PerformanceModel
import SwiftUI
import UIKit

// MOD-16: the card a simulated build shares as — mirrors GAR-15's BuildCard.

extension Car {
    var simPaint: Color { colorHex.flatMap { Color(paintHex: $0) } ?? .dust }
    var simTitle: String { nickname ?? shortLabel }
}

/// The card a simulated build shares as: the car, the mods switched on, and the
/// estimates they produce — marked "Simulated" so it can't read as a real dyno.
struct SimCard: View {
    let car: Car
    let mods: [Mod]
    let estimate: Estimate
    let handle: String?
    let silhouette: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            ZStack(alignment: .bottom) {
                ZStack { Color.concrete; SilhouetteIcon(silhouette, paint: car.simPaint).padding(Space.s48) }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipped()
                Rectangle().fill(car.simPaint).frame(height: Size.paintBar)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.r20, style: .continuous))
            VStack(alignment: .leading, spacing: Space.s4) {
                Text(verbatim: car.simTitle).typeStyle(.title).foregroundStyle(Color.chalk)
                if car.nickname != nil { Text(verbatim: car.fullLabel).typeStyle(.sub).foregroundStyle(Color.dust) }
                Text("SIMULATED", bundle: .module).typeStyle(.label).foregroundStyle(Color.sodium)
            }
            if mods.isEmpty {
                Text("Stock — no mods switched on.", bundle: .module).typeStyle(.sub).foregroundStyle(Color.dust)
            } else {
                Text(verbatim: mods.map(\.name).formatted(.list(type: .and)))
                    .typeStyle(.sub).foregroundStyle(Color.chalk)
            }
            HStack(alignment: .top, spacing: Space.s12) {
                cell(estimate.hp, "EST. HP", digits: 0, unit: "hp")
                cell(estimate.torque, "EST. TQ", digits: 0, unit: "lb-ft")
                cell(estimate.zeroToSixty, "EST. 0–60", digits: 1, unit: "s")
                cell(estimate.quarterET, "EST. ¼ MILE", digits: 1, unit: "s")
            }
            Text("Simulated estimates from stock specs and the mods listed.", bundle: .module)
                .typeStyle(.foot).foregroundStyle(Color.dust)
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

    private func cell(_ r: ClosedRange<Double>, _ label: LocalizedStringKey, digits: Int, unit: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(label).typeStyle(.label).foregroundStyle(Color.dust)
            Text(readout: Format.range(r, fractionDigits: digits), token: .readoutS)
                .foregroundStyle(Color.chalk)
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
enum SimShare {
    static func render(car: Car, mods: [Mod], estimate: Estimate, handle: String?, silhouette: String,
                       scale: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content: SimCard(car: car, mods: mods, estimate: estimate, handle: handle,
                                                      silhouette: silhouette)
            .environment(\.colorScheme, .dark))
        renderer.scale = scale
        return renderer.uiImage
    }
}
