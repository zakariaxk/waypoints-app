import Foundation

extension PreviewStore: TeamRepository {
    func withCount(_ team: Team) -> Team {
        var t = team
        t.memberCount = members.filter { $0.teamID == team.id }.count
        return t
    }
    func isMember(_ team: TeamID, _ user: UserID) -> Bool {
        members.contains { $0.teamID == team && $0.userID == user }
    }
    func permissions(in team: TeamID, for user: UserID) -> TeamPermissions {
        if teams[team]?.ownerID == user { return .all }
        guard let member = members.first(where: { $0.teamID == team && $0.userID == user }),
              let role = roles.first(where: { $0.id == member.roleID }) else { return [] }
        return role.permissions
    }
    func require(_ permission: TeamPermissions, in team: TeamID) throws {
        guard permissions(in: team, for: try me()).contains(permission) else { throw WaypointsError.forbidden }
    }

    public func myTeams() async throws -> [Team] {
        let me = try me()
        return teams.values.filter { isMember($0.id, me) }.map(withCount).sorted { $0.name < $1.name }
    }
    public func team(_ id: TeamID) async throws -> Team {
        let me = try me()
        guard let team = teams[id], team.isPublic || isMember(id, me) else { throw WaypointsError.notFound }
        return withCount(team)
    }
    public func publicTeams(matching query: String?) async throws -> [Team] {
        let q = query?.lowercased() ?? ""
        return teams.values
            .filter { $0.isPublic && (q.isEmpty || $0.name.lowercased().contains(q) || $0.tag.lowercased().contains(q)) }
            .map(withCount).sorted { $0.memberCount > $1.memberCount }
    }
    public func createTeam(_ draft: TeamDraft) async throws -> Team {
        let me = try me()
        guard !teams.values.contains(where: { $0.tag == draft.tag }) else { throw WaypointsError.conflict("tag") }
        let team = Team(ownerID: me, name: draft.name, tag: draft.tag, about: draft.about, iconPath: draft.iconPath,
                        isPublic: draft.isPublic, inviteCode: String(UUID().uuidString.prefix(6)))
        teams[team.id] = team
        let owner = TeamRole(teamID: team.id, name: "Owner", rank: 0, permissions: .all)
        roles += [owner, TeamRole(teamID: team.id, name: "Member", rank: 1, permissions: [])]
        members.append(TeamMember(teamID: team.id, userID: me, roleID: owner.id))
        for (i, (name, kind)) in [("general", ChannelKind.text), ("Garage", .voice)].enumerated() {
            let channel = Channel(teamID: team.id, name: name, kind: kind, sort: i)
            channels[channel.id] = channel
        }
        return team
    }
    public func updateTeam(_ team: Team) async throws -> Team {
        try require(.manageTeam, in: team.id)
        teams[team.id] = team
        return team
    }
    public func deleteTeam(_ id: TeamID) async throws {
        let me = try me()
        guard teams[id]?.ownerID == me else { throw WaypointsError.forbidden }
        teams[id] = nil
        members.removeAll { $0.teamID == id }
        channels = channels.filter { $0.value.teamID != id }
    }
    public func join(code: String) async throws -> Team {
        let me = try me()
        guard let team = teams.values.first(where: { $0.inviteCode?.uppercased() == code.uppercased() }) else {
            throw WaypointsError.notFound
        }
        if !isMember(team.id, me) { members.append(TeamMember(teamID: team.id, userID: me)) }
        return withCount(team)
    }
    public func joinPublic(_ id: TeamID) async throws {
        let me = try me()
        guard teams[id]?.isPublic == true else { throw WaypointsError.forbidden }
        if !isMember(id, me) { members.append(TeamMember(teamID: id, userID: me)) }
    }
    public func leave(_ id: TeamID) async throws {
        let me = try me()
        members.removeAll { $0.teamID == id && $0.userID == me }
    }
    public func members(of team: TeamID) async throws -> [TeamMember] { members.filter { $0.teamID == team } }
    public func roles(of team: TeamID) async throws -> [TeamRole] {
        roles.filter { $0.teamID == team }.sorted { $0.rank < $1.rank }
    }
    public func saveRole(_ role: TeamRole) async throws -> TeamRole {
        try require(.manageRoles, in: role.teamID)
        roles.removeAll { $0.id == role.id }
        roles.append(role)
        return role
    }
    public func deleteRole(_ id: TeamRoleID) async throws {
        guard let role = roles.first(where: { $0.id == id }) else { return }
        try require(.manageRoles, in: role.teamID)
        roles.removeAll { $0.id == id }
    }
    public func assign(_ role: TeamRoleID?, to user: UserID, in team: TeamID) async throws {
        try require(.manageRoles, in: team)
        if let i = members.firstIndex(where: { $0.teamID == team && $0.userID == user }) { members[i].roleID = role }
    }
    public func kick(_ user: UserID, from team: TeamID) async throws {
        try require(.kick, in: team)
        members.removeAll { $0.teamID == team && $0.userID == user }
    }
    public func myPermissions(in team: TeamID) async throws -> TeamPermissions { permissions(in: team, for: try me()) }
    public func channels(of team: TeamID) async throws -> [Channel] {
        channels.values.filter { $0.teamID == team }.sorted { $0.sort < $1.sort }
    }
    public func channel(_ id: ChannelID) async throws -> Channel {
        guard let channel = channels[id] else { throw WaypointsError.notFound }
        return channel
    }
    public func saveChannel(_ channel: Channel) async throws -> Channel {
        try require(.manageChannels, in: channel.teamID)
        channels[channel.id] = channel
        return channel
    }
    public func deleteChannel(_ id: ChannelID) async throws {
        guard let channel = channels[id] else { return }
        try require(.manageChannels, in: channel.teamID)
        channels[id] = nil
    }
}

