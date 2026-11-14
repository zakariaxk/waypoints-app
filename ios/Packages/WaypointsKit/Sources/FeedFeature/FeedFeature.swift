import AVFoundation
import Combine
import Core
import DesignSystem
import PhotosUI
import SwiftUI

/// The Feed tab (plan 10.5 F1–F3), extra modes from `FeedMode` providers (Showdown), route `post`.
public enum FeedFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        let uploader = Uploader(env: env)
        registry.registerTab(.feed) { AnyView(FeedHome(env: env, registry: registry, uploader: uploader)) }
        registry.registerRoute(.post) { route in
            guard case let .post(id) = route else { return nil }
            return AnyView(SinglePost(env: env, postID: id))
        }
    }
}

// MARK: Players

/// Three players at most, reused as the pager moves (plan W4-4).
@MainActor
final class PlayerPool {
    private var players: [Int: AVPlayer] = [:]
    private var looper: [Int: NSObjectProtocol] = [:]
    /// Unmuting once holds for the rest of the session, across modes and pools (FEED-1).
    private static var sessionMuted = true
    var muted = true {
        didSet { PlayerPool.sessionMuted = muted; players.values.forEach { $0.isMuted = muted } }
    }

    init() { muted = PlayerPool.sessionMuted }

    func player(for index: Int, url: URL) -> AVPlayer {
        if let p = players[index] { return p }
        for key in players.keys where abs(key - index) > 1 {
            players[key]?.pause()
            players[key] = nil
            if let o = looper[key] { NotificationCenter.default.removeObserver(o) }
            looper[key] = nil
        }
        let item = Self.item(url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = muted
        loop(index, item: item, player: p)
        players[index] = p
        return p
    }

    /// FEED-8: "Try again" loads the video afresh into the same player.
    func retry(_ index: Int, url: URL) {
        guard let p = players[index] else { return }
        if let o = looper[index] { NotificationCenter.default.removeObserver(o) }
        let item = Self.item(url)
        p.replaceCurrentItem(with: item)
        loop(index, item: item, player: p)
        p.play()
    }

    private static func item(_ url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 2
        return item
    }

    private func loop(_ index: Int, item: AVPlayerItem, player p: AVPlayer) {
        looper[index] = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            MainActor.assumeIsolated { p.seek(to: .zero); p.play() }
        }
    }

    func play(_ index: Int) {
        for (k, p) in players { if k == index { p.play() } else { p.pause() } }
    }

    func pauseAll() { players.values.forEach { $0.pause() } }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.videoGravity = .resizeAspectFill
        v.playerLayer.player = player
        return v
    }
    func updateUIView(_ v: LayerView, context: Context) { v.playerLayer.player = player }
}

// MARK: Copy

enum FeedCopy {
    /// SAFE-9: shown when the server refuses with `rateLimited`.
    static let rateLimited = "You're doing that a lot. Try again in a few minutes."
}

// MARK: F1

@MainActor
@Observable
final class FeedModel {
    let env: AppEnvironment
    var posts: [Post] = []
    var authors: [UserID: Profile] = [:]
    var following: [UserID: Bool] = [:]
    var cars: [CarID: Car] = [:]
    var meets: [MeetID: Meet] = [:]
    var next: PageCursor?
    var loading = false
    var failed = false
    var offline = false
    var exhausted = false
    var me: UserID?
    /// Following reads `follows`; For you reads `feed_for_you` (FEED-2).
    let followingOnly: Bool

    init(env: AppEnvironment, followingOnly: Bool = false) { self.env = env; self.followingOnly = followingOnly }

    func refresh() async {
        guard !loading else { return }
        next = nil
        exhausted = false
        await load(replacing: true)
    }

    func more() async {
        guard !loading, !exhausted else { return }
        await load(replacing: false)
    }

