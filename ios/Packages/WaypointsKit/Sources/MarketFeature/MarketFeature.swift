import Core
import CoreLocation
import DesignSystem
import PhotosUI
import SwiftUI
import VehicleCatalog

/// The Market tab (plan 10.6 K1–K4) and route `listing`.
public enum MarketFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        registry.registerTab(.market) { AnyView(Browse(env: env)) }
        registry.registerRoute(.listing, presentation: .push(tab: .market)) { route in
            guard case let .listing(id) = route else { return nil }
            return AnyView(ListingScreen(env: env, id: id))
        }
    }
}

enum Price {
    static func text(_ cents: Int) -> String {
        (Double(cents) / 100).formatted(.currency(code: Locale.current.currency?.identifier ?? "USD").precision(.fractionLength(0)))
    }
}

/// SET-3: distances follow the device's locale.
enum Units {
    static var metric: Bool { Locale.current.measurementSystem == .metric }
    static var meters: Double { metric ? 1000 : 1609.344 }
    static var name: String { metric ? "km" : "mi" }
}

/// The phone's last known position, rounded to 0.1 degree before it is used anywhere (MKT-1).
enum Coarse {
    static func here() -> Coordinate? {
        guard let l = CLLocationManager().location else { return nil }
        return Coordinate(latitude: (l.coordinate.latitude * 10).rounded() / 10, longitude: (l.coordinate.longitude * 10).rounded() / 10)
    }
}

/// SAFE-9: the server's abuse limits get their own line; everything else gets the fallback.
func message(for error: any Error, fallback: String) -> String {
    (error as? WaypointsError) == .rateLimited ? String(localized: "You're doing that a lot. Try again in a few minutes.") : fallback
}

extension ListingCategory {
    /// MKT-7 part categories, in the PRD's order.
    var title: LocalizedStringKey {
        switch self {
        case .wheelsTires: "Wheels and tires"
        case .exhaust: "Exhaust"
        case .intakeFuel: "Intake and fuel"
        case .forcedInduction: "Forced induction"
        case .engine: "Engine"
        case .drivetrain: "Drivetrain"
        case .suspension: "Suspension"
        case .brakes: "Brakes"
        case .exteriorAero: "Exterior and aero"
        case .interior: "Interior"
        case .lighting: "Lighting"
        case .electronicsTuning: "Electronics and tuning"
        case .tools: "Tools"
        case .apparel: "Apparel"
        case .other: "Other"
        }
    }
}

/// A row that opens the list of part categories (plan 9.9: chips only for five or fewer).
struct CategoryPicker: View {
    @Binding var selection: ListingCategory?
    let noneTitle: LocalizedStringKey

    var body: some View {
        Menu {
            Button(noneTitle) { selection = nil }
            ForEach(ListingCategory.allCases, id: \.self) { c in Button(c.title) { selection = c } }
        } label: {
            Row(Text("Category"), showsDivider: false, trailing: {
                HStack(spacing: Space.s4) {
                    Text(selection?.title ?? noneTitle).typeStyle(.sub)
                    Disclosure()
                }
            })
        }
        .buttonStyle(RowButtonStyle())
    }
}

// MARK: K1 Browse

struct Browse: View {
    let env: AppEnvironment
    @State private var query = ""
    @State private var kind: ListingKind = .part
    @State private var fitsCar: Car?
    @State private var cars: [Car] = []
    @State private var listings: [Listing] = []
    @State private var next: PageCursor?
    @State private var loading = false
    @State private var listing = false
    @State private var yours = false
    @State private var showFilter = false
    @State private var minPrice = ""
    @State private var maxPrice = ""
    @State private var conditions: Set<ListingCondition> = []
    @State private var category: ListingCategory?
    /// Distance in the locale's unit (5, 25, 50, 100), nil for any (MKT-1).
    @State private var within: Int?
    @State private var here: Coordinate?

