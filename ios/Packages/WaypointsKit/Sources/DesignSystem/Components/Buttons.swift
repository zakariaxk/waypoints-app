import SwiftUI

// PrimaryButton, SecondaryButton, QuietButton, DestructiveButton, IconButton (plan 9.9).

/// Fill and label for the filled button kinds.
enum FilledButtonKind {
    case primary, secondary, destructive

    func fill(enabled: Bool) -> Color {
        guard enabled else { return .curb }
        switch self {
        case .primary: return .sodium
        case .secondary, .destructive: return .concrete
        }
    }

    func label(enabled: Bool) -> Color {
        guard enabled else { return .gravel }
        switch self {
        case .primary: return .asphalt
        case .secondary: return .chalk
        case .destructive: return .brake
        }
    }
}

struct FilledButtonStyle: ButtonStyle {
    let kind: FilledButtonKind
    let isLoading: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var height = Size.control

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .typeStyle(.bodyStrong)
            .multilineTextAlignment(.center)
            .opacity(isLoading ? 0 : 1)
            .overlay { if isLoading { LoadingDots() } }
            .foregroundStyle(kind.label(enabled: isEnabled))
            .padding(.horizontal, Space.s16)
            .padding(.vertical, Space.s12)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(kind.fill(enabled: isEnabled), in: RoundedRectangle(cornerRadius: Radius.r12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.r12, style: .continuous))
            .scaleEffect(configuration.isPressed ? Opacity.pressedScale : 1)
            .animation(Motion.quick.resolved(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// The 3-dot stepped loading indicator. Steps instead of sliding; static with Reduce Motion.
struct LoadingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var dot = Space.s8

    var body: some View {
        TimelineView(.periodic(from: .now, by: Timing.loadingStep)) { context in
            let step = reduceMotion ? -1 : Int(context.date.timeIntervalSinceReferenceDate / Timing.loadingStep) % 3
            HStack(spacing: Space.s4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: dot, height: dot)
                        .opacity(index == step ? 1 : Opacity.inactive)
                }
            }
        }
        .accessibilityLabel(Text("Loading", bundle: .module))
    }
}

/// The primary action of a screen. At most one per screen.
public struct PrimaryButton: View {
    private let title: LocalizedStringKey
    private let isLoading: Bool
    private let action: () -> Void

    public init(_ title: LocalizedStringKey, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button(title, action: action)
            .buttonStyle(FilledButtonStyle(kind: .primary, isLoading: isLoading))
            .allowsHitTesting(!isLoading)
    }
}

public struct SecondaryButton: View {
    private let title: LocalizedStringKey
    private let isLoading: Bool
    private let action: () -> Void

    public init(_ title: LocalizedStringKey, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button(title, action: action)
            .buttonStyle(FilledButtonStyle(kind: .secondary, isLoading: isLoading))
            .allowsHitTesting(!isLoading)
    }
}

/// Text only, `sodium`. For the lesser of two actions.
public struct QuietButton: View {
    private let title: LocalizedStringKey
    private let action: () -> Void

    public init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(title, action: action).buttonStyle(QuietButtonStyle())
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .typeStyle(.bodyStrong)
            .foregroundStyle(isEnabled ? Color.sodium : Color.gravel)
            .frame(minWidth: Size.hitTarget, minHeight: Size.hitTarget)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? Opacity.pressed : 1)
            .animation(Motion.quick.resolved(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// `brake` label on `concrete`. Always asks first, naming what will be lost.
public struct DestructiveButton: View {
    private let title: LocalizedStringKey
    private let confirmTitle: LocalizedStringKey
    private let consequence: LocalizedStringKey
    private let isLoading: Bool
    private let action: () -> Void
    @State private var isConfirming = false

    /// - Parameters:
    ///   - confirmTitle: the dialog's destructive choice, for example "Delete car".
    ///   - consequence: what will be lost, for example "Your build timeline and photos for this car are deleted."
    public init(_ title: LocalizedStringKey, confirmTitle: LocalizedStringKey, consequence: LocalizedStringKey,
                isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.consequence = consequence
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button(title) { isConfirming = true }
            .buttonStyle(FilledButtonStyle(kind: .destructive, isLoading: isLoading))
            .allowsHitTesting(!isLoading)
            .confirmationDialog(title, isPresented: $isConfirming, titleVisibility: .visible) {
                Button(confirmTitle, role: .destructive, action: action)
            } message: {
                Text(consequence)
            }
    }
}

/// A 44 pt symbol-only button. The accessibility label is required.
public struct IconButton: View {
    public enum Style: Sendable { case plain, overMap }

    private let symbol: String
    private let label: LocalizedStringKey
    private let style: Style
    private let action: () -> Void

    public init(_ symbol: String, label: LocalizedStringKey, style: Style = .plain, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.style = style
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image.symbol(symbol)
                .imageScale(.large)
                .foregroundStyle(Color.chalk)
                .frame(width: Size.hitTarget, height: Size.hitTarget)
                .background {
                    if style == .overMap {
                        Circle().fill(.regularMaterial).mapShadow()
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(Text(label))
    }
}

struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Opacity.pressedScale : 1)
            .animation(Motion.quick.resolved(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

#Preview("Buttons") {
    VStack(spacing: Space.s12) {
        PrimaryButton("Start meet") {}
        PrimaryButton("Post report", isLoading: true) {}
        PrimaryButton("List it") {}.disabled(true)
        SecondaryButton("Invite a friend") {}
        QuietButton("Not now") {}
        DestructiveButton("Delete car", confirmTitle: "Delete car",
                          consequence: "The build timeline and photos for this car are deleted.") {}
        HStack {
            IconButton(Symbol.recenter, label: "Recenter", style: .overMap) {}
            IconButton(Symbol.close, label: "Close") {}
        }
    }
    .padding(Space.margin)
    .background(Color.asphalt)
    .preferredColorScheme(.dark)
}
