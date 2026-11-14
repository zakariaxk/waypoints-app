#if DEBUG
import Core
import Foundation

/// `-wp-smoke` (PRD 7.1): calls every repository and service method once against the
/// configured backend and prints `SMOKE PASS|FAIL|SKIP <method>` per method, then a summary.
/// Read it with `xcrun simctl launch --console booted app.waypoints.ios -wp-login <handle> -wp-smoke`.
///
/// Writes are made in pairs that undo each other (save then unsave, send then delete, create
/// then end), so the seed is left as it was. Methods that cannot be undone, or whose undo is
/// another method's job (deleting an account, voting in Showdown), print SKIP with the reason.
enum SmokeRunner {
    static func run(env: AppEnvironment) async {
        var s = Smoke()
        print("SMOKE start")
        guard let session = await env.auth.currentSession() else {
            print("SMOKE FAIL auth.currentSession (signed out: add -wp-login <handle>)")
            return
        }
        let me = session.userID
        let region = MapRegion(minLatitude: 39.6, minLongitude: -75.4, maxLatitude: 40.1, maxLongitude: -74.5)
        let here = Coordinate(latitude: 39.9387, longitude: -75.0230)

        // Auth
        await s.check("auth.currentSession") {}
        await s.check("auth.sessions") { _ = try await first(await env.auth.sessions()) }
        await s.check("auth.accessToken") { _ = try await env.auth.accessToken() }
        for name in ["signInWithApple", "sendEmailCode", "verifyEmailCode", "completeOnboarding", "signOut", "deleteAccount"] {
            s.skip("auth.\(name)", "changes the session")
        }

        // Profiles
        var myProfile: Profile?
        await s.check("profiles.myProfile") { myProfile = try await env.profiles.myProfile() }
        await s.check("profiles.profile(id)") { _ = try await env.profiles.profile(me) }
        await s.check("profiles.profile(handle)") {
            guard let handle = myProfile?.handle else { throw SmokeError.missing("my handle") }
            guard try await env.profiles.profile(handle: handle) != nil else { throw SmokeError.missing("profile by handle") }
        }
        await s.check("profiles.profiles") { _ = try await env.profiles.profiles([me]) }
        await s.check("profiles.profile(uid)") {
            guard let uid = myProfile?.uid else { throw SmokeError.missing("uid") }
            _ = try await env.profiles.profile(uid: uid)
        }
        await s.check("profiles.search") { _ = try await env.profiles.search("a", limit: 5) }
        await s.check("profiles.isHandleAvailable") { _ = try await env.profiles.isHandleAvailable("smoke_\(Int.random(in: 1000...9999))") }
        s.skip("profiles.updateMyProfile", "edits the seed profile")
        s.skip("profiles.acceptTerms", "covered by safety.acceptTerms")
        var privacy: PrivacySettings?
        await s.check("profiles.myPrivacySettings") { privacy = try await env.profiles.myPrivacySettings() }
        s.skip("profiles.registerDeviceToken", "needs an APNs token")
        s.skip("profiles.removeDeviceToken", "needs an APNs token")
        await s.check("profiles.notificationPrefs+setNotificationPrefs") {
            let prefs = try await env.profiles.notificationPrefs()
            try await env.profiles.setNotificationPrefs(prefs)
        }
        await s.check("profiles.myProfileChanges") { _ = await env.profiles.myProfileChanges() }

        // Garage
        var cars: [Car] = []
        await s.check("garage.cars") { cars = try await env.garage.cars(of: me) }
        let car = cars.first
        await s.check("garage.car") { _ = try await env.garage.car(try need(car).id) }
        await s.check("garage.reorderCars") { if !cars.isEmpty { try await env.garage.reorderCars(cars.map(\.id)) } }
        await s.check("garage.photos+reorderPhotos") {
            let id = try need(car).id
            let photos = try await env.garage.photos(of: id)
            if !photos.isEmpty { try await env.garage.reorderPhotos(of: id, photos.map(\.id)) }
        }
        await s.check("garage.buildEntries") { _ = try await env.garage.buildEntries(of: try need(car).id) }
        await s.check("garage.carChanges") { _ = await env.garage.carChanges(of: me) }
        for name in ["createCar", "updateCar", "deleteCar", "addPhoto", "removePhoto", "addBuildEntry", "updateBuildEntry", "deleteBuildEntry"] {
            s.skip("garage.\(name)", "edits the seed garage")
        }

        // Friends
        var friends: [Friend] = []
        await s.check("friends.friends") { friends = try await env.friends.friends() }
        await s.check("friends.incomingRequests") { _ = try await env.friends.incomingRequests() }
        await s.check("friends.outgoingRequests") { _ = try await env.friends.outgoingRequests() }
        await s.check("friends.friendship") { _ = try await env.friends.friendship(with: try need(friends.first).id) }
        await s.check("friends.friendChanges") { _ = await env.friends.friendChanges() }
        for name in ["sendRequest", "acceptRequest", "remove"] { s.skip("friends.\(name)", "edits the seed graph") }

        // Meets
        var meets: [Meet] = []
        await s.check("meets.meets") { meets = try await env.meets.meets(in: region) }
        let meet = meets.first
        await s.check("meets.meet") { _ = try await env.meets.meet(try need(meet).id) }
        await s.check("meets.upcomingMeets") { _ = try await env.meets.upcomingMeets(for: me) }
        await s.check("meets.rsvps") { _ = try await env.meets.rsvps(for: try need(meet).id) }
        await s.check("meets.myRSVP+setRSVP+clearRSVP") {
            let id = try need(meet).id
            let before = try await env.meets.myRSVP(for: id)
            try await env.meets.setRSVP(.maybe, for: id, car: car?.id)
            if let before {
                try await env.meets.setRSVP(before.status, for: id, car: before.carID)
            } else {
                try await env.meets.clearRSVP(for: id)
            }
        }
        await s.check("meets.venueNotes") { _ = try await env.meets.venueNotes(near: here, meters: 5000) }
        s.skip("meets.addVenueNote", "no delete")

        // Reports
        var reports: [Report] = []
        await s.check("reports.reports") { reports = try await env.reports.reports(in: region) }
        await s.check("reports.report") { _ = try await env.reports.report(try need(reports.first).id) }
        await s.check("reports.hazards") {
            _ = try await env.reports.hazards(along: [here, Coordinate(latitude: 39.89, longitude: -74.90)], bufferMeters: 50)
        }
        await s.check("reports.myVote") { _ = try await env.reports.myVote(on: try need(reports.first).id) }

        // Teams
        var teams: [Team] = []
        var channels: [Channel] = []
        await s.check("teams.myTeams") { teams = try await env.teams.myTeams() }
        let team = teams.first
        await s.check("teams.team") { _ = try await env.teams.team(try need(team).id) }
        await s.check("teams.publicTeams") { _ = try await env.teams.publicTeams(matching: nil) }
        await s.check("teams.members") { _ = try await env.teams.members(of: try need(team).id) }
        await s.check("teams.roles") { _ = try await env.teams.roles(of: try need(team).id) }
        await s.check("teams.myPermissions") { _ = try await env.teams.myPermissions(in: try need(team).id) }
        await s.check("teams.channels") { channels = try await env.teams.channels(of: try need(team).id) }
        await s.check("teams.channel") { _ = try await env.teams.channel(try need(channels.first).id) }
        await s.check("teams.meets") { _ = try await env.teams.meets(of: try need(team).id) }
        for name in ["createTeam", "updateTeam", "deleteTeam", "join", "joinPublic", "leave", "saveRole", "deleteRole",
                     "assign", "kick", "saveChannel", "deleteChannel"] {
            s.skip("teams.\(name)", "edits seed teams")
        }

        // Messages
        await s.check("messages.messages+send+markRead+delete") {
            let target = MessageTarget.channel(try need(channels.first).id)
            _ = try await env.messages.messages(in: target, before: nil, limit: 20)
            let sent = try await env.messages.send("Smoke test, ignore.", attachmentPath: nil, to: target)
            try await env.messages.markRead(target, upTo: sent.id)
            try await env.messages.delete(sent.id)
        }
        await s.check("messages.live") { _ = await env.messages.live(.channel(try need(channels.first).id)) }
        var threads: [MessageThread] = []
        await s.check("messages.threads") { threads = try await env.messages.threads() }
        await s.check("messages.openThread") {
            _ = try await env.messages.openThread(with: try need(friends.first).id, listing: nil)
        }
        await s.check("messages.unreadCount") { _ = try await first(await env.messages.unreadCount()) }
        await s.check("messages.unreadCounts") { _ = try await env.messages.unreadCounts(in: channels.map(\.id)) }
        _ = threads

        // Posts
        var posts: [Post] = []
        await s.check("posts.feed") { posts = try await env.posts.feed(after: nil, limit: 10).items }
        await s.check("posts.forYou") { _ = try await env.posts.forYou(after: nil, limit: 10) }
        await s.check("posts.followingFeed") { _ = try await env.posts.followingFeed(after: nil, limit: 10) }
        await s.check("posts.posts(by)") { _ = try await env.posts.posts(by: me) }
        await s.check("posts.post") { _ = try await env.posts.post(try need(posts.first).id) }
        await s.check("posts.like+unlike") {
            let id = try need(posts.first).id
            try await env.posts.like(id)
            try await env.posts.unlike(id)
        }
        await s.check("posts.comments+addComment+deleteComment") {
            let id = try need(posts.first).id
            _ = try await env.posts.comments(on: id)
            let c = try await env.posts.addComment("Smoke test, ignore.", to: id)
            try await env.posts.deleteComment(c.id)
        }
        await s.check("posts.isFollowing+follow+unfollow") {
            let other = try need(friends.first).id
            let was = try await env.posts.isFollowing(other)
            if was {
                try await env.posts.unfollow(other)
                try await env.posts.follow(other)
            } else {
                try await env.posts.follow(other)
                try await env.posts.unfollow(other)
            }
        }
        s.skip("posts.createPost", "needs an uploaded clip")
        s.skip("posts.deletePost", "pairs with createPost")

        // Showdown
        await s.check("showdown.entry") { _ = try await env.showdown.entry(for: try need(car).id) }
        await s.check("showdown.nextPair") { _ = try await env.showdown.nextPair(in: .street) }
        await s.check("showdown.rankings(week)") { _ = try await env.showdown.rankings(in: .street, period: .week, limit: 10) }
        await s.check("showdown.rankings(allTime)") { _ = try await env.showdown.rankings(in: .street, period: .allTime, limit: 10) }
        for name in ["enter", "withdraw", "vote"] { s.skip("showdown.\(name)", "changes ratings") }

        // Market
        var listings: [Listing] = []
        await s.check("market.listings") { listings = try await env.market.listings(ListingFilter(), after: nil, limit: 10).items }
        await s.check("market.listing") { _ = try await env.market.listing(try need(listings.first).id) }
        await s.check("market.listings(by)") { _ = try await env.market.listings(by: me) }
        await s.check("market.save+savedListings+unsave") {
            let id = try need(listings.first).id
            try await env.market.save(id)
            _ = try await env.market.savedListings()
            try await env.market.unsave(id)
        }
        for name in ["createListing", "updateListing", "setStatus"] { s.skip("market.\(name)", "edits seed listings") }

        // Spots, roads, progress, activity
        await s.check("spots.spots") { _ = try await env.spots.spots(by: me) }
        s.skip("spots.addSpot", "needs a photo")
        s.skip("spots.deleteSpot", "pairs with addSpot")
        var roads: [Road] = []
        await s.check("roads.roads") { roads = try await env.roads.roads(in: region) }
        await s.check("roads.road") { _ = try await env.roads.road(try need(roads.first).id) }
        await s.check("roads.roads(by)") { _ = try await env.roads.roads(by: me) }
        await s.check("roads.myRating") { _ = try await env.roads.myRating(for: try need(roads.first).id) }
        s.skip("roads.createRoad", "no delete")
        s.skip("roads.rate", "no undo")
        await s.check("progress.achievements") { _ = try await env.progress.achievements(of: me) }
        await s.check("progress.myProgress") { _ = try await env.progress.myProgress() }
        await s.check("progress.raceResults(for)") { _ = try await env.progress.raceResults(for: try need(car).id) }
        await s.check("progress.bestRaceResults") { _ = try await env.progress.bestRaceResults(limit: 5) }
        await s.check("progress.raceResults(by)") { _ = try await env.progress.raceResults(by: me, limit: 5) }
        s.skip("progress.saveRaceResult", "no delete")
        await s.check("activity.recent") { _ = try await env.activity.recent(limit: 20) }
        await s.check("activity.unreadCount") { _ = try await first(await env.activity.unreadCount()) }
        await s.check("activity.markAllRead") { try await env.activity.markAllRead() }

        // Media
        await s.check("media.upload+publicURL+delete") {
            let stored = try await env.media.upload(Data("smoke".utf8), contentType: "image/jpeg", to: .avatars) { _ in }
            _ = env.media.publicURL(bucket: stored.bucket, path: stored.path)
            try await env.media.delete(stored)
        }

        // Safety
        await s.check("safety.blockedUsers") { _ = try await env.safety.blockedUsers() }
        await s.check("safety.blockedChanges") { _ = await env.safety.blockedChanges() }
        await s.check("safety.check") { _ = await env.safety.check("See you at the meet") }
        await s.check("safety.needsTermsAcceptance") { _ = await env.safety.needsTermsAcceptance() }
        await s.check("safety.acceptTerms") { try await env.safety.acceptTerms() }
        for name in ["report", "block", "unblock"] { s.skip("safety.\(name)", "feeds moderation") }

        // Catalog
        var makes: [CatalogMake] = []
        var models: [CatalogModel] = []
        var years: [Int] = []
        var variants: [CatalogVariant] = []
        await s.check("catalog.search") { _ = try await env.catalog.search("civic", limit: 5) }
        await s.check("catalog.popularMakes") { _ = try await env.catalog.popularMakes() }
        await s.check("catalog.makes") { makes = try await env.catalog.makes() }
        await s.check("catalog.models") { models = try await env.catalog.models(of: try need(makes.first).id) }
        await s.check("catalog.years") { years = try await env.catalog.years(of: try need(models.first).id) }
        await s.check("catalog.variants") { variants = try await env.catalog.variants(of: try need(models.first).id, year: try need(years.first)) }
        await s.check("catalog.variant") { _ = try await env.catalog.variant(try need(variants.first).id) }
        await s.check("catalog.decodeVIN") { _ = try await env.catalog.decodeVIN("JHMAP11496T000001") }

        // Gateway
        await s.check("gateway.updatePrivacy") { try await env.gateway.updatePrivacy(try need(privacy)) }
        await s.check("gateway.postReport+voteReport+undoReport") {
            let r = try await env.gateway.postReport(kind: .pothole, at: here, note: "Smoke test")
            do { try await env.gateway.voteReport(r.id, stillThere: true) } catch WaypointsError.forbidden {}
            try await env.gateway.undoReport(r.id)
        }
        await s.check("gateway.helpRequests") { _ = try await env.gateway.helpRequests(in: region) }
        await s.check("gateway.postHelp+helpRequest+extendHelp+endHelp") {
            let h = try await env.gateway.postHelp(HelpDraft(kind: .other, coordinate: here, note: "Smoke test"))
            _ = try await env.gateway.helpRequest(h.id)
            _ = try await env.gateway.extendHelp(h.id)
            try await env.gateway.endHelp(h.id)
        }
        s.skip("gateway.respondToHelp", "needs another person's request")
        s.skip("gateway.createMeet", "3 per day limit; no delete")
        s.skip("gateway.updateMeet", "pairs with createMeet")
        s.skip("gateway.cancelMeet", "pairs with createMeet")
        s.skip("gateway.cancelMeetAndFollowing", "pairs with createMeet")
        await s.check("gateway.createConvoy+joinConvoy+setConvoyDestination+setConvoyRegroup+endConvoy") {
            let invite = try await env.gateway.createConvoy(name: "Smoke", destination: nil)
            _ = try await env.gateway.joinConvoy(code: invite.joinCode)
            try await env.gateway.setConvoyDestination(invite.id, ConvoyDestination(coordinate: here, name: "Cherry Hill Mall"))
            try await env.gateway.setConvoyRegroup(invite.id, at: here)
            try await env.gateway.endConvoy(invite.id)
        }
        s.skip("gateway.inviteToConvoy", "sends a push")
        await s.check("gateway.voiceToken(channel)") { _ = try await env.gateway.voiceToken(for: try need(channels.first).id) }
        s.skip("gateway.voiceToken(convoy)", "needs a live convoy")

        // Realtime
        await s.check("realtime.connectionState") { _ = try await first(await env.realtime.connectionState(), seconds: 5) }
        await s.check("realtime.events+setViewport") {
            _ = await env.realtime.events()
            await env.realtime.setViewport(region)
        }

        print("SMOKE done: \(s.passed) PASS, \(s.failed) FAIL, \(s.skipped) SKIP")
    }

    /// The first element of a stream, or a timeout.
    static func first<T: Sendable>(_ stream: AsyncStream<T>, seconds: Double = 3) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                for await value in stream { return value }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() ?? nil else { throw SmokeError.missing("stream value") }
            return value
        }
    }

    static func need<T>(_ value: T?) throws -> T {
        guard let value else { throw SmokeError.missing("seed data for this call (\(T.self))") }
        return value
    }
}

private enum SmokeError: Error, CustomStringConvertible {
    case missing(String)
    var description: String {
        switch self {
        case .missing(let what): "missing \(what)"
        }
    }
}

private struct Smoke {
    var passed = 0, failed = 0, skipped = 0

    mutating func check(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            passed += 1
            print("SMOKE PASS \(name)")
        } catch {
            failed += 1
            print("SMOKE FAIL \(name): \(error)")
        }
    }

    mutating func skip(_ name: String, _ reason: String) {
        skipped += 1
        print("SMOKE SKIP \(name) (\(reason))")
    }
}
#endif