extension PreviewStore: MessageRepository {
    public func messages(in target: MessageTarget, before: MessageID?, limit: Int) async throws -> [Message] {
        guard canRead(target, as: try me()) else { throw WaypointsError.forbidden }
        return Array(messages
            .filter { message in
                message.target == target && (before.map { message.id < $0 } ?? true) && visible(message.authorID)
            }
            .sorted { $0.id > $1.id }
            .prefix(limit))
    }
    public func send(_ body: String, attachmentPath: String?, to target: MessageTarget) async throws -> Message {
        let me = try me()
        guard canRead(target, as: me) else { throw WaypointsError.forbidden }
        let message = Message(id: MessageID(raw: (messages.map(\.id.raw).max() ?? 0) + 1), target: target,
                              authorID: me, body: body, attachmentPath: attachmentPath)
        messages.append(message)
        readMarkers[target] = message.id
        messageBroadcasts[target]?.send(message)
        return message
    }
    public func delete(_ id: MessageID) async throws {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].deletedAt = .now
        messageBroadcasts[messages[i].target]?.send(messages[i])
    }
    public func live(_ target: MessageTarget) async -> AsyncStream<Message> {
        messageBroadcasts[target, default: Broadcast()].subscribe()
    }
    public func threads() async throws -> [MessageThread] {
        let me = try me()
        return threads.values.filter { $0.aID == me || $0.bID == me }.map { thread in
            var t = thread
            let target = MessageTarget.thread(thread.id)
            t.lastMessage = messages.filter { $0.target == target }.max { $0.id < $1.id }
            t.unreadCount = messages.filter {
                $0.target == target && $0.authorID != me && $0.id > (readMarkers[target] ?? MessageID(raw: 0))
            }.count
            return t
        }.sorted { ($0.lastMessage?.id.raw ?? 0) > ($1.lastMessage?.id.raw ?? 0) }
    }
    public func openThread(with user: UserID, listing: ListingID?) async throws -> MessageThread {
        let me = try me()
        guard !isBlockedEitherWay(me, user) else { throw WaypointsError.forbidden }
        if let existing = threads.values.first(where: {
            Set([$0.aID, $0.bID]) == Set([me, user]) && $0.listingID == listing
        }) { return existing }
        let thread = MessageThread(kind: listing == nil ? .dm : .listing, listingID: listing, aID: me, bID: user)
        threads[thread.id] = thread
        return thread
    }
    public func markRead(_ target: MessageTarget, upTo id: MessageID) async throws {
        readMarkers[target] = max(readMarkers[target] ?? id, id)
        unreadBroadcast.send(unreadTotal())
    }
    public func unreadCount() async -> AsyncStream<Int> { unreadBroadcast.subscribe(initial: unreadTotal()) }
}