    private func load(replacing: Bool) async {
        loading = true
        me = await env.auth.currentSession()?.userID
        do {
            let page: Page<Post>
            if followingOnly {
                page = try await env.posts.followingFeed(after: next, limit: 10)
            } else {
                page = try await env.posts.forYou(after: next, limit: 10)
            }
            if replacing { posts = [] }
            let seen = Set(posts.map(\.id))
            posts += page.items.filter { !seen.contains($0.id) }
            next = page.next
            exhausted = page.next == nil
            failed = false
            offline = false
            let missing = Set(page.items.map(\.authorID)).filter { authors[$0] == nil }
            for p in (try? await env.profiles.profiles(Array(missing))) ?? [] { authors[p.userID] = p }
            for a in missing where following[a] == nil { following[a] = (try? await env.posts.isFollowing(a)) ?? false }
            for id in page.items.compactMap(\.carID) where cars[id] == nil { cars[id] = try? await env.garage.car(id) }
            for id in page.items.compactMap(\.meetID) where meets[id] == nil { meets[id] = try? await env.meets.meet(id) }
        } catch {
            if case WaypointsError.offline = error { offline = true } else { failed = true }
        }
        loading = false
    }

    func toggleLike(_ post: Post) {
        guard let i = posts.firstIndex(where: { $0.id == post.id }) else { return }
        posts[i].likedByMe.toggle()
        posts[i].likeCount += posts[i].likedByMe ? 1 : -1
        let liked = posts[i].likedByMe
        Task { if liked { try? await env.posts.like(post.id) } else { try? await env.posts.unlike(post.id) } }
    }

    func follow(_ user: UserID) {
        following[user] = true
        Task { try? await env.posts.follow(user) }
    }

    func hide(_ post: Post) { posts.removeAll { $0.id == post.id } }
}

struct FeedHome: View {
    let env: AppEnvironment
    let registry: FeatureRegistry
    let uploader: Uploader
    @State private var mode = "foryou"
    @State private var forYou: FeedModel
    @State private var followingFeed: FeedModel
    @State private var posting = false

    init(env: AppEnvironment, registry: FeatureRegistry, uploader: Uploader) {
        self.env = env; self.registry = registry; self.uploader = uploader
        _forYou = State(initialValue: FeedModel(env: env))
        _followingFeed = State(initialValue: FeedModel(env: env, followingOnly: true))
    }

    private var model: FeedModel { mode == "following" ? followingFeed : forYou }

    private var options: [(value: String, title: LocalizedStringKey)] {
        [("following", "Following"), ("foryou", "For you")] + registry.feedModes.prefix(1).map { ($0.id, LocalizedStringKey($0.title)) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let extra = registry.feedModes.first(where: { $0.id == mode }) {
                extra.view().padding(.top, Size.row)
            } else {
                Pager(model: model, followingOnly: mode == "following", switchToForYou: { mode = "foryou" }, post: { posting = true })
                    .id(mode)
            }
            HStack {
                Spacer()
                SegmentedSwitch(selection: $mode, options: options).frame(maxWidth: Size.row * 5.5)
                Spacer()
            }
            .overlay(alignment: .trailing) {
                IconButton(Symbol.add, label: "Post", style: .overMap) { posting = true }.padding(.trailing, Space.s12)
            }
            .padding(.top, Space.s8)
            if uploader.progress != nil {
                ProgressView(value: uploader.progress ?? 0).tint(.sodium).padding(.top, Size.row).padding(.horizontal, Space.margin)
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toast(Binding(get: { uploader.toast }, set: { uploader.toast = $0 }))
        .sheet(isPresented: $posting) { PostVideo(env: env, uploader: uploader) }
        .task(id: mode) { if registry.feedModes.allSatisfy({ $0.id != mode }) && model.posts.isEmpty { await model.refresh() } }
    }
}

struct Pager: View {
    @Bindable var model: FeedModel
    let followingOnly: Bool
    let switchToForYou: () -> Void
    let post: () -> Void
    @State private var pool = PlayerPool()
    @State private var current: Int? = 0
    @State private var commentsFor: Post?
    @State private var overflow: Post?

    private var posts: [Post] { model.posts }

    var body: some View {
        Group {
            if posts.isEmpty && !model.loading {
                VStack {
                    Spacer()
                    if model.failed || model.offline {
                        ErrorState(Text("Couldn't load the feed.", bundle: .module)) { Task { await model.refresh() } }
                    } else if followingOnly {
                        EmptyState("Nobody you follow has posted yet.", actionTitle: "See For you", action: switchToForYou)
                    } else {
                        EmptyState("No posts near you yet. Post the first one.", actionTitle: "Post", action: post)
                    }
                    Spacer()
                }
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(posts.enumerated()), id: \.element.id) { i, p in
                            Group {
                                if let path = p.videoPath {
                                    let url = model.env.media.publicURL(bucket: .posts, path: path)
                                    VideoPage(model: model, post: p, player: pool.player(for: i, url: url),
                                              pool: pool, comments: { commentsFor = p }, overflow: { overflow = p },
                                              retry: { pool.retry(i, url: url) })
                                } else {
                                    PhotoPage(model: model, post: p, comments: { commentsFor = p }, overflow: { overflow = p })
                                }
                            }
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(i)
                                .onAppear { if i >= posts.count - 3 { Task { await model.more() } } }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $current)
                .ignoresSafeArea(edges: .top)
                .onChange(of: current) { pool.play(current ?? 0) }
                .onAppear { pool.play(current ?? 0) }
                .onDisappear { pool.pauseAll() }
            }
        }
        .connectionBanner(model.offline ? .offline : nil)
        .sheet(item: $commentsFor) { p in Comments(env: model.env, post: p) }
        .confirmationDialog("", isPresented: Binding(get: { overflow != nil }, set: { if !$0 { overflow = nil } })) {
            if let p = overflow {
                Button("Not interested") { model.hide(p) }
                Button("Report") { model.env.router.open(.reportContent(ContentRef(kind: .post, id: p.id.description))) }
                if p.authorID != model.me {
                    Button("Block", role: .destructive) { Task { try? await model.env.safety.block(p.authorID); model.hide(p) } }
                }
            }
        }
    }
}

struct VideoPage: View {
    let model: FeedModel
    let post: Post
    let player: AVPlayer
    let pool: PlayerPool
    let comments: () -> Void
    let overflow: () -> Void
    let retry: () -> Void
    @State private var paused = false
    @State private var heart: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// FEED-8: the item failed to load or to play; the poster stays with "Try again".
    @State private var failed = false

