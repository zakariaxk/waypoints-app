import Core
import DesignSystem
import MapKit
import SwiftUI
import UserNotifications

// MARK: MEET-6 reminders

/// The local "starts in 30 minutes" reminder for a meet you're Going to. Scheduled on the
/// device; no server job. The answer to "Remind you before it starts?" is kept per meet so
/// Going asks it once.
enum MeetReminder {
    static let lead: TimeInterval = 30 * 60

    private static func key(_ id: MeetID) -> String { "meet.remind.\(id)" }
    private static func identifier(_ id: MeetID) -> String { "meet.reminder.\(id)" }

    /// nil until the person has answered for this meet.
    static func answer(for id: MeetID) -> Bool? { UserDefaults.standard.object(forKey: key(id)) as? Bool }
    static func setAnswer(_ yes: Bool, for id: MeetID) { UserDefaults.standard.set(yes, forKey: key(id)) }

    /// Brings the pending reminder in line with the meet and the RSVP: scheduled (or moved to a
    /// new start time) while Going with a yes, removed otherwise.
    static func sync(_ meet: Meet, going: Bool) async {
        if going, meet.cancelledAt == nil, answer(for: meet.id) == true {
            await schedule(meet)
        } else {
            cancel(meet.id)
        }
    }

    static func cancel(_ id: MeetID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier(id)])
    }

    /// The first yes is a notification permission moment (plan 10.2, ACC-7): asked even when the
    /// meet is too close for this reminder, so the first Going RSVP is where it happens.
    private static func schedule(_ meet: Meet) async {
        let fireAt = meet.startsAt.addingTimeInterval(-lead)
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            UserDefaults.standard.set(true, forKey: "notifications.asked")
            guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        case .denied:
            return
        default:
            break
        }
        guard fireAt > .now else { cancel(meet.id); return }
        let content = UNMutableNotificationContent()
        content.title = meet.title
        content.body = meet.placeName.isEmpty
            ? String(localized: "Starts in 30 minutes.", bundle: .module)
            : String(localized: "Starts in 30 minutes at \(meet.placeName).", bundle: .module)
        content.sound = .default
        content.userInfo = ["url": "waypoints://meet/\(meet.id)"]
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireAt)
        let request = UNNotificationRequest(identifier: identifier(meet.id), content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        try? await center.add(request)
    }
}

/// E2 "Going": which car, and whether to be reminded, asked once in one sheet (MEET-4).
struct GoingSheet: View {
    let cars: [Car]
    let askCar: Bool
    let askRemind: Bool
    let onGo: (_ car: CarID?, _ remind: Bool?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var car: CarID?
    @State private var remind = true

    init(cars: [Car], askCar: Bool, askRemind: Bool, onGo: @escaping (CarID?, Bool?) -> Void) {
        self.cars = cars; self.askCar = askCar; self.askRemind = askRemind; self.onGo = onGo
        _car = State(initialValue: cars.first?.id)
    }

    var body: some View {
        Sheet(Text("Going", bundle: .module)) {
            VStack(alignment: .leading, spacing: Space.s16) {
                if askCar {
                    Text("Which car are you bringing?", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust)
                    VStack(spacing: 0) {
                        ForEach(cars) { c in
                            Button { car = c.id } label: {
                                Row(Text(verbatim: c.shortLabel), trailing: {
                                    if car == c.id { Image(systemName: "checkmark").foregroundStyle(Color.sodium).accessibilityHidden(true) }
                                })
                            }
                            .buttonStyle(RowButtonStyle())
                            .accessibilityAddTraits(car == c.id ? .isSelected : [])
                        }
                        Button { car = nil } label: {
                            Row(Text("Not sure yet", bundle: .module), showsDivider: false, trailing: {
                                if car == nil { Image(systemName: "checkmark").foregroundStyle(Color.sodium).accessibilityHidden(true) }
                            })
                        }
                        .accessibilityAddTraits(car == nil ? .isSelected : [])
                        .buttonStyle(RowButtonStyle())
                    }
                }
                if askRemind {
                    Row(Text("Remind you before it starts?", bundle: .module), subtitle: Text("30 minutes before", bundle: .module), showsDivider: false, trailing: {
                        Toggle("", isOn: $remind).labelsHidden().tint(.sodium)
                    })
                }
                PrimaryButton("I'm going") {
                    onGo(askCar ? car : cars.first?.id, askRemind ? remind : nil)
                    dismiss()
                }
            }
            .padding(Space.margin)
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: MEET-12 recurrence copy

extension MeetFormat {
    static func recurrenceTitle(_ r: MeetRecurrence?) -> LocalizedStringKey {
        switch r {
        case nil: "Doesn't repeat"
        case .weekly: "Weekly"
        case .biweekly: "Every two weeks"
        case .monthly: "Monthly"
        }
    }

    /// "Every Saturday", "Every other Saturday", "First Saturday of the month".
    static func repeats(_ m: Meet) -> String? {
        guard let r = m.recurrence else { return nil }
        let day = m.startsAt.formatted(.dateTime.weekday(.wide))
        switch r {
        case .weekly: return String(localized: "Every \(day)", bundle: .module)
        case .biweekly: return String(localized: "Every other \(day)", bundle: .module)
        case .monthly:
            let nth = (Calendar.current.component(.day, from: m.startsAt) - 1) / 7
            let ordinal = [String(localized: "First", bundle: .module), String(localized: "Second", bundle: .module), String(localized: "Third", bundle: .module),
                           String(localized: "Fourth", bundle: .module), String(localized: "Last", bundle: .module)][min(nth, 4)]
            return String(localized: "\(ordinal) \(day) of the month", bundle: .module)
        }
    }
}

// MARK: LINK-5 share card

/// A meet as an image: map snapshot with the pin, title, time, and place.
struct MeetShareCard: View {
    let meet: Meet
    let map: UIImage?

    static let width = Size.row * 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let map {
                    Image(uiImage: map).resizable().scaledToFill()
                } else {
                    Color.concrete
                }
                MeetPin(kind: meet.kind.rawValue).frame(width: Size.Marker.meetPin, height: Size.Marker.meetPin)
            }
            .frame(width: Self.width, height: Size.row * 3)
            .clipped()
            VStack(alignment: .leading, spacing: Space.s4) {
                Text(MeetFormat.kindTitle(meet.kind)).typeStyle(.label).foregroundStyle(Color.sodium)
                Text(verbatim: meet.title).typeStyle(.title).foregroundStyle(Color.chalk)
                Text(verbatim: meet.startsAt.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))
                    .typeStyle(.readoutM).foregroundStyle(Color.chalk)
                if !meet.placeName.isEmpty {
                    Text(verbatim: meet.placeName).typeStyle(.sub).foregroundStyle(Color.dust)
                }
                if let r = MeetFormat.repeats(meet) {
                    Text(verbatim: r).typeStyle(.sub).foregroundStyle(Color.dust)
                }
                Text("Waypoints", bundle: .module).typeStyle(.label).foregroundStyle(Color.gravel).padding(.top, Space.s8)
            }
            .padding(Space.s16)
            .frame(width: Self.width, alignment: .leading)
        }
        .background(Color.tarmac)
        .clipShape(RoundedRectangle(cornerRadius: Radius.r20))
        .environment(\.colorScheme, .dark)
    }