extension PreviewStore: PostRepository {
    func decorated(_ post: Post) -> Post {
        var p = post
        if let me = session?.userID { p.likedByMe = likes.contains(Pair(post.id.raw, me.raw)) }
        return p
    }
    public func feed(after cursor: PageCursor?, limit: Int) async throws -> Page<Post> {
        let all = posts.values.filter { visible($0.authorID) }.sorted { $0.createdAt > $1.createdAt }
        let start = cursor.flatMap { Int($0.raw) } ?? 0
        let page = all.dropFirst(start).prefix(limit).map(decorated)
        let next = start + page.count < all.count ? PageCursor(raw: String(start + page.count)) : nil
        return Page(items: Array(page), next: next)
    }
    public func posts(by author: UserID) async throws -> [Post] {
        posts.values.filter { $0.authorID == author && visible(author) }.sorted { $0.createdAt > $1.createdAt }
            .map(decorated)
    }
    public func post(_ id: PostID) async throws -> Post {
        guard let post = posts[id], visible(post.authorID) else { throw WaypointsError.notFound }
        return decorated(post)
    }
    public func createPost(_ new: NewPost) async throws -> Post {
        let post = Post(authorID: try me(), carID: new.carID, videoPath: new.videoPath, posterPath: new.posterPath,
                        caption: new.caption, durationMs: new.durationMs)
        posts[post.id] = post
        return post
    }
    public func deletePost(_ id: PostID) async throws {
        let me = try me()
        guard posts[id]?.authorID == me else { throw WaypointsError.forbidden }
        posts[id] = nil
    }
    public func like(_ id: PostID) async throws {
        if likes.insert(Pair(id.raw, try me().raw)).inserted { posts[id]?.likeCount += 1 }
    }
    public func unlike(_ id: PostID) async throws {
        if likes.remove(Pair(id.raw, try me().raw)) != nil { posts[id]?.likeCount -= 1 }
    }
    public func comments(on post: PostID) async throws -> [PostComment] {
        comments.filter { $0.postID == post && visible($0.authorID) }.sorted { $0.createdAt < $1.createdAt }
    }
    public func addComment(_ body: String, to post: PostID) async throws -> PostComment {
        let comment = PostComment(postID: post, authorID: try me(), body: body)
        comments.append(comment)
        posts[post]?.commentCount += 1
        return comment
    }
    public func deleteComment(_ id: CommentID) async throws {
        guard let comment = comments.first(where: { $0.id == id }) else { return }
        comments.removeAll { $0.id == id }
        posts[comment.postID]?.commentCount -= 1
    }
    public func follow(_ user: UserID) async throws { follows.insert(Pair(try me().raw, user.raw)) }
    public func unfollow(_ user: UserID) async throws { follows.remove(Pair(try me().raw, user.raw)) }
    public func isFollowing(_ user: UserID) async throws -> Bool { follows.contains(Pair(try me().raw, user.raw)) }
}

extension PreviewStore: ShowdownRepository {
    func contender(_ entry: ShowdownEntry) -> ShowdownContender? {
        guard let car = cars[entry.carID], let owner = profiles[car.ownerID], visible(owner.userID) else { return nil }
        return ShowdownContender(car: car, owner: owner, photos: carPhotos.filter { $0.carID == car.id }, entry: entry)
    }
    public func entry(for car: CarID) async throws -> ShowdownEntry? { showdown[car] }
    public func enter(_ car: CarID, class showdownClass: ShowdownClass) async throws -> ShowdownEntry {
        let me = try me()
        guard cars[car]?.ownerID == me else { throw WaypointsError.forbidden }
        guard carPhotos.contains(where: { $0.carID == car }) else { throw WaypointsError.invalid("photo") }
        let entry = showdown[car] ?? ShowdownEntry(carID: car, showdownClass: showdownClass)
        showdown[car] = entry
        return entry
    }
    public func withdraw(_ car: CarID) async throws { showdown[car] = nil }
    public func nextPair(in showdownClass: ShowdownClass) async throws -> ShowdownPair? {
        let me = try me()
        let pool = showdown.values.filter { $0.showdownClass == showdownClass && cars[$0.carID]?.ownerID != me }
            .compactMap(contender).shuffled()
        for (i, a) in pool.enumerated() {
            for b in pool.dropFirst(i + 1) where !showdownVotes.contains(votePair(me, a.car.id, b.car.id)) {
                return ShowdownPair(left: a, right: b)
            }
        }
        return nil
    }
    /// Unordered pair per voter, like the `showdown_votes` primary key.
    func votePair(_ voter: UserID, _ x: CarID, _ y: CarID) -> [UUID] {
        [voter.raw] + [x.raw, y.raw].sorted { $0.uuidString < $1.uuidString }
    }
    public func vote(winner: CarID, loser: CarID) async throws {
        let me = try me()
        guard cars[winner]?.ownerID != me, cars[loser]?.ownerID != me else { throw WaypointsError.forbidden }
        guard showdownVotes.insert(votePair(me, winner, loser)).inserted,
              var w = showdown[winner], var l = showdown[loser] else { throw WaypointsError.conflict("vote") }
        let expected = 1 / (1 + pow(10, Double(l.rating - w.rating) / 400))
        let delta = Int((24 * (1 - expected)).rounded())
        w.rating += delta; w.wins += 1
        l.rating -= delta; l.losses += 1
        showdown[winner] = w; showdown[loser] = l
    }
    public func rankings(in showdownClass: ShowdownClass, period: RankingPeriod, limit: Int) async throws -> [ShowdownContender] {
        Array(showdown.values.filter { $0.showdownClass == showdownClass }.sorted { $0.rating > $1.rating }
            .compactMap(contender).prefix(limit))
    }
}