    var body: some View {
        ZStack(alignment: .bottom) {
            MediaView(url: model.env.media.publicURL(bucket: .posts, path: post.posterPath), cornerRadius: 0, label: Text(verbatim: post.caption))
            if failed {
                VStack(spacing: Space.s12) {
                    Text("Couldn't play this.", bundle: .module).typeStyle(.body).foregroundStyle(Color.chalk)
                    SecondaryButton("Try again") { failed = false; retry() }
                }
                .padding(Space.s16)
                .background(Color.tarmac, in: RoundedRectangle(cornerRadius: Radius.r12))
                .padding(.horizontal, Space.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onLongPressGesture { overflow() }
                .accessibilityAction(named: Text("More options", bundle: .module)) { overflow() }
            } else {
                PlayerLayerView(player: player)
                    .onTapGesture(count: 2) { loc in
                        if !post.likedByMe { model.toggleLike(post) }
                        heart = loc
                        Task { try? await Task.sleep(for: .seconds(Timing.likeHeart)); heart = nil }
                    }
                    .onTapGesture {
                        paused.toggle()
                        if paused { player.pause() } else { player.play() }
                        pool.muted = false
                    }
                    .onLongPressGesture { overflow() }
                    .accessibilityElement()
                    .accessibilityLabel(post.caption.isEmpty ? Text("Video", bundle: .module) : Text(verbatim: post.caption))
                    .accessibilityValue(paused ? Text("Paused", bundle: .module) : Text("Playing", bundle: .module))
                    .accessibilityAddTraits([.isButton, .startsMediaSession])
                    .accessibilityAction {
                        paused.toggle()
                        if paused { player.pause() } else { player.play() }
                        pool.muted = false
                    }
                    .accessibilityAction(named: Text(post.likedByMe ? "Unlike" : "Like", bundle: .module)) { model.toggleLike(post) }
                    .accessibilityAction(named: Text("More options", bundle: .module)) { overflow() }
            }
            if let heart {
                Image(systemName: "heart.fill").font(.system(size: Size.likeHeart)).foregroundStyle(Color.brake)
                    .position(heart).transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
            PostOverlay(model: model, post: post, comments: comments)
        }
        .clipped()
        .motion(.quick, value: heart)
        .onReceive(player.publisher(for: \.currentItem?.status).receive(on: DispatchQueue.main)) { failed = $0 == .failed }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification).receive(on: DispatchQueue.main)) {
            if ($0.object as? AVPlayerItem) === player.currentItem { failed = true }
        }
    }

}

/// Author, caption, tags, and the like/comment/share rail over a video or photo post (FEED-3, FEED-4).
struct PostOverlay: View {
    let model: FeedModel
    let post: Post
    let comments: () -> Void
    @State private var expanded = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Gradients.scrim.frame(height: Size.row * 4).allowsHitTesting(false)
            HStack(alignment: .bottom) {
                info
                Spacer()
                rail
            }
            .padding(Space.margin)
            .padding(.bottom, Space.s16)
        }
    }

    private var info: some View {
        let author = model.authors[post.authorID]
        return VStack(alignment: .leading, spacing: Space.s8) {
            HStack(spacing: Space.s8) {
                Button { model.env.router.open(.profile(post.authorID)) } label: {
                    Avatar(name: author?.displayName ?? "", url: author?.avatarPath.map { model.env.media.publicURL(bucket: .avatars, path: $0) }, size: .s40)
                    Text(verbatim: "@\(author?.handle ?? "")").typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
                }
                if model.following[post.authorID] == false && post.authorID != model.me {
                    QuietButton("Follow") { model.follow(post.authorID) }
                }
            }
            if !post.caption.isEmpty {
                Text(verbatim: post.caption).typeStyle(.body).foregroundStyle(Color.chalk).lineLimit(expanded ? nil : 2)
                    .onTapGesture { expanded.toggle() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(expanded ? Text("Shows less", bundle: .module) : Text("Shows the whole caption", bundle: .module))
            }
            if let id = post.carID, let car = model.cars[id] {
                Button { model.env.router.open(.car(id)) } label: {
                    CarBadge(car.shortLabel, icon: author?.markerIcon ?? "coupe", paint: car.colorHex.flatMap { Color(paintHex: $0) } ?? .dust)
                }
            }
            if let id = post.meetID, let meet = model.meets[id] {
                Button { model.env.router.open(.meet(id)) } label: {
                    Text("At \(meet.title)", bundle: .module).typeStyle(.sub).foregroundStyle(Color.chalk)
                }
            }
        }
    }

    private var rail: some View {
        VStack(spacing: Space.s16) {
            railButton(post.likedByMe ? "heart.fill" : Symbol.like, count: post.likeCount, tint: post.likedByMe ? .brake : .chalk, label: "Like") {
                model.toggleLike(post)
            }
            railButton(Symbol.comment, count: post.commentCount, tint: .chalk, label: "Comments", action: comments)
            if let url = Route.post(post.id).shareURL {
                ShareLink(item: url) {
                    Image.symbol(Symbol.share).font(.title2).foregroundStyle(Color.chalk).frame(width: Size.hitTarget, height: Size.hitTarget)
                }
                .accessibilityLabel(Text("Share", bundle: .module))
            }
        }
    }

    private func railButton(_ symbol: String, count: Int, tint: Color, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Space.s2) {
                Image(systemName: symbol).font(.title2).foregroundStyle(tint)
                Text(verbatim: "\(count)").typeStyle(.readoutS).foregroundStyle(Color.chalk)
            }
            .frame(minWidth: Size.hitTarget, minHeight: Size.hitTarget)
        }
        .accessibilityLabel(Text(label, bundle: .module))
        .accessibilityValue(Text(verbatim: "\(count)"))
    }
}

