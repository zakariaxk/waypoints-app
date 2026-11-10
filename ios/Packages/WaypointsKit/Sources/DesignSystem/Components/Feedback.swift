import SwiftUI

// Sheet, Banner, EmptyState, ErrorState, Skeleton, Toast (plan 9.9).

// MARK: Sheet

/// Sheet chrome: `r28`, `tarmac` (or material over the map), drag indicator, and a title row.
public struct Sheet<Content: View, Trailing: View>: View {
    private let title: Text?
    private let overMap: Bool
    private let content: Content
    private let trailing: Trailing

    public init(_ title: Text? = nil, overMap: Bool = false,
                @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.overMap = overMap
        self.trailing = trailing()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: Space.s12) {
                    title.typeStyle(.title).foregroundStyle(Color.chalk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    trailing
                }
                .padding(.horizontal, Space.margin)
                .padding(.top, Space.s24)
                .padding(.bottom, Space.s8)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheetChrome(overMap: overMap)
    }
}

public extension Sheet where Trailing == EmptyView {
    init(_ title: Text? = nil, overMap: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title, overMap: overMap, trailing: { EmptyView() }, content: content)
    }
}

public extension View {
    /// The sheet presentation chrome on its own, for content that builds its own header.
    func sheetChrome(overMap: Bool = false) -> some View {
        modifier(SheetChrome(overMap: overMap))
    }
}

private struct SheetChrome: ViewModifier {
    let overMap: Bool
    func body(content: Content) -> some View {
        if overMap {
            content
                .presentationCornerRadius(Radius.r28)
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        } else {
            content
                .presentationCornerRadius(Radius.r28)
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.tarmac)
        }
    }
}

// MARK: Banner

/// Connection state shown under the navigation bar. `nil` hides it.
public enum BannerState: Sendable, Equatable {
    case offline, reconnecting
}

public struct Banner: View {
    private let state: BannerState
    public init(_ state: BannerState) { self.state = state }

    public var body: some View {
        HStack(spacing: Space.s8) {
            Image.symbol(state == .offline ? Symbol.offline : Symbol.reconnecting)
                .accessibilityHidden(true)
            Group {
                switch state {
                case .offline: Text("Offline. Showing what was saved.", bundle: .module)
                case .reconnecting: Text("Reconnecting", bundle: .module)
                }
            }
            .typeStyle(.foot)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Color.chalk)
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.s8)
        .background(Color.concrete)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

public extension View {
    /// Pins the connection banner under the navigation bar. It leaves by itself when `state`
    /// becomes `nil`.
    func connectionBanner(_ state: BannerState?) -> some View {
        modifier(BannerModifier(state: state))
    }
}

private struct BannerModifier: ViewModifier {
    let state: BannerState?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if let state {
                Banner(state).transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.standard.resolved(reduceMotion: reduceMotion), value: state)
    }
}

// MARK: Empty and error states

/// One sentence of what is absent and one button that fixes it. No illustration.
public struct EmptyState: View {
    private let message: LocalizedStringKey
    private let actionTitle: LocalizedStringKey
    private let action: () -> Void