extension PreviewStore: MarketRepository {
    func decorated(_ listing: Listing) -> Listing {
        var l = listing
        if let me = session?.userID { l.savedByMe = saves.contains(Pair(listing.id.raw, me.raw)) }
        return l
    }
    func matches(_ listing: Listing, _ filter: ListingFilter) -> Bool {
        if let kind = filter.kind, listing.kind != kind { return false }
        if let q = filter.query?.lowercased(), !q.isEmpty,
           !listing.title.lowercased().contains(q), !listing.description.lowercased().contains(q) { return false }
        if let want = filter.fits {
            guard let fits = listing.fits, fits.make == want.make else { return false }
            if let model = want.model, let m = fits.model, model != m { return false }
            if let year = want.yearFrom, let to = fits.yearTo, year > to { return false }
            if let year = want.yearTo, let from = fits.yearFrom, year < from { return false }
        }
        return true
    }
    public func listings(_ filter: ListingFilter, after cursor: PageCursor?, limit: Int) async throws -> Page<Listing> {
        let all = listings.values.filter { $0.status == .active && visible($0.sellerID) && matches($0, filter) }
            .sorted { $0.createdAt > $1.createdAt }
        let start = cursor.flatMap { Int($0.raw) } ?? 0
        let page = all.dropFirst(start).prefix(limit).map(decorated)
        return Page(items: Array(page),
                    next: start + page.count < all.count ? PageCursor(raw: String(start + page.count)) : nil)
    }
    public func listing(_ id: ListingID) async throws -> Listing {
        guard let listing = listings[id], visible(listing.sellerID) else { throw WaypointsError.notFound }
        return decorated(listing)
    }
    public func listings(by seller: UserID) async throws -> [Listing] {
        listings.values.filter { $0.sellerID == seller }.sorted { $0.createdAt > $1.createdAt }.map(decorated)
    }
    public func createListing(_ draft: ListingDraft) async throws -> Listing {
        let listing = Listing(sellerID: try me(), kind: draft.kind, title: draft.title, priceCents: draft.priceCents,
                              condition: draft.condition, description: draft.description, fits: draft.fits,
                              carID: draft.carID, region: draft.region,
                              photos: draft.photoPaths.enumerated().map { ListingPhoto(path: $0.element, sort: $0.offset) })
        listings[listing.id] = listing
        return listing
    }
    public func updateListing(_ listing: Listing) async throws -> Listing {
        let me = try me()
        guard listings[listing.id]?.sellerID == me else { throw WaypointsError.forbidden }
        listings[listing.id] = listing
        return listing
    }
    public func setStatus(_ status: ListingStatus, for id: ListingID) async throws {
        let me = try me()
        guard listings[id]?.sellerID == me else { throw WaypointsError.forbidden }
        listings[id]?.status = status
    }
    public func save(_ id: ListingID) async throws { saves.insert(Pair(id.raw, try me().raw)) }
    public func unsave(_ id: ListingID) async throws { saves.remove(Pair(id.raw, try me().raw)) }
    public func savedListings() async throws -> [Listing] {
        let me = try me()
        return listings.values.filter { saves.contains(Pair($0.id.raw, me.raw)) }.map(decorated)
    }
}