// MARK: FEED-11 photo posts

/// A photo post: up to 6 photos swiped sideways inside the vertical pager, with the same overlay.
struct PhotoPage: View {
    let model: FeedModel
    let post: Post
    let comments: () -> Void
    let overflow: () -> Void
    @State private var page = 0
    @State private var heart: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $page) {
                ForEach(Array(post.photoPaths.enumerated()), id: \.offset) { i, path in
                    MediaView(url: model.env.media.publicURL(bucket: .posts, path: path), cornerRadius: 0, label: Text(verbatim: post.caption))
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: post.photoPaths.count > 1 ? .always : .never))
            .onTapGesture(count: 2) { loc in
                if !post.likedByMe { model.toggleLike(post) }
                heart = loc
                Task { try? await Task.sleep(for: .seconds(Timing.likeHeart)); heart = nil }
            }
            .onLongPressGesture { overflow() }
            .accessibilityAction(named: Text(post.likedByMe ? "Unlike" : "Like", bundle: .module)) { model.toggleLike(post) }
            .accessibilityAction(named: Text("More options", bundle: .module)) { overflow() }
            if let heart {
                Image(systemName: "heart.fill").font(.system(size: Size.likeHeart)).foregroundStyle(Color.brake)
                    .position(heart).transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
            PostOverlay(model: model, post: post, comments: comments)
        }
        .clipped()
        .motion(.quick, value: heart)
    }
}

