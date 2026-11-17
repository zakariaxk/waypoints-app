import Core
import DesignSystem
import SwiftUI
import UIKit

// MARK: ROAD-12 Share drive card

/// The card a saved drive shares as: the trace polyline to scale over concrete (the same
/// bounding-box draw as `LoopCard`), a sodium paint bar, the drive's length, its date.
struct DriveCard: View {
    let drive: Drive

    /// Total length of the trace, point to point, in meters.
    private var lengthMeters: Int {
        Int(zip(drive.points, drive.points.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            ZStack(alignment: .bottom) {
                ZStack {
                    Color.concrete
                    LoopRoadsShape(paths: [drive.points])
                        .stroke(Color.sodium, style: StrokeStyle(lineWidth: Size.paintBar, lineCap: .round, lineJoin: .round))
                        .padding(Space.s12)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipped()
                Rectangle().fill(Color.sodium).frame(height: Size.paintBar)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.r20, style: .continuous))
            VStack(alignment: .leading, spacing: Space.s4) {
                let len = Units.length(lengthMeters)
                Text(verbatim: "\(len.value) \(len.unit)").typeStyle(.title).foregroundStyle(Color.chalk)
                Text(verbatim: drive.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .typeStyle(.sub).foregroundStyle(Color.dust)
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
}

@MainActor
enum DriveShare {
    static func render(drive: Drive, scale: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content: DriveCard(drive: drive)
            .environment(\.colorScheme, .dark))
        renderer.scale = scale
        return renderer.uiImage
    }
}
