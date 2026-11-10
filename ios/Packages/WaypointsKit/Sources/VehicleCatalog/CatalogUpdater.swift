import CryptoKit
import Core
import Foundation

/// Checks `catalog/manifest.json` in Supabase Storage at most once a day and downloads a newer
/// catalog in the background. The download swaps in atomically on the next launch, so the
/// picker never waits on the network (plan 11.1).
enum CatalogUpdater {
    struct Manifest: Decodable { let version: String; let url: URL; let sha256: String; let bytes: Int }

    static let checkedKey = "catalog.checkedAt"
    static let versionKey = "catalog.version"

    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Moves a verified pending download into place. Called before the catalog is opened.
    static func swapInPending() {
        let fm = FileManager.default
        let pending = support.appending(path: "catalog.next.sqlite")
        let live = support.appending(path: "catalog.sqlite")
        guard fm.fileExists(atPath: pending.path) else { return }
        _ = try? fm.replaceItemAt(live, withItemAt: pending)
        if !fm.fileExists(atPath: live.path) { try? fm.moveItem(at: pending, to: live) }
        if let v = UserDefaults.standard.string(forKey: "catalog.pendingVersion") {
            UserDefaults.standard.set(v, forKey: versionKey)
        }
    }

    static func checkInBackground(config: AppConfig) {
        let last = UserDefaults.standard.double(forKey: checkedKey)
        guard Date.now.timeIntervalSince1970 - last > 86_400 else { return }
        Task.detached(priority: .background) {
            await check(config: config)
        }
    }

    static func check(config: AppConfig) async {
        let manifestURL = config.supabaseURL.appending(path: "storage/v1/object/public/catalog/manifest.json")
        guard let (data, _) = try? await URLSession.shared.data(from: manifestURL),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: checkedKey)
        let current = UserDefaults.standard.string(forKey: versionKey) ?? ""
        guard m.version.compare(current, options: .numeric) == .orderedDescending,
              let (tmp, _) = try? await URLSession.shared.download(from: m.url),
              let body = try? Data(contentsOf: tmp) else { return }
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        guard digest == m.sha256.lowercased() else { return }
        let expanded = (try? (body as NSData).decompressed(using: .lzfse) as Data) ?? body
        try? expanded.write(to: support.appending(path: "catalog.next.sqlite"), options: .atomic)
        UserDefaults.standard.set(m.version, forKey: "catalog.pendingVersion")
    }
}
