import Foundation

/// Locale-aware numbers and money for user-facing text (SET-3). Distances, speeds, and
/// weights follow the device's locale through `Measurement`; these helpers cover the
/// plain numbers that `String(format:)` would print with a fixed decimal point.
///
/// Money is always USD: prices and costs are stored as bare cents with no currency, and
/// the market's price fields are labelled "$".
public enum Format {
    /// A number in the device's locale with a fixed number of fraction digits:
    /// "12.3" in the US, "12,3" in the EU.
    public static func number(_ value: Double, fractionDigits digits: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    /// A signed delta: "+1.2" or "-0.4", in the device's locale.
    public static func delta(_ value: Double, fractionDigits digits: Int = 0) -> String {
        (value > 0 ? "+" : "") + number(value, fractionDigits: digits)
    }

    /// Both ends of a range at the same precision: "8.4–9.1".
    public static func range(_ r: ClosedRange<Double>, fractionDigits digits: Int = 0) -> String {
        "\(number(r.lowerBound, fractionDigits: digits))–\(number(r.upperBound, fractionDigits: digits))"
    }

    /// "$1,299" — build costs and listing prices are USD cents.
    public static func money(cents: Int) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }
}