struct SinglePost: View {
    let env: AppEnvironment
    let postID: PostID
    @State private var model: FeedModel
    @State private var pool = PlayerPool()
    @State private var comments: Post?

    init(env: AppEnvironment, postID: PostID) {
        self.env = env; self.postID = postID
        _model = State(initialValue: FeedModel(env: env))
    }

    var body: some View {
        Group {
            if let p = model.posts.first, let path = p.videoPath {
                let url = env.media.publicURL(bucket: .posts, path: path)
                VideoPage(model: model, post: p, player: pool.player(for: 0, url: url),
                          pool: pool, comments: { comments = p }, overflow: {}, retry: { pool.retry(0, url: url) })
                    .onAppear { pool.play(0) }
                    .onDisappear { pool.pauseAll() }
            } else if let p = model.posts.first {
                PhotoPage(model: model, post: p, comments: { comments = p }, overflow: {})
            } else {
                SkeletonBlock(height: Size.row * 8)
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .sheet(item: $comments) { Comments(env: env, post: $0) }
        .task {
            if let p = try? await env.posts.post(postID) {
                model.posts = [p]
                if let a = try? await env.profiles.profile(p.authorID) { model.authors[a.userID] = a }
                if let id = p.carID { model.cars[id] = try? await env.garage.car(id) }
                if let id = p.meetID { model.meets[id] = try? await env.meets.meet(id) }
            }
        }
    }
}

// MARK: F2 Comments

struct Comments: View {
    let env: AppEnvironment
    let post: Post
    @State private var comments: [PostComment] = []
    @State private var authors: [UserID: Profile] = [:]
    @State private var draft = ""
    @State private var me: UserID?
    @State private var error: String?

    var body: some View {
        Sheet(Text("Comments", bundle: .module)) {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if comments.isEmpty { Text("No comments yet.", bundle: .module).typeStyle(.sub).foregroundStyle(Color.dust).padding(Space.margin) }
                        ForEach(comments) { c in
                            let a = authors[c.authorID]
                            Row(Text(verbatim: "@\(a?.handle ?? "")  \(c.body)"),
                                subtitle: Text(verbatim: c.createdAt.formatted(.relative(presentation: .numeric))),
                                leading: { Avatar(name: a?.displayName ?? "", size: .s28) })
                                .contextMenu {
                                    if c.authorID == me || post.authorID == me {
                                        Button("Delete", role: .destructive) {
                                            Task { try? await env.posts.deleteComment(c.id); await load() }
                                        }
                                    } else {
                                        Button("Report") { env.router.open(.reportContent(ContentRef(kind: .comment, id: c.id.description))) }
                                    }
                                }
                        }
                    }
                }
                if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                HStack {
                    Field("Comment", text: $draft, prompt: "Add a comment", limit: 300)
                    IconButton(Symbol.send, label: "Send") {
                        let text = draft
                        Task {
                            if case .blocked = await env.safety.check(text) { error = "That comment can't be posted."; return }
                            do {
                                _ = try await env.posts.addComment(text, to: post.id)
                                draft = ""
                                error = nil
                            } catch WaypointsError.rateLimited {
                                error = FeedCopy.rateLimited
                            } catch {
                                self.error = "Couldn't post that comment. Try again."
                            }
                            await load()
                        }
                    }
                    .disabled(draft.isEmpty)
                }
                .padding(Space.s12)
            }
        }
        .presentationDetents([.medium, .large])
        .task { me = await env.auth.currentSession()?.userID; await load() }
    }

    private func load() async {
        comments = (try? await env.posts.comments(on: post.id)) ?? []
        for p in (try? await env.profiles.profiles(Array(Set(comments.map(\.authorID))))) ?? [] { authors[p.userID] = p }
    }
}

// MARK: F3 Post a video

/// Uploads continue after the sheet closes; drafts stay on the device when they fail.
@MainActor
@Observable
final class Uploader {
    let env: AppEnvironment
    var progress: Double?
    var toast: ToastMessage?

    init(env: AppEnvironment) { self.env = env }

