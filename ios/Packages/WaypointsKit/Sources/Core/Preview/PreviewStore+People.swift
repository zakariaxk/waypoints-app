import Foundation

extension PreviewStore: AuthService {
    public func sessions() async -> AsyncStream<AuthSession?> { sessionBroadcast.subscribe(initial: .some(session)) }
    public func currentSession() async -> AuthSession? { session }
    public func accessToken() async throws -> String { _ = try me(); return session?.accessToken ?? "" }

    public func signInWithApple(idToken: String, nonce: String) async throws -> AuthSession {
        let new = PreviewStore.makeSession(for: PreviewSeed.me, needsOnboarding: false)
        setSession(new)
        return new
    }
    public func sendEmailCode(to email: String) async throws {
        guard email.contains("@") else { throw WaypointsError.invalid("email") }
    }
    /// Any six digits sign in as the seed user, except "000000", which is treated as wrong.
    public func verifyEmailCode(_ code: String, email: String) async throws -> AuthSession {
        guard code.count == 6, code.allSatisfy(\.isNumber), code != "000000" else { throw WaypointsError.invalid("code") }
        let new = PreviewStore.makeSession(for: PreviewSeed.me, needsOnboarding: false)
        setSession(new)
        return new
    }
    public func completeOnboarding() async throws {
        guard var current = session else { throw WaypointsError.notSignedIn }
        current.needsOnboarding = false
        setSession(current)
    }
    public func signOut() async throws { setSession(nil) }
    public func deleteAccount() async throws {
        let me = try me()
        profiles[me] = nil
        cars = cars.filter { $0.value.ownerID != me }
        friendships.removeAll { $0.requesterID == me || $0.addresseeID == me }
        setSession(nil)
    }
}

extension PreviewStore: ProfileRepository {
    public func myProfile() async throws -> Profile {
        guard let profile = profiles[try me()] else { throw WaypointsError.notFound }
        return profile
    }
    public func profile(_ id: UserID) async throws -> Profile {
        guard let profile = profiles[id], visible(id) else { throw WaypointsError.notFound }
        return profile
    }
    public func profile(handle: String) async throws -> Profile? {
        profiles.values.first { $0.handle == handle.lowercased() && visible($0.userID) }
    }
    public func profiles(_ ids: [UserID]) async throws -> [Profile] {
        ids.compactMap { profiles[$0] }.filter { visible($0.userID) }
    }
    public func profile(uid: RealtimeUID) async throws -> Profile? {
        profiles.values.first { $0.uid == uid && visible($0.userID) }
    }
    public func search(_ query: String, limit: Int) async throws -> [Profile] {
        let q = query.lowercased()
        return profiles.values
            .filter { visible($0.userID) && ($0.handle.contains(q) || $0.displayName.lowercased().contains(q)) }
            .sorted { $0.handle < $1.handle }
            .prefix(limit).map { $0 }
    }
    public func isHandleAvailable(_ handle: String) async throws -> Bool {
        let mine = session.flatMap { profiles[$0.userID]?.handle }
        return Profile.isValidHandle(handle) && (handle == mine || !profiles.values.contains { $0.handle == handle })
    }
    public func updateMyProfile(_ update: ProfileUpdate) async throws -> Profile {
        var profile = try await myProfile()
        if let handle = update.handle {
            guard try await isHandleAvailable(handle) else { throw WaypointsError.conflict("handle") }
            profile.handle = handle
        }
        if let v = update.displayName { profile.displayName = v }
        if let v = update.bio { profile.bio = v }
        if let v = update.avatarPath { profile.avatarPath = v }
        if let v = update.homeRegion { profile.homeRegion = v }
        if let v = update.markerIcon { profile.markerIcon = v }
        if let v = update.markerTrail { profile.markerTrail = v }
        if let v = update.primaryCarID { profile.primaryCarID = v }
        if let v = update.birthYear { profile.birthYear = v }
        profileChanged(profile)
        return profile
    }
    public func acceptTerms() async throws {
        var profile = try await myProfile()
        profile.acceptedTermsAt = .now
        termsAccepted = true
        profileChanged(profile)
    }
    public func myPrivacySettings() async throws -> PrivacySettings { privacy[try me()] ?? .defaults }
    public func registerDeviceToken(_ apnsToken: String, environment: APNsEnvironment) async throws {
        deviceTokens[try me(), default: []].insert(apnsToken)
    }
    public func removeDeviceToken(_ apnsToken: String) async throws {
        deviceTokens[try me()]?.remove(apnsToken)
    }
    public func myProfileChanges() async -> AsyncStream<Profile> {
        profileBroadcast.subscribe(initial: session.flatMap { profiles[$0.userID] })
    }
}

