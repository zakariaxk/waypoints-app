import DesignSystem
import PerformanceModel
import SwiftUI

/// MOD-13 debug screen: the model's run for each reference car beside its published test.
/// Reached from G6 in debug builds (a row under the mod list). Public so a debug menu elsewhere
/// can show it too.
public struct ReferenceCarsView: View {
    @State private var checks: [ReferenceCheck] = []

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !checks.isEmpty {
                    let stated = checks.filter(\.withinStated).count
                    let passed = checks.filter(\.passes).count
                    Text(verbatim: "\(stated) of \(checks.count) inside the stated error (trap ±3%, ¼ mile ±5%, 0–60 ±0.4 s). "
                        + "\(passed) of \(checks.count) inside it once doubled for typical gear ratios.")
                        .typeStyle(.body).foregroundStyle(Color.chalk)
                        .padding(Space.margin)
                    SectionLabel(verbatim: "MODEL / PUBLISHED")
                    ForEach(checks) { c in
                        Row(Text(verbatim: c.car.name), subtitle: Text(verbatim: line(c)), trailing: {
                            Text(verbatim: c.withinStated ? "inside" : c.passes ? "inside ×2" : "outside")
                                .typeStyle(.foot)
                                .foregroundStyle(c.withinStated ? Color.go : c.passes ? Color.dust : Color.brake)
                        })
                    }
                }
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle("Reference cars")
        .navigationBarTitleDisplayMode(.inline)
        .task { if checks.isEmpty { checks = ReferenceCars.checks() } }
    }

    private func line(_ c: ReferenceCheck) -> String {
        String(format: "0–60 %.2f / %.1f s · ¼ %.2f / %.1f s · trap %.1f / %.1f mph",
               c.model.zeroToSixty, c.car.zeroToSixty, c.model.quarterET, c.car.quarterET,
               c.model.quarterMph, c.car.quarterMph)
    }
}
