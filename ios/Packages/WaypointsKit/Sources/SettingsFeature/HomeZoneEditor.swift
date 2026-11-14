import Core
import DesignSystem
import MapKit
import SwiftUI

/// "Add a zone" (S2): tap the map to place a 300 m circle, name it, save. Shown in the locale's units.
struct HomeZoneEditor: View {
    let onSave: (HomeZone) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var center: CLLocationCoordinate2D?
    @State private var name = "Home"
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    /// Where the camera is looking, so VoiceOver can place the zone without a tap point.
    @State private var cameraCenter: CLLocationCoordinate2D?

    var body: some View {
        Sheet(Text("Add a zone", bundle: .module)) {
            VStack(spacing: Space.s16) {
                MapReader { proxy in
                    Map(position: $position) {
                        UserAnnotation()
                        if let center {
                            MapCircle(center: center, radius: CLLocationDistance(HomeZone.radius))
                                .foregroundStyle(Color.sodium.opacity(Opacity.areaFill))
                                .stroke(Color.sodium, lineWidth: Size.Marker.ring)
                        }
                    }
                    .mapStyle(.standard(emphasis: .muted))
                    .onTapGesture { point in center = proxy.convert(point, from: .local) }
                    .onMapCameraChange(frequency: .onEnd) { cameraCenter = $0.region.center }
                    .accessibilityLabel(Text("Map", bundle: .module))
                    .accessibilityValue(center == nil ? Text("No zone placed", bundle: .module) : Text("Zone placed", bundle: .module))
                    .accessibilityAction(named: Text("Place the zone at the map's centre", bundle: .module)) {
                        if let cameraCenter { center = cameraCenter }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.r20))
                .environment(\.colorScheme, .dark)
                (center == nil ? Text("Tap the map to place the zone.", bundle: .module) : Text("Tap again to move it.", bundle: .module))
                    .typeStyle(.foot).foregroundStyle(Color.dust)
                Field("Name", text: $name, limit: 20)
                PrimaryButton("Save zone") {
                    guard let center else { return }
                    onSave(HomeZone(name: name, center: Coordinate(latitude: center.latitude, longitude: center.longitude)))
                    dismiss()
                }
                .disabled(center == nil || name.isEmpty)
            }
            .padding(Space.margin)
        }
        .presentationDetents([.large])
    }
}
