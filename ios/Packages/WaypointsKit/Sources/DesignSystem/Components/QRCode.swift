import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

// QR codes for meet-in-person adding and team invites (PRD SOC-9).

/// A QR code of `payload`, drawn in `asphalt` modules on a `chalk` field with a quiet zone.
/// Scanners need dark on light, so this is one of the few light surfaces in the app.
public struct QRCodeView: View {
    private let payload: String
    private let image: CGImage?

    public init(_ payload: String) {
        self.payload = payload
        self.image = QRCodeView.render(payload)
    }

    /// Modules become opaque and the field transparent, so the code can be tinted by a token.
    static func render(_ payload: String) -> CGImage? {
        let qr = CIFilter.qrCodeGenerator()
        qr.message = Data(payload.utf8)
        qr.correctionLevel = "M"
        guard let modules = qr.outputImage else { return nil }
        let invert = CIFilter.colorInvert()
        invert.inputImage = modules
        let mask = CIFilter.maskToAlpha()
        mask.inputImage = invert.outputImage
        guard let output = mask.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    public var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .renderingMode(.template)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .foregroundStyle(Color.asphalt)
            } else {
                Color.concrete.aspectRatio(1, contentMode: .fit)
            }
        }
        .padding(Space.s16)
        .background(Color.chalk, in: RoundedRectangle(cornerRadius: Radius.r20, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(Text("QR code"))
        .accessibilityValue(Text(verbatim: payload))
    }
}

/// A screen showing one code to be scanned in person, with the same link to share.
/// Used by "My code" (Friends) and "Invite people" (a team).
public struct QRCodeScreen: View {
    private let title: Text
    private let heading: Text
    private let caption: Text?
    private let url: URL

    public init(_ title: Text, heading: Text, caption: Text? = nil, url: URL) {
        self.title = title
        self.heading = heading
        self.caption = caption
        self.url = url
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Space.s16) {
                    heading.typeStyle(.title).foregroundStyle(Color.chalk)
                    if let caption { caption.typeStyle(.sub).foregroundStyle(Color.dust) }
                    QRCodeView(url.absoluteString)
                        .frame(maxWidth: Size.row * 6)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.s16)
                }
                .padding(.top, Space.s16)
                .padding(.horizontal, Space.margin)
                ShareLink(item: url) {
                    Row(Text("Share link"), showsDivider: false, trailing: { Image.symbol(Symbol.share) })
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("QR code") {
    NavigationStack {
        QRCodeScreen(Text(verbatim: "My code"), heading: Text(verbatim: "@maya.gt"),
                     caption: Text(verbatim: "Scan it in Friends to add each other."),
                     url: URL(string: "waypoints://profile/6f1c2a52-8d0e-4c43-9a51-3b8f6d1e2c77")!)
    }
    .preferredColorScheme(.dark)
}
