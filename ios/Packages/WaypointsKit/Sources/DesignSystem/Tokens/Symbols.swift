import SwiftUI

/// SF Symbols, one meaning each across the app (plan 9.7). Weight `.medium` in content,
/// `.semibold` in the tab bar, hierarchical rendering, never multicolor.
public enum Symbol {
    // Tabs (plan 10.1)
    public static let map = "map"
    public static let feed = "play.rectangle"
    public static let market = "tag"
    public static let teams = "person.3"
    public static let garage = "car.side"

    // Navigation and chrome
    public static let close = "xmark"
    public static let back = "chevron.left"
    public static let disclosure = "chevron.right"
    public static let more = "ellipsis"
    public static let add = "plus"
    public static let search = "magnifyingglass"
    public static let settings = "gearshape"
    public static let share = "square.and.arrow.up"
    public static let edit = "pencil"
    public static let delete = "trash"
    public static let confirm = "checkmark"

    // Map
    public static let recenter = "location.fill"
    public static let directions = "arrow.triangle.turn.up.right.diamond"
    public static let layers = "square.2.layers.3d"
    public static let ghost = "eye.slash"

    // Social
    public static let send = "arrow.up"
    public static let like = "heart"
    public static let comment = "bubble.left"
    public static let friend = "person.crop.circle.badge.plus"
    public static let invite = "person.badge.plus"
    public static let report = "flag"
    public static let block = "hand.raised"

    // Media and voice
    public static let camera = "camera"
    public static let photo = "photo"
    public static let micOn = "mic"
    public static let micOff = "mic.slash"
    public static let speaker = "speaker.wave.2"

    // Connection and status
    public static let offline = "wifi.slash"
    public static let reconnecting = "arrow.triangle.2.circlepath"
    public static let warning = "exclamationmark.triangle"
    public static let time = "clock"
    public static let place = "mappin"

    public static let all: [(String, String)] = [
        ("map", map), ("feed", feed), ("market", market), ("teams", teams), ("garage", garage),
        ("close", close), ("back", back), ("disclosure", disclosure), ("more", more), ("add", add),
        ("search", search), ("settings", settings), ("share", share), ("edit", edit),
        ("delete", delete), ("confirm", confirm), ("recenter", recenter), ("directions", directions),
        ("layers", layers), ("ghost", ghost), ("send", send), ("like", like), ("comment", comment),
        ("friend", friend), ("invite", invite), ("report", report), ("block", block),
        ("camera", camera), ("photo", photo), ("micOn", micOn), ("micOff", micOff),
        ("speaker", speaker), ("offline", offline), ("reconnecting", reconnecting),
        ("warning", warning), ("time", time), ("place", place),
    ]
}

public extension Image {
    /// An interface symbol with the content weight and hierarchical rendering.
    static func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.hierarchical)
            .fontWeight(.medium)
    }
}