    /// FEED-11: photos upload in order; the first is also the poster.
    func post(photos: [Data], caption: String, car: CarID?, meet: MeetID?) {
        progress = 0
        Task {
            do {
                var paths: [String] = []
                let total = Double(photos.count)
                for (i, data) in photos.prefix(Post.maxPhotos).enumerated() {
                    let media = try await env.media.upload(data, contentType: "image/jpeg", to: .posts) { p in
                        Task { @MainActor in self.progress = (Double(i) + p) / total }
                    }
                    paths.append(media.path)
                }
                guard let first = paths.first else { throw WaypointsError.invalid("photo") }
                _ = try await env.posts.createPost(NewPost(carID: car, meetID: meet, videoPath: nil, photoPaths: paths,
                                                           posterPath: first, caption: caption, durationMs: 0))
                toast = ToastMessage(Text("Posted", bundle: .module))
            } catch WaypointsError.rateLimited {
                toast = ToastMessage(Text(FeedCopy.rateLimited))
            } catch {
                toast = ToastMessage(Text("Couldn't post. Check your connection and try again.", bundle: .module))
            }
            progress = nil
        }
    }

    func post(video: URL, poster: Data, caption: String, car: CarID?, meet: MeetID?, duration: Double) {
        progress = 0
        Task {
            do {
                let exported = try await Self.export(video)
                let data = try Data(contentsOf: exported.url)
                let seconds = max(0.001, min(duration, exported.duration))
                let posterMedia = try await env.media.upload(poster, contentType: "image/jpeg", to: .posts) { _ in }
                let videoMedia = try await env.media.upload(data, contentType: "video/mp4", to: .posts) { p in
                    Task { @MainActor in self.progress = p }
                }
                _ = try await env.posts.createPost(NewPost(carID: car, meetID: meet, videoPath: videoMedia.path,
                                                           posterPath: posterMedia.path, caption: caption,
                                                           durationMs: Int(seconds * 1000)))
                toast = ToastMessage(Text("Posted", bundle: .module))
            } catch WaypointsError.rateLimited {
                toast = ToastMessage(Text(FeedCopy.rateLimited))
            } catch {
                let drafts = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "drafts")
                try? FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: video, to: drafts.appending(path: video.lastPathComponent))
                toast = ToastMessage(Text("Couldn't post. Saved as a draft.", bundle: .module))
            }
            progress = nil
        }
    }

    /// Upload cap (FEED-7, plan F3).
    nonisolated static let maxBytes: Int64 = 12 * 1024 * 1024

    /// HEVC, short side scaled to 720, capped at 30 s and 12 MB, with no metadata (SEC-4: no
    /// location). `fileLengthLimit` ends the file early rather than exceed the cap, so the
    /// returned duration is read back from the export.
    nonisolated static func export(_ url: URL) async throws -> (url: URL, duration: Double) {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality),
              let track = try await asset.loadTracks(withMediaType: .video).first else { throw WaypointsError.invalid("video") }
        let length = min(try await asset.load(.duration), CMTime(seconds: 30, preferredTimescale: 600))
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let scale = min(1, 720 / max(1, min(abs(rect.width), abs(rect.height))))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: length)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: (abs(rect.width) * scale / 2).rounded() * 2, height: (abs(rect.height) * scale / 2).rounded() * 2)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]

        let out = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        session.videoComposition = composition
        session.timeRange = CMTimeRange(start: .zero, duration: length)
        session.fileLengthLimit = maxBytes
        session.metadata = []
        session.metadataItemFilter = .forSharing()
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: out, as: .mp4)
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? 0
        guard size > 0, size <= maxBytes else { throw WaypointsError.invalid("video") }
        let exported = try await AVURLAsset(url: out).load(.duration).seconds
        return (out, exported)
    }
}

struct VideoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return VideoFile(url: copy)
        }
    }
}

