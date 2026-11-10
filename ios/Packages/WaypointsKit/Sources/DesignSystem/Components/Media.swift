import SwiftUI

// Avatar, Readout, MediaView (plan 9.9).

/// A circular avatar. Missing photo: initials on `curb`.
public struct Avatar: View {
    public enum Diameter: CGFloat, Sendable, CaseIterable {
        case s28 = 28, s40 = 40, s64 = 64, s96 = 96

        var initialsToken: TypeToken {
            switch self {
            case .s28: .readoutS
            case .s40: .foot
            case .s64: .title
            case .s96: .display
            }
        }
    }

    private let name: String
    private let url: URL?
    private let size: Diameter

    public init(name: String, url: URL? = nil, size: Diameter) {
        self.name = name
        self.url = url
        self.size = size
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    public var body: some View {
        CachedImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color.curb
                Text(verbatim: initials)
                    .font(size.initialsToken.font.weight(.semibold))
                    .foregroundStyle(Color.chalk)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(Space.s2)
            }
        }
        .frame(width: size.rawValue, height: size.rawValue)
        .clipShape(Circle())
        .accessibilityLabel(Text(verbatim: name))
    }
}

/// A measurement: number in a readout token, unit in `readoutS` `dust` after a thin space,
/// optional `label` above, optional low–high range as a thin bar beneath.
public struct Readout: View {
    /// A low–high estimate drawn inside `bounds`.
    public struct Range: Sendable, Equatable {
        public var low: Double
        public var high: Double
        public var bounds: ClosedRange<Double>
        public init(low: Double, high: Double, bounds: ClosedRange<Double>) {
            self.low = low
            self.high = high
            self.bounds = bounds
        }
    }

    private let value: String
    private let unit: String?
    private let label: LocalizedStringKey?
    private let token: TypeToken
    private let range: Range?

    public init(_ value: String, unit: String? = nil, label: LocalizedStringKey? = nil,
                token: TypeToken = .readoutM, range: Range? = nil) {
        precondition(token.isReadout, "Readout takes a readout token")
        self.value = value
        self.unit = unit
        self.label = label
        self.token = token
        self.range = range
    }

    private var number: Text {
        var text = Text(verbatim: value).font(token.font).foregroundStyle(Color.chalk)
        if let unit {
            text = text + Text(verbatim: thinSpace + unit).font(TypeToken.readoutS.font).foregroundStyle(Color.dust)
        }
        return text
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if let label {
                Text(label).typeStyle(.label).foregroundStyle(Color.dust)
            }
            number.contentTransition(.numericText())
            if let range {
                RangeBar(range: range)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RangeBar: View {
    let range: Readout.Range

    var body: some View {
        GeometryReader { proxy in
            let span = max(range.bounds.upperBound - range.bounds.lowerBound, .ulpOfOne)
            let start = (range.low - range.bounds.lowerBound) / span
            let end = (range.high - range.bounds.lowerBound) / span
            ZStack(alignment: .leading) {
                Capsule().fill(Color.curb)
                Capsule()
                    .fill(Color.chalk)
                    .frame(width: max(Size.rangeBar, proxy.size.width * (end - start)))
                    .offset(x: proxy.size.width * start)
            }
        }
        .frame(height: Size.rangeBar)
        .accessibilityHidden(true)
    }
}

/// An image with a `concrete` placeholder and a 0.2 s crossfade on load. Tap opens it full
/// screen with a zoom transition from the thumbnail.
public struct MediaView: View {
    private let url: URL?
    private let aspectRatio: CGFloat?
    private let cornerRadius: CGFloat
    private let label: Text
    @Namespace private var namespace
    @State private var isFullScreen = false

    public init(url: URL?, aspectRatio: CGFloat? = nil, cornerRadius: CGFloat = Radius.r20, label: Text) {
        self.url = url
        self.aspectRatio = aspectRatio
        self.cornerRadius = cornerRadius
        self.label = label
    }

    public var body: some View {
        Button { isFullScreen = true } label: {
            Color.concrete
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    CachedImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.concrete
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: "media", in: namespace)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isImage)
        .fullScreenCover(isPresented: $isFullScreen) {
            FullScreenMedia(url: url, label: label) { isFullScreen = false }
                .navigationTransition(.zoom(sourceID: "media", in: namespace))
        }
    }
}

private struct FullScreenMedia: View {
    let url: URL?
    let label: Text
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.asphalt.ignoresSafeArea()
            CachedImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.concrete
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(label)
            IconButton(Symbol.close, label: "Close", style: .overMap, action: close)
                .padding(Space.margin)
        }
    }
}

#Preview("Avatar, Readout, Media") {
    VStack(alignment: .leading, spacing: Space.s24) {
        HStack(spacing: Space.s12) {
            ForEach(Avatar.Diameter.allCases, id: \.self) { Avatar(name: "Dev Patel", size: $0) }
        }
        Readout("412", unit: "hp", label: "Power", token: .readoutL,
                range: .init(low: 395, high: 430, bounds: 300...500))
        Readout("11.8", unit: "s", token: .readoutXL)
        MediaView(url: nil, aspectRatio: 4 / 3, label: Text(verbatim: "2019 Mustang GT, front three quarter"))
    }
    .padding(Space.margin)
    .background(Color.asphalt)
    .preferredColorScheme(.dark)
}
