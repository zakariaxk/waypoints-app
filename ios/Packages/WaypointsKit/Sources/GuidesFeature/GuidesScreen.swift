import Core
import DesignSystem
import SwiftUI

/// KNW-2: guides for the viewer's cars first, then a search over every task.
struct GuidesScreen: View {
    let ctx: GuidesContext
    @State private var forYours: [Guide] = []
    @State private var firstCar: CarID?
    @State private var query = ""
    @State private var results: [Guide] = []
    @State private var loaded = false

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Field("Search every task", text: $query,
                      prompt: "brake pads, downpipe, alignment")
                    .padding(.horizontal, Space.margin)
                    .padding(.top, Space.s16)
                if searching {
                    if results.isEmpty {
                        Text("No guides match.", bundle: .module)
                            .typeStyle(.body).foregroundStyle(Color.dust).padding(Space.margin)
                    } else {
                        SectionLabel("RESULTS")
                        guideRows(results)
                    }
                } else if !forYours.isEmpty {
                    SectionLabel("FOR YOUR CARS")
                    guideRows(forYours)
                } else if loaded {
                    Text("Add a car to your garage and matching guides show up here, or search every task above.", bundle: .module)
                        .typeStyle(.body).foregroundStyle(Color.dust).padding(Space.margin)
                }
            }
            .padding(.bottom, Space.s48)
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle(Text("Guides", bundle: .module))
        .task { await loadForYours() }
        .task(id: query) { await search() }
    }

    private func guideRows(_ guides: [Guide]) -> some View {
        ForEach(guides) { guide in
            Button { ctx.env.router.open(.guide(guide.id)) } label: {
                Row(Text(verbatim: guide.task),
                    subtitle: Text(verbatim: "\(guide.vehicleLabel) · \(Self.timeLabel(guide))"),
                    trailing: { Disclosure() })
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    /// "1–2 h" or "45 min".
    static func timeLabel(_ guide: Guide) -> String {
        let lo = guide.timeMinMinutes, hi = guide.timeMaxMinutes
        if lo >= 60 || hi >= 60 {
            let fmt = { (m: Int) -> String in
                m % 60 == 0 ? "\(m / 60)" : String(format: "%.1f", Double(m) / 60)
            }
            return lo == hi ? "\(fmt(lo)) h" : "\(fmt(lo))–\(fmt(hi)) h"
        }
        return lo == hi ? "\(lo) min" : "\(lo)–\(hi) min"
    }

    private func loadForYours() async {
        defer { loaded = true }
        guard let me = await ctx.env.auth.currentSession()?.userID else { return }
        let cars = (try? await ctx.env.garage.cars(of: me)) ?? []
        firstCar = cars.first?.id
        var seen: Set<GuideID> = []
        var out: [Guide] = []
        for make in Set(cars.map(\.make)) {
            for guide in (try? await ctx.env.guides.guidesForMake(make)) ?? [] where seen.insert(guide.id).inserted {
                out.append(guide)
            }
        }
        forYours = out.sorted { $0.task < $1.task }
    }

    private func search() async {
        guard searching else { results = []; return }
        results = (try? await ctx.env.guides.search(query)) ?? []
    }
}