    public init(_ message: LocalizedStringKey, actionTitle: LocalizedStringKey, action: @escaping () -> Void) {
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Space.s20) {
            Text(message)
                .typeStyle(.body)
                .foregroundStyle(Color.dust)
                .multilineTextAlignment(.center)
            PrimaryButton(actionTitle, action: action)
        }
        .padding(.horizontal, Space.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What failed in plain words, and "Try again".
public struct ErrorState: View {
    private let message: Text
    private let retry: () -> Void

    public init(_ message: Text, retry: @escaping () -> Void) {
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        VStack(spacing: Space.s20) {
            message
                .typeStyle(.body)
                .foregroundStyle(Color.dust)
                .multilineTextAlignment(.center)
            SecondaryButton("Try again", action: retry)
        }
        .padding(.horizontal, Space.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Skeleton

/// A block of a loading layout, in `concrete`. No shimmer.
public struct SkeletonBlock: View {
    private let width: CGFloat?
    private let height: CGFloat
    private let cornerRadius: CGFloat

    public init(width: CGFloat? = nil, height: CGFloat, cornerRadius: CGFloat = Radius.r6) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.concrete)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// A placeholder with `Row`'s blocks: leading circle, title line, subtitle line.
public struct SkeletonRow: View {
    private let hasLeading: Bool
    @ScaledMetric(relativeTo: .body) private var line = Space.s12
    @ScaledMetric(relativeTo: .body) private var minHeight = Size.row

    public init(hasLeading: Bool = true) { self.hasLeading = hasLeading }

    public var body: some View {
        HStack(spacing: Space.s12) {
            if hasLeading {
                Circle().fill(Color.concrete).frame(width: Avatar.Diameter.s40.rawValue, height: Avatar.Diameter.s40.rawValue)
            }
            VStack(alignment: .leading, spacing: Space.s8) {
                SkeletonBlock(width: Space.s48 * 3, height: line)
                SkeletonBlock(width: Space.s48 * 2, height: line)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.rowPadding)
        .frame(minHeight: minHeight)
    }
}

/// Shows `placeholder` while `isLoading`, but only once loading has taken 300 ms; before
/// that, nothing.
public struct Skeleton<Content: View, Placeholder: View>: View {
    private let isLoading: Bool
    private let content: Content
    private let placeholder: Placeholder
    @State private var isLate = false

    public init(isLoading: Bool, @ViewBuilder content: () -> Content, @ViewBuilder placeholder: () -> Placeholder) {
        self.isLoading = isLoading
        self.content = content()
        self.placeholder = placeholder()
    }

    public var body: some View {
        Group {
            if !isLoading {
                content
            } else if isLate {
                placeholder.accessibilityLabel(Text("Loading", bundle: .module))
            } else {
                Color.clear
            }
        }
        .task(id: isLoading) {
            isLate = false
            guard isLoading else { return }
            try? await Task.sleep(for: .seconds(Timing.skeletonDelay))
            if !Task.isCancelled { isLate = true }
        }
    }
}

// MARK: Toast

/// A completed action, shown for 3 s above the tab bar, with "Undo" when undo is possible.
public struct ToastMessage: Identifiable, Equatable {
    public let id = UUID()
    public let text: Text
    public let undo: (@MainActor () -> Void)?

    public init(_ text: Text, undo: (@MainActor () -> Void)? = nil) {
        self.text = text
        self.undo = undo
    }

    public static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool { lhs.id == rhs.id }
}

public struct Toast: View {
    private let message: ToastMessage
    private let dismiss: () -> Void

    public init(_ message: ToastMessage, dismiss: @escaping () -> Void) {
        self.message = message
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(spacing: Space.s12) {
            message.text
                .typeStyle(.body)
                .foregroundStyle(Color.chalk)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let undo = message.undo {
                Button { undo(); dismiss() } label: { Text("Undo", bundle: .module) }
                    .buttonStyle(QuietButtonStyle())
            }
        }
        .padding(.leading, Space.s16)
        .padding(.trailing, Space.s8)
        .padding(.vertical, Space.s4)
        .frame(minHeight: Size.control)
        .background(Color.concrete, in: RoundedRectangle(cornerRadius: Radius.r12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.r12, style: .continuous).strokeBorder(Color.seam, lineWidth: Size.Marker.innerStroke))
        .padding(.horizontal, Space.margin)
        .padding(.bottom, Space.s8)
        .accessibilityElement(children: .contain)
    }
}

public extension View {
    /// Shows `message` at the bottom for 3 s, then clears it.
    func toast(_ message: Binding<ToastMessage?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var message: ToastMessage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let current = message {
                    Toast(current) { message = nil }
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        .task(id: current.id) {
                            try? await Task.sleep(for: .seconds(Timing.toast))
                            if !Task.isCancelled, message?.id == current.id { message = nil }
                        }
                }
            }
            .animation(Motion.standard.resolved(reduceMotion: reduceMotion), value: message)
    }
}

#Preview("Feedback") {
    VStack(spacing: 0) {
        Banner(.offline)
        Banner(.reconnecting)
        SkeletonRow()
        SkeletonRow()
        EmptyState("No friends on the map yet.", actionTitle: "Invite a friend") {}
        Toast(ToastMessage(Text(verbatim: "Report posted"), undo: {})) {}
    }
    .background(Color.asphalt)
    .preferredColorScheme(.dark)
}
