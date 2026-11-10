import SwiftUI
import UIKit

/// The app is portrait except where a screen asks otherwise (the Strip run is landscape).
/// The app delegate reads `mask`.
@MainActor
public enum OrientationLock {
    public static private(set) var mask: UIInterfaceOrientationMask = .portrait

    public static func set(_ new: UIInterfaceOrientationMask) {
        mask = new
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: new)) { _ in }
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}

public extension View {
    /// Locks orientation while this view is on screen, then returns to portrait.
    func orientation(_ mask: UIInterfaceOrientationMask) -> some View {
        onAppear { OrientationLock.set(mask) }
            .onDisappear { OrientationLock.set(.portrait) }
    }
}
