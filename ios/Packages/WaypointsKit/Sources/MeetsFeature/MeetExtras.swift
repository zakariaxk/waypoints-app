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

    /// The first yes is a notification permission moment (plan 10.2).
    private static func schedule(_ meet: Meet) async {
        let fireAt = meet.startsAt.addingTimeInterval(-lead)
        guard fireAt > .now else { cancel(meet.id); return }
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
        let content = UNMutableNotificationContent()
        content.title = meet.title
        content.body = meet.placeName.isEmpty
            ? String(localized: "Starts in 30 minutes.")
            : String(localized: "Starts in 30 minutes at \(meet.placeName).")
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
        Sheet(Text("Going")) {
            VStack(alignment: .leading, spacing: Space.s16) {
                if askCar {
                    Text("Which car are you bringing?").typeStyle(.foot).foregroundStyle(Color.dust)
                    VStack(spacing: 0) {
                        ForEach(cars) { c in
                            Button { car = c.id } label: {
                                Row(Text(verbatim: c.shortLabel), trailing: {
                                    if car == c.id { Image(systemName: "checkmark").foregroundStyle(Color.sodium) }
                                })
                            }
                            .buttonStyle(RowButtonStyle())
                        }
                        Button { car = nil } label: {
                            Row(Text("Not sure yet"), showsDivider: false, trailing: {
                                if car == nil { Image(systemName: "checkmark").foregroundStyle(Color.sodium) }
                            })
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
                if askRemind {
                    Row(Text("Remind you before it starts?"), subtitle: Text("30 minutes before"), showsDivider: false, trailing: {
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
        case .weekly: return String(localized: "Every \(day)")
        case .biweekly: return String(localized: "Every other \(day)")
        case .monthly:
            let nth = (Calendar.current.component(.day, from: m.startsAt) - 1) / 7
            let ordinal = [String(localized: "First"), String(localized: "Second"), String(localized: "Third"),
                           String(localized: "Fourth"), String(localized: "Last")][min(nth, 4)]
            return String(localized: "\(ordinal) \(day) of the month")
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
                Text("Waypoints").typeStyle(.label).foregroundStyle(Color.gravel).padding(.top, Space.s8)
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
