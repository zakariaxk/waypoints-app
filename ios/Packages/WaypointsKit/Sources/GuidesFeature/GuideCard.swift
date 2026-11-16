import Core
import DesignSystem
import SwiftUI
import UIKit

// KNW-10: the card a guide shares as — mirrors GAR-15's BuildCard / MOD-16's SimCard.

/// The card a guide shares as: the task, the vehicle it covers, the step count,
/// and how many people found it helpful. Guides are pipeline-written, so there
/// is no author handle to show.
struct GuideCard: View {
    let guide: Guide
    let time: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            ZStack(alignment: .bottom) {
                ZStack {
                    Color.concrete
                    Image.symbol("wrench.and.screwdriver")
                        .foregroundStyle(Color.dust)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipped()
                Rectangle().fill(Color.sodium).frame(height: Size.paintBar)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.r20, style: .continuous))
            VStack(alignment: .leading, spacing: Space.s4) {
                Text(verbatim: guide.task).typeStyle(.title).foregroundStyle(Color.chalk)
                Text(verbatim: "\(guide.vehicleLabel) · \(time)").typeStyle(.sub).foregroundStyle(Color.dust)
            }
            HStack(alignment: .top, spacing: Space.s12) {
                cell("\(guide.steps.count)", "STEPS")
                cell("\(guide.votesCount)", "FOUND HELPFUL")
            }
            HStack {
                Spacer()
                Text(verbatim: "Waypoints").typeStyle(.label).foregroundStyle(Color.dust)
            }
        }
        .padding(Space.margin)
        .frame(width: Size.row * 7)
        .background(Color.asphalt)
    }

    private func cell(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(label).typeStyle(.label).foregroundStyle(Color.dust)
            Text(readout: value, token: .readoutS).foregroundStyle(Color.chalk)
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
enum GuideShare {
    static func render(guide: Guide, time: String, scale: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content: GuideCard(guide: guide, time: time)
            .environment(\.colorScheme, .dark))
        renderer.scale = scale
        return renderer.uiImage
    }
}
