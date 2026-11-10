import SwiftUI

// Row and SectionLabel (plan 9.9). Lists are rows on `asphalt`, not cards.

/// A full-width row: leading slot, title, optional subtitle, trailing slot. 56 pt minimum; the
/// `seam` divider is inset to the text edge.
public struct Row<Leading: View, Trailing: View>: View {
    private let title: Text
    private let subtitle: Text?
    private let showsDivider: Bool
    private let leading: Leading
    private let trailing: Trailing
    @ScaledMetric(relativeTo: .body) private var minHeight = Size.row

    public init(_ title: Text, subtitle: Text? = nil, showsDivider: Bool = true,
                @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.showsDivider = showsDivider
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: Space.s12) {
            leading
            HStack(spacing: Space.s12) {
                VStack(alignment: .leading, spacing: Space.s2) {
                    title.typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
                    if let subtitle {
                        subtitle.typeStyle(.sub).foregroundStyle(Color.dust)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing.foregroundStyle(Color.dust)
            }
            .padding(.vertical, Space.rowPadding)
            .padding(.trailing, Space.margin)
            .frame(minHeight: minHeight)
            .overlay(alignment: .bottom) { if showsDivider { Hairline() } }
        }
        .padding(.leading, Space.margin)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

public extension Row where Leading == EmptyView {
    init(_ title: Text, subtitle: Text? = nil, showsDivider: Bool = true, @ViewBuilder trailing: () -> Trailing) {
        self.init(title, subtitle: subtitle, showsDivider: showsDivider, leading: { EmptyView() }, trailing: trailing)
    }
}

public extension Row where Trailing == EmptyView {
    init(_ title: Text, subtitle: Text? = nil, showsDivider: Bool = true, @ViewBuilder leading: () -> Leading) {
        self.init(title, subtitle: subtitle, showsDivider: showsDivider, leading: leading, trailing: { EmptyView() })
    }
}

public extension Row where Leading == EmptyView, Trailing == EmptyView {
    init(_ title: Text, subtitle: Text? = nil, showsDivider: Bool = true) {
        self.init(title, subtitle: subtitle, showsDivider: showsDivider, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// The trailing chevron for rows that open something.
public struct Disclosure: View {
    public init() {}
    public var body: some View {
        Image.symbol(Symbol.disclosure)
            .imageScale(.small)
            .foregroundStyle(Color.gravel)
            .accessibilityHidden(true)
    }
}

/// Highlight for a tappable row: `curb` while pressed, with `quick`.
public struct RowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.curb : Color.clear)
            .animation(Motion.quick.resolved(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Section label: `label` text in `dust`, 32 above, 8 below.
public struct SectionLabel: View {
    private let text: Text
    public init(_ title: LocalizedStringKey) { text = Text(title) }
    public init(verbatim: String) { text = Text(verbatim) }

    public var body: some View {
        text
            .typeStyle(.label)
            .foregroundStyle(Color.dust)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Space.s32)
            .padding(.bottom, Space.s8)
            .padding(.horizontal, Space.margin)
            .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Rows") {
    ScrollView {
        VStack(spacing: 0) {
            SectionLabel("Nearby")
            Row(Text(verbatim: "Maya Okafor"), subtitle: Text(verbatim: "2019 Mustang GT")) {
                Avatar(name: "Maya Okafor", size: .s40)
            } trailing: { Disclosure() }
            Row(Text(verbatim: "Cars and Coffee, Cherry Hill"), subtitle: Text(verbatim: "Saturday 8:00"),
                trailing: { Disclosure() })
            Row(Text(verbatim: "Share location"), showsDivider: false,
                trailing: { Toggle("", isOn: .constant(true)).labelsHidden().tint(.sodium) })
        }
    }
    .background(Color.asphalt)
    .preferredColorScheme(.dark)
}
