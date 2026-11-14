import Core
import Foundation
import UIKit
import UserNotifications

// GAR-16 service log, SET-3 units, SAFE-9 copy.

enum GarageCopy {
    /// SAFE-9: shown when the server refuses with `rateLimited`.
    static let rateLimited = "You're doing that a lot. Try again in a few minutes."
}

/// SET-3: weights and distances in the device's units.
enum GarageUnits {
    /// "3,705 lb" or "1,681 kg".
    static func weight(lb: Int) -> String {
        Measurement(value: Double(lb), unit: UnitMass.pounds)
            .formatted(.measurement(width: .abbreviated, usage: .general, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    /// The odometer unit a new service entry starts in: miles where the locale drives in miles.
    static var defaultOdometer: OdometerUnit {
        switch Locale.current.measurementSystem {
        case .us, .uk: .mi
        default: .km
        }
    }

    /// An odometer reading as entered, in the unit read off the dash: "45,210 mi".
    static func odometer(_ value: Int, _ unit: OdometerUnit) -> String {
        "\(value.formatted(.number)) \(unit.rawValue)"
    }
}

/// The local service reminder for a timeline entry. Scheduled on the device at 9:00 on the
/// chosen day; no server job.
enum ServiceReminder {
    static func identifier(_ id: BuildEntryID) -> String { "service-\(id)" }

    static func cancel(_ id: BuildEntryID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier(id)])
    }

    /// Replaces any reminder for `entry`; clears it when the entry has no future reminder day.
    static func sync(_ entry: BuildEntry, car: Car) async {
        cancel(entry.id)
        guard entry.isService, let day = entry.remindOn else { return }
        var parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        parts.hour = 9
        guard let fireAt = Calendar.current.date(from: parts), fireAt > .now else { return }
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
        content.title = car.nickname ?? car.shortLabel
        content.body = String(localized: "Service reminder: \(entry.title)")
        content.sound = .default
        if let url = Route.car(car.id).shareURL(host: nil) { content.userInfo = ["url": url.absoluteString] }
        let request = UNNotificationRequest(identifier: identifier(entry.id), content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        try? await center.add(request)
    }
}