extension PreviewStore: FriendRepository {
    public func friends() async throws -> [Friend] { _ = try me(); return friendList() }

    private func requests(incoming: Bool) throws -> [FriendRequest] {
        let me = try me()
        return friendships
            .filter { $0.status == .pending && (incoming ? $0.addresseeID == me : $0.requesterID == me) }
            .compactMap { f in profiles[f.other(than: me)].map { FriendRequest(profile: $0, sentAt: f.createdAt) } }
    }
    public func incomingRequests() async throws -> [FriendRequest] { try requests(incoming: true) }
    public func outgoingRequests() async throws -> [FriendRequest] { try requests(incoming: false) }
    public func friendship(with user: UserID) async throws -> Friendship? {
        let me = try me()
        return friendships.first { Set([$0.requesterID, $0.addresseeID]) == Set([me, user]) }
    }
    public func sendRequest(to user: UserID) async throws {
        let me = try me()
        guard me != user, try await friendship(with: user) == nil, !isBlockedEitherWay(me, user) else { return }
        friendships.append(Friendship(requesterID: me, addresseeID: user, status: .pending))
    }
    public func acceptRequest(from user: UserID) async throws {
        let me = try me()
        guard let index = friendships.firstIndex(where: {
            $0.requesterID == user && $0.addresseeID == me && $0.status == .pending
        }) else { throw WaypointsError.notFound }
        friendships[index].status = .accepted
        friendBroadcast.send(friendList())
    }
    public func remove(_ user: UserID) async throws {
        let me = try me()
        friendships.removeAll { Set([$0.requesterID, $0.addresseeID]) == Set([me, user]) }
        friendBroadcast.send(friendList())
    }
    public func friendChanges() async -> AsyncStream<[Friend]> { friendBroadcast.subscribe(initial: friendList()) }
}

extension PreviewStore: SafetyService {
    public func report(_ target: ContentRef, reason: ContentReportReason, note: String?) async throws {
        _ = try me()
    }
    public func block(_ user: UserID) async throws {
        let me = try me()
        blocks.insert(Pair(me.raw, user.raw))
        friendships.removeAll { Set([$0.requesterID, $0.addresseeID]) == Set([me, user]) }
        blockedBroadcast.send(blockedSet())
        friendBroadcast.send(friendList())
    }
    public func unblock(_ user: UserID) async throws {
        blocks.remove(Pair(try me().raw, user.raw))
        blockedBroadcast.send(blockedSet())
    }
    public func blockedUsers() async throws -> [Profile] {
        blockedSet().compactMap { profiles[$0] }.sorted { $0.handle < $1.handle }
    }
    public func blockedChanges() async -> AsyncStream<Set<UserID>> { blockedBroadcast.subscribe(initial: blockedSet()) }
    public func check(_ text: String) async -> TextCheck { .ok }
    public func needsTermsAcceptance() async -> Bool { !termsAccepted }

    private func blockedSet() -> Set<UserID> {
        guard let me = session?.userID else { return [] }
        return Set(blocks.filter { $0.a == me.raw }.map { UserID(raw: $0.b) })
    }
}
