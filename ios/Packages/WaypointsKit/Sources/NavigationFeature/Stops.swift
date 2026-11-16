import Core
import DesignSystem
import MapKit
import SwiftUI

// Stop on the way (NAV-16): fuel, EV charging, or food along the route, with the detour each adds.

enum StopKind: CaseIterable, Identifiable {
    case fuel, charging, food
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .fuel: LocalizedStringKey("Fuel")
        case .charging: LocalizedStringKey("EV charging")
        case .food: LocalizedStringKey("Food")
        }
    }
    var categories: [MKPointOfInterestCategory] {
        switch self {
        case .fuel: [.gasStation]
        case .charging: [.evCharger]
        case .food: [.restaurant, .cafe, .bakery]
        }
    }
}

struct Stop: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
    /// Seconds the trip grows by: the route via the stop minus the current route.
    let detour: TimeInterval
    /// The leg from the stop to the destination.
    var onward: MKRoute?
}

extension NavigationModel {
    static func request(from origin: CLLocationCoordinate2D?, to end: CLLocationCoordinate2D) -> MKDirections.Request {
        let request = MKDirections.Request()
        request.source = origin.map { MKMapItem(placemark: MKPlacemark(coordinate: $0)) } ?? .forCurrentLocation()
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = .automobile
        return request
    }

    /// Searches near three points of the route still ahead, then measures the four places closest
    /// to it (two `MKDirections` requests each).
    func findStops(_ kind: StopKind) {
        stopKind = kind
        stops = []
        stopsError = false
        guard let r = current else { return }
        var path = Self.sample(r.route.polyline, every: 20)
        guard !path.isEmpty else { return }
        if guiding, remaining > 0, r.route.distance > 0 {
            path.removeFirst(max(0, min(path.count - 1, Int(Double(path.count) * (1 - remaining / r.route.distance)))))
        }
        stopsLoading = true
        stopSearch += 1
        stopFound = []
        stopFailed = false
        stopPending = 3
        let search = stopSearch, base = arrival.timeIntervalSinceNow
        for quarter in 1...3 {
            let center = path[(path.count - 1) * quarter / 4]
            let request = MKLocalPointsOfInterestRequest(center: center.cl, radius: 2000)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: kind.categories)
            MKLocalSearch(request: request).start { response, error in
                let places = (response?.mapItems ?? []).map { (name: $0.name ?? "", at: $0.placemark.coordinate) }
                // "Nothing found" arrives as an error too; it is an empty result, not a failure.
                let failed = response == nil && (error as? MKError)?.code != .placemarkNotFound
                MainActor.assumeIsolated { self.searched(places, failed: failed, near: center, search: search, base: base) }
            }
        }
    }

    private func searched(_ places: [(name: String, at: CLLocationCoordinate2D)], failed: Bool, near: Coordinate, search: Int, base: TimeInterval) {
        guard search == stopSearch else { return }
        stopPending -= 1
        if failed { stopFailed = true }
        for p in places where !p.name.isEmpty
            && !stopFound.contains(where: { $0.at.latitude == p.at.latitude && $0.at.longitude == p.at.longitude }) {
            stopFound.append((p.name, p.at, near.distance(to: Coordinate(latitude: p.at.latitude, longitude: p.at.longitude))))
        }
        guard stopPending == 0 else { return }
        let picks = stopFound.sorted { $0.off < $1.off }.prefix(4)
        stopFound = []
        guard !picks.isEmpty else {
            stopsLoading = false
            stopsError = stopFailed
            return
        }
        stopPending = picks.count
        let origin = me, end = destination.cl
        for p in picks {
            let name = p.name, at = p.at
            MKDirections(request: Self.request(from: origin, to: at)).calculate { response, _ in
                let there = response?.routes.first?.expectedTravelTime
                MainActor.assumeIsolated {
                    guard let there else { self.measured(nil, search: search); return }
                    MKDirections(request: Self.request(from: at, to: end)).calculate { response, _ in
                        MainActor.assumeIsolated {
                            self.measured((response?.routes.first).map {
                                Stop(name: name, coordinate: at, detour: max(0, there + $0.expectedTravelTime - base), onward: $0)
                            }, search: search)
                        }
                    }
                }
            }
        }
    }

    private func measured(_ found: Stop?, search: Int) {
        guard search == stopSearch else { return }
        stopPending -= 1
        if let found {
            stops.append(found)
            stops.sort { $0.detour < $1.detour }
        }
        if stopPending == 0 {
            stopsLoading = false
            stopsError = stops.isEmpty
        }
    }

    /// Routes to the stop first; reaching it carries on to the destination.
    func addStop(_ s: Stop) {
        stop = s
        calculate(from: me)
    }

    func removeStop() {
        stop = nil
        calculate(from: me)
    }

    /// The "Add a stop" sheet with results, for `waypoints://debug/stops`.
    static func stopsSeed(_ env: AppEnvironment) -> NavigationModel {
        let model = NavigationModel(env: env, destination: Coordinate(latitude: 39.9412, longitude: -75.0246), name: "Cherry Hill Mall")
        model.stops = [
            Stop(name: "Wawa", coordinate: CLLocationCoordinate2D(latitude: 39.9336, longitude: -75.0412), detour: 120),
            Stop(name: "Sunoco", coordinate: CLLocationCoordinate2D(latitude: 39.9381, longitude: -75.0337), detour: 240),
            Stop(name: "Exxon", coordinate: CLLocationCoordinate2D(latitude: 39.9452, longitude: -75.0189), detour: 420),
        ]
        return model
    }
}

struct StopsSheet: View {
    @Bindable var model: NavigationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Sheet(Text("Add a stop", bundle: .module)) {
            VStack(alignment: .leading, spacing: Space.s12) {
                HStack(spacing: Space.s8) {
                    ForEach(StopKind.allCases) { kind in
                        Chip(kind.title, isSelected: model.stopKind == kind) { model.findStops(kind) }
                    }
                }
                .padding(.horizontal, Space.margin)
                if model.stopsLoading {
                    SkeletonRow(hasLeading: false); SkeletonRow(hasLeading: false); SkeletonRow(hasLeading: false)
                } else if model.stopsError {
                    ErrorState(Text("Couldn't search along this route.", bundle: .module)) { model.findStops(model.stopKind) }
                } else if model.stops.isEmpty {
                    Text("Nothing along this route.", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust)
                        .padding(.horizontal, Space.margin)
                } else {
                    ScrollView {
                        ForEach(model.stops) { s in
                            Button {
                                model.addStop(s)
                                dismiss()
                            } label: {
                                Row(Text(verbatim: s.name), trailing: {
                                    Text("+\(Int((s.detour / 60).rounded())) min", bundle: .module).typeStyle(.readoutS)
                                        .accessibilityLabel(Text("Adds \(Int((s.detour / 60).rounded())) minutes to the trip", bundle: .module))
                                })
                            }
                            .buttonStyle(RowButtonStyle())
                        }
                    }
                }
            }
        }
    }
}
