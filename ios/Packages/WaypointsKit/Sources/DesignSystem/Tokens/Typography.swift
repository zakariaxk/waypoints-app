import CoreText
import SwiftUI

/// Type tokens (plan 9.3). Each maps to a Dynamic Type style and scales with it.
public enum TypeToken: String, Sendable, CaseIterable, Identifiable {
    case display, title, label, body, bodyStrong, sub, foot
    case readoutXL, readoutL, readoutM, readoutS

    public var id: String { rawValue }

    public var font: Font {
        switch self {
        case .display: .system(.title, weight: .bold).width(.expanded)
        case .title: .system(.title3, weight: .semibold).width(.expanded)
        case .label: .system(.caption2, weight: .semibold).width(.expanded)
        case .body: .system(.body)
        case .bodyStrong: .system(.body, weight: .semibold)
        case .sub: .system(.subheadline)
        case .foot: .system(.footnote)
        case .readoutXL: ReadoutFace.font(size: 56, relativeTo: .largeTitle)
        case .readoutL: ReadoutFace.font(size: 32, relativeTo: .title)
        case .readoutM: ReadoutFace.font(size: 17, relativeTo: .body)
        case .readoutS: ReadoutFace.font(size: 12, relativeTo: .caption)
        }
    }

    /// Point size at the default content size, for tracking and the gallery.
    public var size: CGFloat {
        switch self {
        case .display: 28
        case .title: 20
        case .label: 11
        case .body, .bodyStrong, .readoutM: 17
        case .sub: 15
        case .foot: 13
        case .readoutXL: 56
        case .readoutL: 32
        case .readoutS: 12
        }
    }

    /// Tracking in points. `label` is +6%.
    public var tracking: CGFloat { self == .label ? size * 0.06 : 0 }

    public var isUppercase: Bool { self == .label }

    public var isReadout: Bool {
        switch self {
        case .readoutXL, .readoutL, .readoutM, .readoutS: true
        default: false
        }
    }
}

public extension View {
    /// Applies a type token: face, size, tracking, and case.
    func typeStyle(_ token: TypeToken) -> some View {
        font(token.font)
            .tracking(token.tracking)
            .textCase(token.isUppercase ? .uppercase : nil)
    }
}

/// A thin space, used between a number and its unit ("412 hp").
public let thinSpace = "\u{2009}"

/// B612 Mono Bold, embedded under the SIL OFL (Resources/Fonts/OFL.txt). Falls back to SF Mono
/// Bold if the file cannot be registered.
enum ReadoutFace {
    static let postScriptName: String? = register()

    static func font(size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        if let postScriptName { return .custom(postScriptName, size: size, relativeTo: style) }
        return .system(style, design: .monospaced, weight: .bold)
    }

    private static func register() -> String? {
        guard
            let url = Bundle.module.url(forResource: "B612Mono-Bold", withExtension: "ttf", subdirectory: "Fonts"),
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            let descriptor = descriptors.first,
            let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
        else { return nil }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            // Already registered is fine; anything else means the face is unusable.
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
            if code != CTFontManagerError.alreadyRegistered.rawValue { return nil }
        }
        return name
    }
}