    /// Price and condition narrow the loaded results (K1 filter sheet).
    private var shown: [Listing] {
        listings.filter { l in
            (Int(minPrice).map { l.priceCents >= $0 * 100 } ?? true) && (Int(maxPrice).map { l.priceCents <= $0 * 100 } ?? true)
                && (conditions.isEmpty || conditions.contains(l.condition))
        }
    }

    private var filter: ListingFilter {
        ListingFilter(kind: kind, query: query.isEmpty ? nil : query,
                      fits: kind != .car ? fitsCar.map { Fitment(make: $0.make, model: $0.model, yearFrom: $0.year, yearTo: $0.year) } : nil,
                      near: within == nil ? nil : here,
                      category: kind != .car ? category : nil,
                      radiusMeters: within.map { Int(Double($0) * Units.meters) })
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.s12) {
                Field("Search", text: $query, prompt: "Search parts and cars")
                HStack {
                    SegmentedSwitch(selection: $kind, options: [(.part, "Parts"), (.car, "Cars"), (.wanted, "Wanted")])
                        .frame(maxWidth: Size.row * 5)
                    Spacer()
                    if kind != .car, !cars.isEmpty {
                        Menu {
                            ForEach(cars) { c in Button(c.shortLabel) { fitsCar = c } }
                            Button("Clear") { fitsCar = nil }
                        } label: {
                            Text(verbatim: fitsCar.map { "Fits: \($0.shortLabel)" } ?? "Fits: any car").typeStyle(.sub).foregroundStyle(Color.sodium)
                        }
                    }
                }
                if shown.isEmpty && !loading {
                    if let c = fitsCar, kind != .car {
                        Group {
                            if kind == .wanted {
                                Text("Nobody is looking for \(c.shortLabel) parts yet.")
                            } else {
                                Text("Nothing listed for a \(c.shortLabel) yet.")
                            }
                        }
                        .typeStyle(.body).foregroundStyle(Color.dust)
                        QuietButton("Search all cars") { fitsCar = nil }
                    } else if kind == .wanted {
                        EmptyState("Nobody has posted a wanted ad yet.", actionTitle: "Post what you want") { listing = true }
                    } else {
                        EmptyState("Nothing for sale near you yet.", actionTitle: "List something") { listing = true }
                    }
                }
                if kind == .part {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s12), GridItem(.flexible())], spacing: Space.s16) {
                        ForEach(shown) { l in card(l) }
                    }
                } else if kind == .car {
                    ForEach(shown) { l in carRow(l) }
                } else {
                    ForEach(shown) { l in wantedRow(l) }
                }
                if next != nil {
                    Color.clear.frame(height: 1).onAppear { Task { await load(more: true) } }
                }
            }
            .padding(Space.margin)
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle("Market")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { IconButton("tray", label: "Yours") { yours = true } }
            ToolbarItem(placement: .topBarTrailing) { IconButton(Symbol.add, label: "List something") { listing = true } }
            ToolbarItem(placement: .topBarTrailing) {
                IconButton("line.3.horizontal.decrease", label: "Filter") { showFilter = true }
            }
        }
        .sheet(isPresented: $listing, onDismiss: { Task { await load(more: false) } }) { ListSomething(env: env, initialKind: kind) }
        .navigationDestination(isPresented: $yours) { Yours(env: env) }
        .sheet(isPresented: $showFilter) {
            Sheet(Text("Filter")) {
                VStack(alignment: .leading, spacing: Space.s16) {
                    HStack(spacing: Space.s12) {
                        Field(kind == .wanted ? "Min budget" : "Min price", text: $minPrice, prompt: "$").keyboardType(.numberPad)
                        Field(kind == .wanted ? "Max budget" : "Max price", text: $maxPrice, prompt: "$").keyboardType(.numberPad)
                    }
                    if kind != .car {
                        CategoryPicker(selection: $category, noneTitle: "All parts").padding(.horizontal, -Space.margin)
                    }
                    Text("Condition").typeStyle(.foot).foregroundStyle(Color.dust)
                    HStack(spacing: Space.s8) {
                        ForEach([(ListingCondition.new, LocalizedStringKey("New")), (.used, "Used"), (.forParts, "For parts")], id: \.0) { c, t in
                            Chip(t, isSelected: conditions.contains(c)) {
                                if conditions.contains(c) { conditions.remove(c) } else { conditions.insert(c) }
                            }
                        }
                    }
                    Text("Distance").typeStyle(.foot).foregroundStyle(Color.dust)
                    HStack(spacing: Space.s8) {
                        ForEach([5, 25, 50, 100], id: \.self) { n in
                            Chip("\(n) \(Units.name)", isSelected: within == n) { within = n; if here == nil { here = Coarse.here() } }
                        }
                        Chip("Any", isSelected: within == nil) { within = nil }
                    }
                    if within != nil {
                        Text(here == nil ? "Turn on location to filter by distance." : "Distance is approximate.")
                            .typeStyle(.foot).foregroundStyle(Color.dust)
                    }
                    QuietButton("Clear") { minPrice = ""; maxPrice = ""; conditions = []; category = nil; within = nil }
                }
                .padding(Space.margin)
            }
            .presentationDetents([.medium])
        }
        .task {
            here = Coarse.here()
            if let me = await env.auth.currentSession()?.userID {
                cars = (try? await env.garage.cars(of: me)) ?? []
                if fitsCar == nil { fitsCar = cars.first }
            }
        }
        .task(id: filter) {
            try? await Task.sleep(for: .milliseconds(250))
            await load(more: false)
        }
        .refreshable { await load(more: false) }
    }

    private func load(more: Bool) async {
        loading = true
        let page = try? await env.market.listings(filter, after: more ? next : nil, limit: 20)
        listings = (more ? listings : []) + (page?.items ?? [])
        next = page?.next
        loading = false
    }

    private func photo(_ l: Listing) -> URL? { l.photos.first.map { env.media.publicURL(bucket: .listings, path: $0.path) } }

    private func card(_ l: Listing) -> some View {
        Button { env.router.open(.listing(l.id)) } label: {
            VStack(alignment: .leading, spacing: Space.s4) {
                MediaView(url: photo(l), aspectRatio: 1, cornerRadius: Radius.r12, label: Text(verbatim: l.title))
                Text(verbatim: l.title).typeStyle(.sub).foregroundStyle(Color.chalk).lineLimit(2).multilineTextAlignment(.leading)
                Text(verbatim: Price.text(l.priceCents)).typeStyle(.readoutM).foregroundStyle(Color.chalk)
                Text(verbatim: l.region).typeStyle(.foot).foregroundStyle(Color.dust)
            }
        }
        .buttonStyle(.plain)
    }

    private func wantedRow(_ l: Listing) -> some View {
        Button { env.router.open(.listing(l.id)) } label: {
            Row(Text(verbatim: l.title), subtitle: Text("Budget \(Price.text(l.priceCents)) · \(l.region)"), trailing: { Disclosure() })
                .padding(.horizontal, -Space.margin)
        }
        .buttonStyle(RowButtonStyle())
    }

    private func carRow(_ l: Listing) -> some View {
        Button { env.router.open(.listing(l.id)) } label: {
            VStack(alignment: .leading, spacing: Space.s4) {
                MediaView(url: photo(l), aspectRatio: 16.0 / 9.0, cornerRadius: Radius.r12, label: Text(verbatim: l.title))
                Text(verbatim: l.title).typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
                Text(verbatim: Price.text(l.priceCents)).typeStyle(.readoutM).foregroundStyle(Color.chalk)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: K2 Listing

struct ListingScreen: View {
    let env: AppEnvironment
    let id: ListingID
    @State private var listing: Listing?
    @State private var seller: Profile?
    @State private var me: UserID?
    @State private var editing = false

    var body: some View {
        ScrollView {
            if let l = listing {
                VStack(alignment: .leading, spacing: Space.s12) {
                    TabView {
                        ForEach(l.photos) { p in
                            MediaView(url: env.media.publicURL(bucket: .listings, path: p.path), aspectRatio: 4.0 / 3.0, cornerRadius: 0,
                                      label: Text(verbatim: l.title))
                        }
                    }
                    .tabViewStyle(.page)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    VStack(alignment: .leading, spacing: Space.s8) {
                        Text(verbatim: l.title).typeStyle(.title).foregroundStyle(Color.chalk)
                        if l.kind == .wanted { Text("Budget").typeStyle(.foot).foregroundStyle(Color.dust) }
                        HStack {
                            Text(verbatim: Price.text(l.priceCents)).typeStyle(.readoutL).foregroundStyle(Color.chalk)
                                .strikethrough(l.status == .sold)
                            if l.status == .sold {
                                Text(l.kind == .wanted ? "Found" : "Sold").typeStyle(.label).foregroundStyle(Color.brake)
                            }
                            if l.sellerID == me, l.isExpired() {
                                Text("Expired").typeStyle(.label).foregroundStyle(Color.dust)
                            }
                        }
                        if l.kind == .wanted {
                            Text(verbatim: l.region).typeStyle(.sub).foregroundStyle(Color.dust)
                        } else {
                            Text(verbatim: "\(l.condition.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) · \(l.region)")
                                .typeStyle(.sub).foregroundStyle(Color.dust)
                        }
                        if let c = l.category { Text(c.title).typeStyle(.sub).foregroundStyle(Color.dust) }
                        if let f = l.fits {
                            Text(verbatim: "Fits: \(f.make) \(f.model ?? "")\(f.yearFrom.map { " \($0)" } ?? "")\(f.yearTo.map { "–\($0)" } ?? "")")
                                .typeStyle(.sub).foregroundStyle(Color.chalk)
                        }
                        if !l.description.isEmpty { Text(verbatim: l.description).typeStyle(.body).foregroundStyle(Color.chalk) }
                    }
                    .padding(.horizontal, Space.margin)
                    if let s = seller {
                        Button { env.router.open(.profile(s.userID)) } label: {
                            Row(Text(verbatim: s.displayName), subtitle: Text("Member since \(s.createdAt.formatted(.dateTime.year()))"), leading: {
                                Avatar(name: s.displayName, url: s.avatarPath.map { env.media.publicURL(bucket: .avatars, path: $0) }, size: .s40)
                            }, trailing: { Disclosure() })
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
                .padding(.bottom, Size.row * 3)
            } else {
                SkeletonBlock(height: Size.row * 5).padding(Space.margin)
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { if let l = listing { bar(l) } }
        .toolbar {
            if let l = listing, l.sellerID != me {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Report") { env.router.open(.reportContent(ContentRef(kind: .listing, id: l.id.description))) }
                    } label: { Image.symbol(Symbol.more) }
                }
            }
        }
        .sheet(isPresented: $editing, onDismiss: { Task { await load() } }) {
            if let l = listing { ListSomething(env: env, editing: l) }
        }
        .task { await load() }
    }

    private func bar(_ l: Listing) -> some View {
        VStack(spacing: Space.s8) {
            Text("Meet in a public place. Waypoints doesn't handle payment.").typeStyle(.foot).foregroundStyle(Color.dust)
            HStack(spacing: Space.s12) {
                if l.sellerID == me {
                    if l.isExpired() {
                        PrimaryButton("Relist") { Task { try? await env.market.relist(l.id); await load() } }
                        SecondaryButton("Edit") { editing = true }
                    } else if l.status != .sold {
                        PrimaryButton(l.kind == .wanted ? "Mark as found" : "Mark as sold") {
                            Task { try? await env.market.setStatus(.sold, for: l.id); await load() }
                        }
                        SecondaryButton("Edit") { editing = true }
                    }
                } else if l.status != .sold {
                    PrimaryButton(l.kind == .wanted ? "Message" : "Message seller") {
                        Task {
                            if let t = try? await env.messages.openThread(with: l.sellerID, listing: l.id) {
                                if (try? await env.messages.messages(in: .thread(t.id), before: nil, limit: 1))?.isEmpty ?? true {
                                    let opener = l.kind == .wanted ? "I have one." : "Is this still available?"
                                    _ = try? await env.messages.send(opener, attachmentPath: nil, to: .thread(t.id))
                                }
                                env.router.open(.thread(t.id))
                            }
                        }
                    }
                    IconButton(l.savedByMe ? "bookmark.fill" : "bookmark", label: l.savedByMe ? "Unsave" : "Save") {
                        Task {
                            if l.savedByMe { try? await env.market.unsave(l.id) } else { try? await env.market.save(l.id) }
                            await load()
                        }
                    }
                }
            }
        }
        .padding(Space.margin)
        .background(Color.tarmac)
    }

    private func load() async {
        me = await env.auth.currentSession()?.userID
        listing = try? await env.market.listing(id)
        if let l = listing { seller = try? await env.profiles.profile(l.sellerID) }
    }
}

// MARK: K3 List something

struct ListSomething: View {
    let env: AppEnvironment
    /// Set when editing an existing listing (MKT-4); photos stay as they are.
    var editing: Listing?
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PhotosPickerItem] = []
    @State private var images: [Data] = []
    @State private var pick = false
    @State private var kind: ListingKind = .part
    @State private var title = ""
    @State private var price = ""
    @State private var condition: ListingCondition = .used
    @State private var fits: Fitment?
    @State private var car: Car?
    @State private var cars: [Car] = []
    @State private var description = ""
    @State private var region = ""
    @State private var picking = false
    @State private var saving = false
    @State private var error: String?
    @State private var category: ListingCategory?

    init(env: AppEnvironment, initialKind: ListingKind = .part) {
        self.env = env
        _kind = State(initialValue: initialKind)
    }

    init(env: AppEnvironment, editing l: Listing) {
        self.env = env
        editing = l
        _kind = State(initialValue: l.kind)
        _title = State(initialValue: l.title)
        _price = State(initialValue: String(l.priceCents / 100))
        _condition = State(initialValue: l.condition)
        _fits = State(initialValue: l.fits)
        _description = State(initialValue: l.description)
        _region = State(initialValue: l.region)
        _category = State(initialValue: l.category)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s16) {
                    ScrollView(.horizontal) {
                        HStack(spacing: Space.s8) {
                            ForEach(Array(images.enumerated()), id: \.offset) { i, d in
                                if let ui = UIImage(data: d) {
                                    Image(uiImage: ui).resizable().scaledToFill().frame(width: Size.row * 1.6, height: Size.row * 1.6)
                                        .clipShape(RoundedRectangle(cornerRadius: Radius.r12))
                                        .overlay(alignment: .bottomLeading) {
                                            if i == 0 {
                                                Text("Cover").typeStyle(.label).foregroundStyle(Color.chalk)
                                                    .padding(Space.s4).background(Color.asphalt, in: RoundedRectangle(cornerRadius: Radius.r6))
                                                    .padding(Space.s4)
                                            }
                                        }
                                        .draggable(String(i)) {
                                            Image(uiImage: ui).resizable().scaledToFill().frame(width: Size.row, height: Size.row)
                                                .clipShape(RoundedRectangle(cornerRadius: Radius.r6))
                                        }
                                        .dropDestination(for: String.self) { dropped, _ in
                                            guard let from = dropped.first.flatMap { Int($0) }, images.indices.contains(from), from != i else { return false }
                                            images.move(fromOffsets: IndexSet(integer: from), toOffset: from < i ? i + 1 : i)
                                            return true
                                        }
                                        .accessibilityLabel(i == 0 ? Text("Cover photo") : Text("Photo \(i + 1)"))
                                        .accessibilityActions {
                                            if i > 0 { Button("Make cover") { images.move(fromOffsets: IndexSet(integer: i), toOffset: 0) } }
                                            if i > 0 { Button("Move left") { images.swapAt(i, i - 1) } }
                                            if i < images.count - 1 { Button("Move right") { images.swapAt(i, i + 1) } }
                                        }
                                }
                            }
                            if images.count < 8, editing == nil {
                                Button { pick = true } label: {
                                    Image.symbol(Symbol.camera).foregroundStyle(Color.sodium)
                                        .frame(width: Size.row * 1.6, height: Size.row * 1.6)
                                        .background(Color.concrete, in: RoundedRectangle(cornerRadius: Radius.r12))
                                }
                                .accessibilityLabel(Text("Add photos"))
                            }
                        }
                    }
                    if images.count > 1 {
                        Text("Drag to reorder. The first photo is the cover.").typeStyle(.foot).foregroundStyle(Color.dust)
                    }
                    Text("What is it?").typeStyle(.foot).foregroundStyle(Color.dust)
                    SegmentedSwitch(selection: $kind, options: [(.part, "Part"), (.car, "Car"), (.wanted, "Wanted")])
                    Field("Title", text: $title, prompt: kind == .wanted ? "What you're looking for" : nil, limit: 70)
                    Field(kind == .wanted ? "Budget" : "Price", text: $price, prompt: "$").keyboardType(.numberPad)
                    if kind != .wanted {
                        HStack(spacing: Space.s8) {
                            Chip("New", isSelected: condition == .new) { condition = .new }
                            Chip("Used", isSelected: condition == .used) { condition = .used }
                            Chip("For parts", isSelected: condition == .forParts) { condition = .forParts }
                        }
                    }
                    if kind != .car {
                        CategoryPicker(selection: $category, noneTitle: "Choose one").padding(.horizontal, -Space.margin)
                    }
                    if kind != .car {
                        Button { picking = true } label: {
                            Row(Text("Fits"), showsDivider: false, trailing: {
                                Text(verbatim: fits.map { "\($0.make) \($0.model ?? "")" } ?? "Any car").typeStyle(.sub)
                            })
                        }
                    } else {
                        Menu {
                            ForEach(cars) { c in
                                Button(c.shortLabel) {
                                    car = c
                                    if title.isEmpty { title = c.fullLabel }
                                }
                            }
                        } label: {
                            Row(Text("Choose from your garage"), showsDivider: false, trailing: { Text(verbatim: car?.shortLabel ?? "").typeStyle(.sub) })
                        }
                    }
                    Field("Description", text: $description, limit: 1500, axis: .vertical)
                    Field("Region", text: $region, prompt: "Like 'South Jersey'", limit: 40)
                    if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                    PrimaryButton(editing == nil ? (kind == .wanted ? "Post it" : "List it") : "Save changes", isLoading: saving) { save() }
                        .disabled(title.isEmpty || Int(price) == nil || region.isEmpty)
                }
                .padding(Space.margin)
            }
            .background(Color.asphalt.ignoresSafeArea())
            .navigationTitle(editing == nil ? "List something" : "Edit listing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { QuietButton("Cancel") { dismiss() } } }
            .photosPicker(isPresented: $pick, selection: $items, maxSelectionCount: 8, matching: .images)
            .sheet(isPresented: $picking) {
                NavigationStack {
                    VehiclePicker(catalog: env.catalog, mode: .range) { p in
                        if case let .fitment(f) = p { fits = f }
                        picking = false
                    }
                    .navigationTitle("Fits")
                }
            }
        }
        .onChange(of: items) {
            Task {
                var out: [Data] = []
                for i in items { if let d = try? await i.loadTransferable(type: Data.self) { out.append(d) } }
                images = out
            }
        }
        .task {
            if let me = await env.auth.currentSession()?.userID { cars = (try? await env.garage.cars(of: me)) ?? [] }
            if region.isEmpty { region = (try? await env.profiles.myProfile().homeRegion) ?? "" }
        }
    }

    private func save() {
        saving = true
        Task {
            if case .blocked = await env.safety.check(title + " " + description) {
                error = "That listing can't be posted."
                saving = false
                return
            }
            let cents = (Int(price) ?? 0) * 100
            let cat = kind == .car ? nil : category
            if var l = editing {
                l.kind = kind; l.title = title; l.priceCents = cents; l.condition = condition; l.description = description
                l.fits = kind == .car ? nil : fits; l.region = region; l.category = cat
                if let c = car { l.carID = c.id }
                do {
                    _ = try await env.market.updateListing(l)
                    dismiss()
                } catch {
                    self.error = message(for: error, fallback: "Couldn't save it. Check your connection and try again.")
                }
                saving = false
                return
            }
            do {
                var paths: [String] = []
                for d in images { paths.append(try await env.media.upload(d, contentType: "image/jpeg", to: .listings) { _ in }.path) }
                _ = try await env.market.createListing(ListingDraft(kind: kind, title: title, priceCents: cents,
                                                                   condition: condition, description: description,
                                                                   fits: kind == .car ? nil : fits,
                                                                   carID: kind == .car ? car?.id : nil, region: region,
                                                                   photoPaths: paths, category: cat, near: Coarse.here()))
                dismiss()
            } catch {
                self.error = message(for: error, fallback: "Couldn't list it. Check your connection and try again.")
            }
            saving = false
        }
    }
}

// MARK: K4 Yours

struct Yours: View {
    let env: AppEnvironment
    @State private var tab = 0
    @State private var selling: [Listing] = []
    @State private var saved: [Listing] = []
    @State private var error: String?
    @State private var listing = false

    var body: some View {
        // A plain List only for its swipe actions (K4); rows keep the Row look on asphalt.
        List {
            Group {
                SegmentedSwitch(selection: $tab, options: [(0, "Selling"), (1, "Saved")]).padding(Space.margin)
                if let error {
                    Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake).padding(.horizontal, Space.margin)
                }
                let list = tab == 0 ? selling : saved
                if list.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s8) {
                        Text(tab == 0 ? "You haven't listed anything." : "Nothing saved yet.").typeStyle(.body).foregroundStyle(Color.dust)
                        if tab == 0 { QuietButton("List something") { listing = true } }
                    }
                    .padding(Space.margin)
                }
                ForEach(list) { l in
                    Button { env.router.open(.listing(l.id)) } label: {
                        Row(Text(verbatim: l.title), subtitle: l.kind == .wanted ? Text("Budget \(Price.text(l.priceCents))") : Text(verbatim: Price.text(l.priceCents)), leading: {
                            MediaView(url: l.photos.first.map { env.media.publicURL(bucket: .listings, path: $0.path) }, aspectRatio: 1,
                                      cornerRadius: Radius.r6, label: Text(verbatim: l.title))
                                .frame(width: Size.hitTarget, height: Size.hitTarget)
                        }, trailing: {
                            status(l).typeStyle(.foot)
                        })
                    }
                    .buttonStyle(RowButtonStyle())
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if tab == 0, l.status != .removed {
                            Button("Remove", role: .destructive) { act { try await env.market.setStatus(.removed, for: l.id) } }
                                .tint(Color.brake)
                            if l.isExpired() {
                                Button("Relist") { act { try await env.market.relist(l.id) } }.tint(Color.sodium)
                            } else if l.status != .sold {
                                Button(l.kind == .wanted ? "Found" : "Sold") { act { try await env.market.setStatus(.sold, for: l.id) } }
                                    .tint(Color.sodium)
                            }
                        }
                    }
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.asphalt)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle("Yours")
        .sheet(isPresented: $listing, onDismiss: { Task { await load() } }) { ListSomething(env: env) }
        .task { await load() }
        .refreshable { await load() }
    }

    private func status(_ l: Listing) -> Text {
        if l.isExpired() { return Text("Expired") }
        if l.status == .sold { return l.kind == .wanted ? Text("Found") : Text("Sold") }
        return Text(verbatim: l.status.rawValue.capitalized)
    }

    private func act(_ op: @escaping @Sendable @MainActor () async throws -> Void) {
        Task {
            do {
                try await op()
                error = nil
            } catch {
                self.error = message(for: error, fallback: "Couldn't change it. Check your connection and try again.")
            }
            await load()
        }
    }

    private func load() async {
        if let me = await env.auth.currentSession()?.userID { selling = (try? await env.market.listings(by: me)) ?? [] }
        saved = (try? await env.market.savedListings()) ?? []
    }
}