    /// Renders the card with a fresh dark map snapshot around the meet.
    @MainActor
    static func render(_ meet: Meet, scale: CGFloat) async -> UIImage? {
        let map = await snapshot(meet.coordinate, size: CGSize(width: width, height: Size.row * 3))
        let renderer = ImageRenderer(content: MeetShareCard(meet: meet, map: map))
        renderer.scale = scale
        return renderer.uiImage
    }

    private static func snapshot(_ c: Coordinate, size: CGSize) async -> UIImage? {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude),
                                            latitudinalMeters: 1200, longitudinalMeters: 1200)
        options.size = size
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        options.pointOfInterestFilter = .excludingAll
        let snapshotter = MKMapSnapshotter(options: options)
        return await withCheckedContinuation { (done: CheckedContinuation<UIImage?, Never>) in
            snapshotter.start { snap, _ in done.resume(returning: snap?.image) }
        }
    }
}

// MARK: FEED-11 posts from this meet

/// E2's "Posts" strip: posts tagged with the meet, newest first. Hidden when there are none.
struct MeetPostsStrip: View {
    let env: AppEnvironment
    let meetID: MeetID
    @State private var posts: [Post] = []

    var body: some View {
        Group {
            if !posts.isEmpty {
                VStack(alignment: .leading, spacing: Space.s8) {
                    Text("Posts", bundle: .module).typeStyle(.label).foregroundStyle(Color.dust)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.s8) {
                            ForEach(posts) { p in
                                Button { env.router.open(.post(p.id)) } label: {
                                    MediaView(url: env.media.publicURL(bucket: .posts, path: p.posterPath), aspectRatio: 9.0 / 16.0,
                                              cornerRadius: Radius.r12, label: Text(verbatim: p.caption))
                                        .frame(width: Size.row * 1.5, height: Size.row * 2.67)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .task(id: meetID) { posts = (try? await env.posts.postsFromMeet(meetID)) ?? [] }
    }
}

// MARK: SET-3 distances, MEET-14 eligibility

extension MeetFormat {
    /// A distance in the locale's road units ("2.3 mi", "3.7 km").
    static func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    /// The place name with how far it is from you, when both are known.
    static func place(_ m: Meet, from here: Coordinate?) -> String {
        guard let here else { return m.placeName }
        let away = distance(here.distance(to: m.coordinate))
        return m.placeName.isEmpty ? away : "\(m.placeName) · \(away)"
    }

    /// People's choice runs at meets and shows (MEET-14).
    static func hasChoice(_ m: Meet) -> Bool { m.kind == .meet || m.kind == .show }
}

// MARK: MEET-13 road route

/// Google encoded polyline, precision 5: the convoy route format (`ConvoyState.routePolyline`).
enum Polyline {
    static func encode(_ path: [Coordinate]) -> String {
        var out = ""
        var lastLat = 0, lastLng = 0
        for c in path {
            let lat = Int((c.latitude * 1e5).rounded()), lng = Int((c.longitude * 1e5).rounded())
            append(lat - lastLat, to: &out)
            append(lng - lastLng, to: &out)
            lastLat = lat; lastLng = lng
        }
        return out
    }

    private static func append(_ delta: Int, to out: inout String) {
        var v = delta < 0 ? ~(delta << 1) : delta << 1
        while v >= 0x20 {
            out.unicodeScalars.append(Unicode.Scalar(UInt8((0x20 | (v & 0x1f)) + 63)))
            v >>= 5
        }
        out.unicodeScalars.append(Unicode.Scalar(UInt8(v + 63)))
    }
}
