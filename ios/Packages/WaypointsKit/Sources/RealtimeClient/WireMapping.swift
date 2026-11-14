import Core
import Foundation
import WireProtocol

/// Conversions between `Core` models and the generated wire types (plan section 6).
enum WireMapping {
    static func e7(_ degrees: Double) -> Int32 {
        Int32(clamping: Int64((degrees * 1e7).rounded()))
    }

    static func degrees(_ e7: Int32) -> Double { Double(e7) / 1e7 }

    static func coordinate(lat: Int32, lng: Int32) -> Coordinate {
        Coordinate(latitude: degrees(lat), longitude: degrees(lng))
    }

    static func date(ms: UInt64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    static func ms(_ date: Date) -> UInt64 { UInt64(max(0, date.timeIntervalSince1970 * 1000)) }

    // MARK: Client frames

    static func hello(token: String, appVersion: String) -> Waypoints_V1_ClientFrame {
        var hello = Waypoints_V1_Hello()
        hello.accessToken = token
        hello.protocol = RealtimeProtocol.version
        hello.appVersion = appVersion
        var frame = Waypoints_V1_ClientFrame()
        frame.hello = hello
        return frame
    }

    static func refresh(token: String) -> Waypoints_V1_ClientFrame {
        var refresh = Waypoints_V1_RefreshToken()
        refresh.accessToken = token
        var frame = Waypoints_V1_ClientFrame()
        frame.refreshToken = refresh
        return frame
    }

    static func location(_ sample: LocationSample, seq: UInt32) -> Waypoints_V1_ClientFrame {
        var update = Waypoints_V1_LocationUpdate()
        update.seq = seq
        update.latE7 = e7(sample.coordinate.latitude)
        update.lngE7 = e7(sample.coordinate.longitude)
        if let heading = sample.heading, heading.isFinite {
            let wrapped = heading.truncatingRemainder(dividingBy: 360)
            update.headingDeg = UInt32((wrapped < 0 ? wrapped + 360 : wrapped).rounded()) % 360
        } else {
            update.headingDeg = 360
        }
        update.speedCms = UInt32(clamping: Int64((max(0, sample.speed) * 100).rounded()))
        update.accuracyM = UInt32(clamping: Int64(max(0, sample.horizontalAccuracy).rounded()))
        update.clientMs = ms(sample.timestamp)
        var frame = Waypoints_V1_ClientFrame()
        frame.location = update
        return frame
    }

    static func viewport(_ region: MapRegion) -> Waypoints_V1_ClientFrame {
        var viewport = Waypoints_V1_SetViewport()
        viewport.minLatE7 = e7(region.minLatitude)
        viewport.minLngE7 = e7(region.minLongitude)
        viewport.maxLatE7 = e7(region.maxLatitude)
        viewport.maxLngE7 = e7(region.maxLongitude)
        var frame = Waypoints_V1_ClientFrame()
        frame.viewport = viewport
        return frame
    }

    static func ping(now: Date = .now) -> Waypoints_V1_ClientFrame {
        var ping = Waypoints_V1_Ping()
        ping.clientMs = ms(now)
        var frame = Waypoints_V1_ClientFrame()
        frame.ping = ping
        return frame
    }

    static func join(_ convoy: ConvoyID) -> Waypoints_V1_ClientFrame {
        var join = Waypoints_V1_JoinConvoy()
        join.convoyID = convoy.raw
        var frame = Waypoints_V1_ClientFrame()
        frame.joinConvoy = join
        return frame
    }

    static func leave() -> Waypoints_V1_ClientFrame {
        var frame = Waypoints_V1_ClientFrame()
        frame.leaveConvoy = Waypoints_V1_LeaveConvoy()
        return frame
    }

    static func homeZones(_ zones: [HomeZone]) -> Waypoints_V1_ClientFrame {
        var message = Waypoints_V1_SetHomeZones()
        message.zones = zones.map { zone in
            var z = Waypoints_V1_Zone()
            z.latE7 = e7(zone.center.latitude)
            z.lngE7 = e7(zone.center.longitude)
            z.radiusM = UInt32(clamping: zone.radiusMeters)
            return z
        }
        var frame = Waypoints_V1_ClientFrame()
        frame.homeZones = message
        return frame
    }

    // MARK: Server frames

    static func entity(_ u: Waypoints_V1_EntityUpdate) -> EntityUpdate {
        let tier: LocationTier = u.tier == .precise ? .precise : .approximate
        return EntityUpdate(
            uid: u.uid,
            coordinate: coordinate(lat: u.latE7, lng: u.lngE7),
            heading: u.headingDeg < 360 && tier == .precise ? Double(u.headingDeg) : nil,
            tier: tier,
            age: Double(u.ageDs) / 10,
            originMs: u.originMs == 0 ? nil : u.originMs,
            info: u.hasInfo ? info(u.info) : nil
        )
    }

    static func info(_ i: Waypoints_V1_EntityInfo) -> EntityInfo {
        let relation: Relation = switch i.relation {
        case .friend: .friend
        case .teammate: .teammate
        case .convoy: .convoy
        // Unknown relations get the most restrictive presentation.
        case .nearby, .unspecified, .UNRECOGNIZED: .nearby
        }
        let nearby = relation == .nearby
        return EntityInfo(relation: relation, markerIcon: i.markerIcon,
                          markerTrail: i.markerTrail.isEmpty ? nil : i.markerTrail, paintRGB: i.paintRgb,
                          displayName: nearby ? "" : i.displayName, carLabel: nearby ? "" : i.carLabel)
    }

    static func aggregate(_ a: Waypoints_V1_CellAggregate) -> CellAggregate {
        CellAggregate(h3: a.h3, count: Int(a.count))
    }

    static func convoy(_ c: Waypoints_V1_ConvoyState) -> ConvoyState {
        ConvoyState(
            id: ConvoyID(raw: c.convoyID),
            leaderUID: c.leaderUid,
            memberUIDs: c.memberUids,
            destination: c.hasDestination
                ? ConvoyDestination(coordinate: coordinate(lat: c.destination.latE7, lng: c.destination.lngE7),
                                    name: c.destination.name)
                : nil,
            routePolyline: c.routePolyline,
            regroup: c.hasRegroup
                ? ConvoyRegroup(coordinate: coordinate(lat: c.regroup.latE7, lng: c.regroup.lngE7),
                                setAt: date(ms: c.regroup.setMs))
                : nil,
            ended: c.ended
        )
    }

    static func mapEvent(_ e: Waypoints_V1_MapEvent) -> MapEvent? {
        let kind: MapEvent.Kind
        switch e.kind {
        case .report: kind = .report
        case .meet: kind = .meet
        case .help: kind = .help
        case .unspecified, .UNRECOGNIZED: return nil
        }
        let op: MapEvent.Op
        switch e.op {
        case .upsert: op = .upsert
        case .remove: op = .remove
        case .unspecified, .UNRECOGNIZED: return nil
        }
        return MapEvent(kind: kind, id: e.id, op: op, coordinate: coordinate(lat: e.latE7, lng: e.lngE7),
                        subtype: e.subtype, title: e.title)
    }
}

enum RealtimeProtocol {
    /// `Hello.protocol`. Bumped only with an incompatible change to `proto/waypoints/v1`.
    static let version: UInt32 = 1
    static let path = "/v1/rt"
}