struct PostVideo: View {
    let env: AppEnvironment
    let uploader: Uploader
    @Environment(\.dismiss) private var dismiss
    @State private var item: PhotosPickerItem?
    @State private var pick = false
    @State private var video: URL?
    @State private var duration = 0.0
    @State private var cover = 0.0
    @State private var poster: UIImage?
    /// FEED-11: a photo post instead of a video, up to 6.
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photos: [UIImage] = []
    @State private var pickPhotos = false
    @State private var caption = ""
    @State private var cars: [Car] = []
    @State private var car: CarID?
    @State private var meets: [Meet] = []
    @State private var meet: MeetID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s16) {
                    if !photos.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Space.s8) {
                                ForEach(Array(photos.enumerated()), id: \.offset) { _, image in
                                    Image(uiImage: image).resizable().aspectRatio(9.0 / 16.0, contentMode: .fill)
                                        .frame(width: Size.row * 2, height: Size.row * 3.5)
                                        .clipShape(RoundedRectangle(cornerRadius: Radius.r12))
                                }
                            }
                        }
                        SecondaryButton("Choose photos") { pickPhotos = true }
                    } else if let poster {
                        Image(uiImage: poster).resizable().aspectRatio(9.0 / 16.0, contentMode: .fit)
                            .frame(maxHeight: Size.row * 6).clipShape(RoundedRectangle(cornerRadius: Radius.r12))
                        Text("Cover frame", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust)
                        Slider(value: $cover, in: 0...max(duration, 0.1)).tint(.sodium)
                            .onChange(of: cover) { Task { await makePoster() } }
                    } else {
                        SecondaryButton("Choose a video") { pick = true }
                        SecondaryButton("Choose photos") { pickPhotos = true }
                    }
                    Field("Caption", text: $caption, limit: 150, axis: .vertical)
                    Menu {
                        Button("No car") { car = nil }
                        ForEach(cars) { c in Button(c.shortLabel) { car = c.id } }
                    } label: {
                        Row(Text("Tag a car", bundle: .module), showsDivider: false, trailing: {
                            Text(verbatim: cars.first { $0.id == car }?.shortLabel ?? "").typeStyle(.sub)
                        })
                    }
                    if !meets.isEmpty {
                        Menu {
                            Button("No meet") { meet = nil }
                            ForEach(meets) { m in Button(m.title) { meet = m.id } }
                        } label: {
                            Row(Text("Tag a meet", bundle: .module), showsDivider: false, trailing: {
                                Text(verbatim: meets.first { $0.id == meet }?.title ?? "").typeStyle(.sub)
                            })
                        }
                    }
                    PrimaryButton("Post") {
                        if !photos.isEmpty {
                            let data = photos.compactMap { $0.jpegData(compressionQuality: 0.85) }
                            uploader.post(photos: data, caption: caption, car: car, meet: meet)
                            dismiss()
                            return
                        }
                        guard let video, let data = poster?.jpegData(compressionQuality: 0.8) else { return }
                        uploader.post(video: video, poster: data, caption: caption, car: car, meet: meet, duration: min(duration, 30))
                        dismiss()
                    }
                    .disabled(video == nil && photos.isEmpty)
                }
                .padding(Space.margin)
            }
            .background(Color.asphalt.ignoresSafeArea())
            .navigationTitle("Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { QuietButton("Cancel") { dismiss() } } }
            .photosPicker(isPresented: $pick, selection: $item, matching: .videos)
            .photosPicker(isPresented: $pickPhotos, selection: $photoItems, maxSelectionCount: Post.maxPhotos,
                          selectionBehavior: .ordered, matching: .images)
        }
        .onChange(of: item) {
            Task {
                guard let file = try? await item?.loadTransferable(type: VideoFile.self) else { return }
                photos = []
                photoItems = []
                video = file.url
                duration = (try? await AVURLAsset(url: file.url).load(.duration).seconds) ?? 0
                await makePoster()
            }
        }
        .onChange(of: photoItems) {
            Task {
                var loaded: [UIImage] = []
                for it in photoItems.prefix(Post.maxPhotos) {
                    if let data = try? await it.loadTransferable(type: Data.self), let image = UIImage(data: data) { loaded.append(image) }
                }
                guard !loaded.isEmpty else { return }
                photos = loaded
                video = nil
                poster = nil
            }
        }
        .task {
            if let me = await env.auth.currentSession()?.userID {
                cars = (try? await env.garage.cars(of: me)) ?? []
                meets = ((try? await env.meets.upcomingMeets(for: me)) ?? []).filter { $0.cancelledAt == nil && $0.startsAt <= .now }
            }
        }
    }

    private func makePoster() async {
        guard let video else { return }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        gen.appliesPreferredTrackTransform = true
        if let (cg, _) = try? await gen.image(at: CMTime(seconds: cover, preferredTimescale: 600)) { poster = UIImage(cgImage: cg) }
    }
}
