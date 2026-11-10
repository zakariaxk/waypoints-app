import AVFoundation
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
    var muted = true { didSet { players.values.forEach { $0.isMuted = muted } } }

    func player(for index: Int, url: URL) -> AVPlayer {
        if let p = players[index] { return p }
        for key in players.keys where abs(key - index) > 1 {
            players[key]?.pause()
            players[key] = nil
            if let o = looper[key] { NotificationCenter.default.removeObserver(o) }
            looper[key] = nil
        }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 2
        let p = AVPlayer(playerItem: item)
        p.isMuted = muted
        looper[index] = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            MainActor.assumeIsolated { p.seek(to: .zero); p.play() }
        }
        players[index] = p
        return p
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

// MARK: F1

@MainActor
@Observable
final class FeedModel {
    let env: AppEnvironment
    var posts: [Post] = []
    var authors: [UserID: Profile] = [:]
    var following: [UserID: Bool] = [:]
    var cars: [CarID: Car] = [:]
    var next: PageCursor?
    var loading = false
    var failed = false
    var me: UserID?

    init(env: AppEnvironment) { self.env = env }

    func refresh() async {
        posts = []
        next = nil
        await more()
    }

    func more() async {
        guard !loading else { return }
        loading = true
        me = await env.auth.currentSession()?.userID
        do {
            let page = try await env.posts.feed(after: next, limit: 10)
            posts += page.items
            next = page.next
            failed = false
            let missing = Set(page.items.map(\.authorID)).filter { authors[$0] == nil }
            for p in (try? await env.profiles.profiles(Array(missing))) ?? [] { authors[p.userID] = p }
            for a in missing where following[a] == nil { following[a] = (try? await env.posts.isFollowing(a)) ?? false }
            for id in page.items.compactMap(\.carID) where cars[id] == nil { cars[id] = try? await env.garage.car(id) }
        } catch {
            failed = true
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
    @State private var model: FeedModel
    @State private var posting = false

    init(env: AppEnvironment, registry: FeatureRegistry, uploader: Uploader) {
        self.env = env; self.registry = registry; self.uploader = uploader
        _model = State(initialValue: FeedModel(env: env))
    }

    private var options: [(value: String, title: LocalizedStringKey)] {
        [("following", "Following"), ("foryou", "For you")] + registry.feedModes.prefix(1).map { ($0.id, LocalizedStringKey($0.title)) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let extra = registry.feedModes.first(where: { $0.id == mode }) {
                extra.view().padding(.top, Size.row)
            } else {
                Pager(model: model, followingOnly: mode == "following", switchToForYou: { mode = "foryou" }, post: { posting = true })
            }
            HStack {
                Spacer()
                SegmentedSwitch(selection: $mode, options: options).frame(maxWidth: Size.row * 5.5)
                Spacer()
            }
            .overlay(alignment: .trailing) {
                IconButton(Symbol.add, label: "Post a video", style: .overMap) { posting = true }.padding(.trailing, Space.s12)
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
        .task { if model.posts.isEmpty { await model.refresh() } }
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

    private var posts: [Post] {
        followingOnly ? model.posts.filter { model.following[$0.authorID] == true } : model.posts
    }

    var body: some View {
        Group {
            if posts.isEmpty && !model.loading {
                VStack {
                    Spacer()
                    if followingOnly {
                        EmptyState("Nobody you follow has posted yet.", actionTitle: "See For you", action: switchToForYou)
                    } else if model.failed {
                        ErrorState(Text("Couldn't load the feed.")) { Task { await model.refresh() } }
                    } else {
                        EmptyState("No videos near you yet. Post the first one.", actionTitle: "Post a video", action: post)
                    }
                    Spacer()
                }
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(posts.enumerated()), id: \.element.id) { i, p in
                            VideoPage(model: model, post: p, player: pool.player(for: i, url: model.env.media.publicURL(bucket: .posts, path: p.videoPath)),
                                      pool: pool, comments: { commentsFor = p }, overflow: { overflow = p })
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
    @State private var paused = false
    @State private var heart: CGPoint?
    @State private var expanded = false

    var body: some View {
        ZStack(alignment: .bottom) {
            MediaView(url: model.env.media.publicURL(bucket: .posts, path: post.posterPath), cornerRadius: 0, label: Text(verbatim: post.caption))
            PlayerLayerView(player: player)
                .onTapGesture(count: 2) { loc in
                    if !post.likedByMe { model.toggleLike(post) }
                    heart = loc
                    Task { try? await Task.sleep(for: .milliseconds(600)); heart = nil }
                }
                .onTapGesture {
                    paused.toggle()
                    if paused { player.pause() } else { player.play() }
                    pool.muted = false
                }
                .onLongPressGesture { overflow() }
            if let heart {
                Image(systemName: "heart.fill").font(.system(size: Size.row * 1.6)).foregroundStyle(Color.brake)
                    .position(heart).transition(.scale.combined(with: .opacity))
            }
            Gradients.scrim.frame(height: Size.row * 4).allowsHitTesting(false)
            HStack(alignment: .bottom) {
                info
                Spacer()
                rail
            }
            .padding(Space.margin)
            .padding(.bottom, Space.s16)
        }
        .clipped()
        .motion(.quick, value: heart)
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
            }
            if let id = post.carID, let car = model.cars[id] {
                Button { model.env.router.open(.car(id)) } label: {
                    CarBadge(car.shortLabel, icon: author?.markerIcon ?? "coupe", paint: car.colorHex.flatMap { Color(paintHex: $0) } ?? .dust)
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
            if let url = URL(string: "waypoints://post/\(post.id)") {
                ShareLink(item: url) {
                    Image.symbol(Symbol.share).font(.title2).foregroundStyle(Color.chalk).frame(width: Size.hitTarget, height: Size.hitTarget)
                }
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
        .accessibilityLabel(Text(label))
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
            if let p = model.posts.first {
                VideoPage(model: model, post: p, player: pool.player(for: 0, url: env.media.publicURL(bucket: .posts, path: p.videoPath)),
                          pool: pool, comments: { comments = p }, overflow: {})
                    .onAppear { pool.play(0) }
                    .onDisappear { pool.pauseAll() }
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
        Sheet(Text("Comments")) {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if comments.isEmpty { Text("No comments yet.").typeStyle(.sub).foregroundStyle(Color.dust).padding(Space.margin) }
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
                            draft = ""
                            _ = try? await env.posts.addComment(text, to: post.id)
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

    func post(video: URL, poster: Data, caption: String, car: CarID?, duration: Double) {
        progress = 0
        Task {
            do {
                let exported = try await Self.export(video)
                let data = try Data(contentsOf: exported)
                let posterMedia = try await env.media.upload(poster, contentType: "image/jpeg", to: .posts) { _ in }
                let videoMedia = try await env.media.upload(data, contentType: "video/mp4", to: .posts) { p in
                    Task { @MainActor in self.progress = p }
                }
                _ = try await env.posts.createPost(NewPost(carID: car, videoPath: videoMedia.path, posterPath: posterMedia.path,
                                                           caption: caption, durationMs: Int(duration * 1000)))
                toast = ToastMessage(Text("Posted"))
            } catch {
                let drafts = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "drafts")
                try? FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: video, to: drafts.appending(path: video.lastPathComponent))
                toast = ToastMessage(Text("Couldn't post. Saved as a draft."))
            }
            progress = nil
        }
    }

    /// 720p, capped at 30 s.
    nonisolated static func export(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return url }
        let out = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 30, preferredTimescale: 600))
        try await session.export(to: out, as: .mp4)
        return out
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
    @State private var pick = true
    @State private var video: URL?
    @State private var duration = 0.0
    @State private var cover = 0.0
    @State private var poster: UIImage?
    @State private var caption = ""
    @State private var cars: [Car] = []
    @State private var car: CarID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s16) {
                    if let poster {
                        Image(uiImage: poster).resizable().aspectRatio(9.0 / 16.0, contentMode: .fit)
                            .frame(maxHeight: Size.row * 6).clipShape(RoundedRectangle(cornerRadius: Radius.r12))
                        Text("Cover frame").typeStyle(.foot).foregroundStyle(Color.dust)
                        Slider(value: $cover, in: 0...max(duration, 0.1)).tint(.sodium)
                            .onChange(of: cover) { Task { await makePoster() } }
                    } else {
                        SecondaryButton("Choose a video") { pick = true }
                    }
                    Field("Caption", text: $caption, limit: 150, axis: .vertical)
                    Menu {
                        Button("No car") { car = nil }
                        ForEach(cars) { c in Button(c.shortLabel) { car = c.id } }
                    } label: {
                        Row(Text("Tag a car"), showsDivider: false, trailing: {
                            Text(verbatim: cars.first { $0.id == car }?.shortLabel ?? "").typeStyle(.sub)
                        })
                    }
                    PrimaryButton("Post") {
                        guard let video, let data = poster?.jpegData(compressionQuality: 0.8) else { return }
                        uploader.post(video: video, poster: data, caption: caption, car: car, duration: min(duration, 30))
                        dismiss()
                    }
                    .disabled(video == nil)
                }
                .padding(Space.margin)
            }
            .background(Color.asphalt.ignoresSafeArea())
            .navigationTitle("Post a video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { QuietButton("Cancel") { dismiss() } } }
            .photosPicker(isPresented: $pick, selection: $item, matching: .videos)
        }
        .onChange(of: item) {
            Task {
                guard let file = try? await item?.loadTransferable(type: VideoFile.self) else { return }
                video = file.url
                duration = (try? await AVURLAsset(url: file.url).load(.duration).seconds) ?? 0
                await makePoster()
            }
        }
        .task {
            if let me = await env.auth.currentSession()?.userID { cars = (try? await env.garage.cars(of: me)) ?? [] }
        }
    }

    private func makePoster() async {
        guard let video else { return }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        gen.appliesPreferredTrackTransform = true
        if let (cg, _) = try? await gen.image(at: CMTime(seconds: cover, preferredTimescale: 600)) { poster = UIImage(cgImage: cg) }
    }
}
