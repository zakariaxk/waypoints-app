import Core
import DesignSystem
import MapKit
import SwiftUI

/// M1 Map.
struct MapScreen: View {
    @Bindable var model: MapModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var detent: Detent = .peek
    @State private var showLayers = false
    @State private var showSearch = false
    @State private var showMarkerPicker = false
    @State private var addPoint: Coordinate?
    @State private var dragOffset: CGFloat = 0
    @State private var passenger = false

    /// Above 8 km/h the add button hides unless a passenger confirms (plan 10.3 M4).
    private var moving: Bool { (model.me?.speed ?? 0) > 8 / 3.6 }

    enum Detent { case peek, medium, large }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                map
                overlays
                panel(height: geo.size.height)
            }
        }
        .connectionBanner(model.banner)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showLayers) { LayersSheet(model: model) { showLayers = false; showMarkerPicker = true } }
        .sheet(isPresented: $showMarkerPicker) { MarkerPicker(model: model) }
        .fullScreenCover(isPresented: $showSearch) { SearchView(model: model) }
        .onChange(of: model.recenterTick) {
            withMotion(.standard, reduceMotion: reduceMotion) {
                position = .userLocation(followsHeading: model.follow == .heading, fallback: .automatic)
            }
        }
        .onChange(of: moving) { if !moving { passenger = false } }
        .onChange(of: model.selection) { if model.selection != nil { detent = .medium } }
    }

    // MARK: Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $position) {
                if model.authorization.allowsUse, let me = model.me {
                    Annotation("", coordinate: me.coordinate.cl, anchor: .center) {
                        VehicleMarker(icon: model.profile?.markerIcon ?? "coupe", paint: model.primaryCar?.paint ?? .dust,
                                      role: .you, heading: me.speed > 2.2 ? me.heading : nil)
                    }
                    .annotationTitles(.hidden)
                }
                ForEach(model.visibleEntities) { e in
                    Annotation("", coordinate: e.coordinate.cl, anchor: .center) {
                        Button { model.selection = .entity(e.uid) } label: { marker(for: e) }
                            .buttonStyle(.plain)
                    }
                    .annotationTitles(.hidden)
                }
                ForEach(model.registry.mapLayers, id: \.id) { provider in
                    if model.isOn(provider.id) {
                        ForEach(model.items[provider.id] ?? []) { item in
                            Annotation(item.title ?? "", coordinate: item.coordinate.cl, anchor: .center) {
                                Button { model.selection = .item(provider: provider.id, id: item.id) } label: {
                                    MapItemView(item: item, selected: model.selection == .item(provider: provider.id, id: item.id))
                                }
                                .buttonStyle(.plain)
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted,
                                pointsOfInterest: .including([.gasStation, .parking, .evCharger, .carRental]),
                                showsTraffic: model.isOn("traffic")))
            .mapControls {}
            .environment(\.colorScheme, .dark)
            .onMapCameraChange(frequency: .onEnd) { ctx in
                let r = ctx.region
                model.cameraSettled(MapRegion(center: Coordinate(latitude: r.center.latitude, longitude: r.center.longitude),
                                              latitudeDelta: r.span.latitudeDelta, longitudeDelta: r.span.longitudeDelta))
            }
            .gesture(LongPressGesture(minimumDuration: 0.5).sequenced(before: DragGesture(minimumDistance: 0))
                .onEnded { value in
                    if case let .second(true, drag?) = value, let c = proxy.convert(drag.location, from: .local) {
                        addPoint = Coordinate(latitude: c.latitude, longitude: c.longitude)
                    }
                })
        }
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder private func marker(for e: Entity) -> some View {
        let selected = model.selection == .entity(e.uid)
        let paint = e.info.map { Color(rgb: $0.paintRGB) } ?? .dust
        let icon = e.info?.markerIcon.isEmpty == false ? e.info!.markerIcon : "coupe"
        switch (e.info?.relation, e.tier) {
        case (.nearby?, _):
            VehicleMarker(icon: icon, paint: .dust, role: .stranger, selected: selected)
        case (_, .approximate):
            VehicleMarker(icon: icon, paint: paint, role: .approximate, staleness: e.staleness, selected: selected)
        default:
            VehicleMarker(icon: icon, paint: paint, role: .friend(name: e.info?.displayName ?? ""), heading: e.heading,
                          moving: e.moving, staleness: e.staleness, selected: selected)
                .opacity(model.hasLiveBatch ? 1 : 0.5)
        }
    }

    // MARK: Floating controls

    private var overlays: some View {
        VStack(spacing: Space.s8) {
            HStack(alignment: .top, spacing: Space.s12) {
                avatar
                Button { showSearch = true } label: {
                    HStack {
                        Image.symbol(Symbol.search).foregroundStyle(Color.dust)
                        Text("Where to?").typeStyle(.body).foregroundStyle(Color.dust)
                        Spacer()
                    }
                    .padding(.horizontal, Space.s16)
                    .frame(height: Size.hitTarget)
                    .overMapMaterial(in: RoundedRectangle(cornerRadius: Radius.r12))
                }
                .accessibilityLabel(Text("Search"))
            }
            if model.aggregateCount > 0 && model.entities.isEmpty {
                Text("Zoom in to see drivers.").typeStyle(.foot).foregroundStyle(Color.chalk)
                    .padding(.horizontal, Space.s12).padding(.vertical, Space.s4)
                    .overMapMaterial(in: Capsule())
            }
            HStack {
                Spacer()
                VStack(spacing: Space.s8) {
                    IconButton("square.3.layers.3d", label: "Layers", style: .overMap) { showLayers = true }
                    IconButton(model.follow == .heading ? "location.north.line.fill" : "location.fill",
                               label: "Recenter", style: .overMap) { model.recenter() }
                }
            }
            Spacer()
            HStack {
                Spacer()
                if moving && !passenger && !model.registry.mapActions.isEmpty {
                    QuietButton("I'm a passenger") { passenger = true }
                        .padding(.horizontal, Space.s12)
                        .overMapMaterial(in: Capsule())
                } else if !model.registry.mapActions.isEmpty {
                    Menu {
                        ForEach(model.registry.mapActions, id: \.id) { action in
                            Button { action.perform(at: model.region.center, router: model.env.router) } label: {
                                Label(action.title, systemImage: action.symbol)
                            }
                        }
                    } label: {
                        Image.symbol(Symbol.add)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.asphalt)
                            .frame(width: Size.control, height: Size.control)
                            .background(Color.sodium, in: Circle())
                            .mapShadow()
                    }
                    .accessibilityLabel(Text("Add"))
                }
            }
            .padding(.bottom, Size.row * 1.8)
        }
        .padding(.horizontal, Space.margin)
        .padding(.top, Space.s8)
        .confirmationDialog("Add here", isPresented: Binding(get: { addPoint != nil }, set: { if !$0 { addPoint = nil } })) {
            ForEach(model.registry.mapActions, id: \.id) { action in
                Button(action.title) {
                    if let p = addPoint { action.perform(at: p, router: model.env.router) }
                    addPoint = nil
                }
            }
        }
    }

    private var avatar: some View {
        let ghost = model.privacy.isGhost()
        let sharing = model.authorization.allowsUse && !ghost
        return Button { model.env.router.open(.settingsPrivacy) } label: {
            Avatar(name: model.profile?.displayName ?? "", url: nil, size: .s40)
                .overlay(Circle().strokeBorder(sharing ? Color.go : Color.dust,
                                               style: StrokeStyle(lineWidth: Size.Marker.ring, dash: ghost ? [3, 3] : [])))
                .mapShadow()
        }
        .contextMenu {
            if ghost {
                Button("Stop ghost mode") { model.setGhost(until: nil) }
            } else {
                Button("Go ghost for 1 hour") { model.setGhost(until: .now.addingTimeInterval(3600)) }
                Button("Until tomorrow") { model.setGhost(until: Self.tomorrowSix) }
                Button("Until I turn it off") { model.setGhost(until: .distantFuture) }
            }
        }
        .accessibilityLabel(Text(ghost ? "Ghost mode on. Privacy settings" : "Privacy settings"))
    }

    static var tomorrowSix: Date {
        let cal = Calendar.current
        let t = cal.date(byAdding: .day, value: 1, to: .now) ?? .now
        return cal.date(bySettingHour: 6, minute: 0, second: 0, of: t) ?? t
    }

    // MARK: Panel (the map sheet)

    private func panel(height: CGFloat) -> some View {
        let target: CGFloat = switch detent {
        case .peek: Size.row * 1.7
        case .medium: height * 0.45
        case .large: height * 0.88
        }
        let h = max(Size.row * 1.7, min(height * 0.92, target - dragOffset))
        return VStack(spacing: 0) {
            Capsule().fill(Color.gravel).frame(width: Size.hitTarget * 0.8, height: Space.s4).padding(.top, Space.s8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let selection = model.selection {
                        HStack {
                            IconButton(Symbol.back, label: "Back") { model.selection = nil; detent = .peek }
                            Spacer()
                        }
                        .padding(.horizontal, Space.s8)
                        detail(for: selection)
                    } else {
                        summary
                        sections
                    }
                }
            }
            .scrollDisabled(detent == .peek)
        }
        .frame(height: h)
        .frame(maxWidth: .infinity)
        .overMapMaterial(in: UnevenRoundedRectangle(topLeadingRadius: Radius.r28, topTrailingRadius: Radius.r28))
        .gesture(DragGesture()
            .onChanged { dragOffset = $0.translation.height }
            .onEnded { v in
                let up = v.translation.height < -40, down = v.translation.height > 40
                withMotion(.sheet, reduceMotion: reduceMotion) {
                    switch detent {
                    case .peek: if up { detent = .medium }
                    case .medium: if up { detent = .large } else if down { detent = .peek }
                    case .large: if down { detent = .medium }
                    }
                    dragOffset = 0
                }
            })
        .haptic(.set, trigger: detent)
        .animation(Motion.sheet.resolved(reduceMotion: reduceMotion), value: detent)
    }

    private var summary: some View {
        Group {
            if !model.authorization.allowsUse {
                HStack {
                    Text("Location is off. You're not on the map.").typeStyle(.sub).foregroundStyle(Color.chalk)
                    Spacer()
                    QuietButton("Turn on") {
                        if model.authorization == .denied {
                            openURL(URL(string: UIApplication.openSettingsURLString)!)
                        } else {
                            Task { await model.env.location.requestWhenInUse(); await model.env.location.setSharing(true) }
                        }
                    }
                }
            } else {
                let n = model.friendsOut.count
                Text(n == 1 ? "1 friend out" : "\(n) friends out").typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.s12)
    }

    @ViewBuilder private var sections: some View {
        friendsSection
        ForEach(model.registry.mapSheetSections, id: \.id) { section in
            section.view(region: model.region)
        }
    }

    @ViewBuilder private var friendsSection: some View {
        SectionLabel("FRIENDS")
        if model.friendsOut.isEmpty {
            VStack(alignment: .leading, spacing: Space.s12) {
                Text("No friends on the map yet.").typeStyle(.body).foregroundStyle(Color.dust)
                if let handle = model.profile?.handle, let url = URL(string: "https://waypoints.app/u/\(handle)") {
                    ShareLink(item: url) { Text("Invite a friend").typeStyle(.bodyStrong).foregroundStyle(Color.sodium) }
                }
            }
            .padding(.horizontal, Space.margin)
        }
        ForEach(model.friendsOut) { f in
            let e = model.entities.first { $0.uid == f.profile.uid }
            Button { model.selection = .entity(f.profile.uid) } label: {
                Row(Text(verbatim: f.profile.displayName),
                    subtitle: f.primaryCar.map { Text(verbatim: $0.shortLabel) }, leading: {
                        Avatar(name: f.profile.displayName, size: .s40)
                    }, trailing: {
                        if let e {
                            Text(verbatim: "\(model.distanceText(to: e.coordinate)) · \(e.moving ? "moving" : "parked")")
                                .typeStyle(.readoutS)
                        }
                    })
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    @ViewBuilder private func detail(for selection: Selection) -> some View {
        switch selection {
        case let .entity(uid):
            if let e = model.entities.first(where: { $0.uid == uid }) {
                DriverPeek(model: model, entity: e)
            }
        case let .item(providerID, id):
            if let provider = model.registry.mapLayers.first(where: { $0.id == providerID }),
               let item = model.items[providerID]?.first(where: { $0.id == id }) {
                provider.detail(for: item)
            }
        }
    }
}

/// Renders a plug-in `MapItem` by glyph name.
struct MapItemView: View {
    let item: MapItem
    let selected: Bool
    var body: some View {
        Group {
            if item.glyph.name.hasPrefix("report.") {
                ReportBadge(kind: String(item.glyph.name.dropFirst("report.".count)))
            } else if item.glyph.name.hasPrefix("meet.") {
                MeetPin(kind: String(item.glyph.name.dropFirst("meet.".count)), time: item.title,
                        live: item.tint == .go)
            } else if item.glyph.name == "road" {
                Image(systemName: "road.lanes").font(.title3.weight(.semibold)).foregroundStyle(item.tint.color)
                    .frame(width: Size.hitTarget, height: Size.hitTarget)
                    .background(Color.tarmac, in: Circle())
                    .mapShadow()
            } else if item.glyph.name == "driven" {
                // ROAD-5 driven map: one soft square per driven grid cell.
                RoundedRectangle(cornerRadius: Radius.r6).fill(item.tint.color.opacity(Opacity.inactive))
                    .frame(width: Space.s12, height: Space.s12)
                    .allowsHitTesting(false)
            } else if item.glyph.name == "pin" {
                Image(systemName: "mappin.circle.fill").font(.largeTitle).foregroundStyle(item.tint.color).mapShadow()
            } else {
                SilhouetteIcon(item.glyph.name, paint: item.tint.color).frame(width: Size.Marker.friend, height: Size.Marker.friend)
            }
        }
        .scaleEffect(selected ? Size.Marker.selectedScale : 1)
        .motion(.sheet, value: selected)
        .accessibilityLabel(Text(verbatim: item.title ?? item.glyph.name))
    }
}

extension Coordinate {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
