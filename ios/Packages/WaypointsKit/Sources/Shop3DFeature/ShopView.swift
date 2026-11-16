import Core
import DesignSystem
import RealityKit
import SwiftUI
import VehicleCatalog

/// The 3D shop (GME-1, GME-2): orbit/pinch/pan a generated car and swap paint, wheels,
/// stance, and aero live. Dark scene, one accent (DES-8).
public struct ShopView: View {
    @State private var model: ShopModel

    /// `shapeClass` is a `MapGlyph` vehicle name ("coupe", "pickup", …) — the catalog
    /// carries no dimensions, so the body class comes from it. Defaults to a coupe.
    public init(car: Car, shapeClass: String = "sedan") {
        _model = State(wrappedValue: ShopModel(car: car, shapeClass: shapeClass))
    }

    public var body: some View {
        VStack(spacing: 0) {
            scene
            panel
        }
        .background(Color.asphalt)
        .navigationTitle(Text(model.car.fullLabel))
        .toolbarTitleDisplayMode(.inline)
    }

    // MARK: Scene

    private var scene: some View {
        RealityView { content in
            model.installScene(in: &content)
        }
        .realityViewCameraControls(.orbit)   // orbit, pinch-dolly, and pan around cameraTarget
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .accessibilityLabel(Text("3D view of \(model.car.fullLabel)", bundle: .module))
    }

    // MARK: Swap panel

    private var panel: some View {
        ScrollView {
            VStack(spacing: 0) {
                SectionLabel("PAINT")
                paintRow
                SectionLabel("WHEELS")
                wheelRow
                SectionLabel("STANCE")
                stanceRow
                SectionLabel("AERO")
                aeroRows
            }
            .padding(.bottom, Space.s32)
        }
        .frame(maxHeight: 340)
        .background(Color.tarmac)
    }

    private var paintRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.s12) {
                if let hex = model.car.colorHex, let custom = Color(paintHex: hex) {
                    swatch(custom, isSelected: model.customHex != nil,
                           label: Text("Your paint", bundle: .module)) { model.pickCustom() }
                }
                ForEach(PaintFamily.allCases, id: \.self) { family in
                    swatch(Color(paintHex: family.hex) ?? .dust,
                           isSelected: model.family == family,
                           label: Text(verbatim: family.title)) { model.pickFamily(family) }
                }
            }
            .padding(.horizontal, Space.margin)
            .padding(.vertical, Space.s8)
        }
        .scrollIndicators(.hidden)
    }

    private func swatch(_ color: Color, isSelected: Bool, label: Text,
                        action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: Size.hitTarget, height: Size.hitTarget)
                .overlay(Circle().strokeBorder(isSelected ? Color.sodium : Color.seam,
                                               lineWidth: Size.Marker.keyline))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .haptic(.tick, trigger: isSelected)
    }

    private var wheelRow: some View {
        SegmentedSwitch(selection: Binding(
            get: { model.wheelStyle }, set: { model.pickWheels($0) }),
            options: [
                (.steelie, "Steelie"),
                (.spokes, "Spokes"),
                (.mesh, "Mesh"),
            ])
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.s8)
    }

    /// Slider with three stops mapped onto the `Clearance` profile (GAR-12).
    private var stanceRow: some View {
        VStack(spacing: Space.s4) {
            Slider(value: stanceBinding, in: 0...2, step: 1)
                .tint(.sodium)
            HStack {
                Text("Stock", bundle: .module)
                Spacer()
                Text("Lowered", bundle: .module)
                Spacer()
                Text("Slammed", bundle: .module)
            }
            .typeStyle(.foot)
            .foregroundStyle(Color.dust)
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.s8)
    }

    private var stanceBinding: Binding<Double> {
        Binding(
            get: { Double(Clearance.allCases.firstIndex(of: model.clearance) ?? 0) },
            set: { model.pickClearance(Clearance.allCases[Int($0)]) })
    }

    private var aeroRows: some View {
        VStack(spacing: 0) {
            Row(Text("Front splitter", bundle: .module), trailing: {
                Toggle("", isOn: Binding(get: { model.splitterOn },
                                         set: { model.toggleSplitter($0) }))
                    .labelsHidden().tint(.sodium)
            })
            Row(Text("Rear wing", bundle: .module), showsDivider: false, trailing: {
                Toggle("", isOn: Binding(get: { model.wingOn },
                                         set: { model.toggleWing($0) }))
                    .labelsHidden().tint(.sodium)
            })
        }
    }
}
