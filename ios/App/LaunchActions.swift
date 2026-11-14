import AppShell
import Backend
import Core
import Foundation

/// Launch arguments (PRD 7.1). Read once from the process arguments:
///
///     -wp-preview          debug: build the environment from PreviewEnvironment (no backend)
///     -wp-login <handle>   debug, loopback Supabase only: sign in as a seed user (or an email)
///                          with the development password from supabase/seed.sql
///     -wp-open <url>       open a link once signed in; debug builds add waypoints://debug/<screen>
///     -wp-smoke            debug: call every repository method once and print PASS or FAIL
struct LaunchOptions: Sendable {
    var preview = false
    var login: String?
    var open: URL?
    var smoke = false

    static let current = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        var it = arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "-wp-preview": preview = true
            case "-wp-smoke": smoke = true
            case "-wp-login": login = it.next()
            case "-wp-open": open = it.next().flatMap(URL.init(string:))
            default: break
            }
        }
    }
}

@MainActor
enum LaunchActions {
    /// The development password every seed user has (supabase/seed.sql, README).
    static let devPassword = "waypoints-dev"

    /// Seed handles to their sign-in emails (supabase/seed.sql).
    static let seedEmails: [String: String] = [
        "marcus_s2k": "marcus.reyes@waypoints.test",
        "dana_gti": "dana.whitfield@waypoints.test",
        "priya_wrx": "priya.natarajan@waypoints.test",
        "tkowalski": "tom.kowalski@waypoints.test",
        "jaylen_e46": "jaylen.brooks@waypoints.test",
        "sofia_mk4": "sofia.moretti@waypoints.test",
        "ray_foxbody": "ray.delgado@waypoints.test",
        "kenji_ae86": "kenji.watanabe@waypoints.test",
        "alexis_fl5": "alexis.grant@waypoints.test",
        "omar_350z": "omar.haddad@waypoints.test",
        "bree_a90": "bree.lawson@waypoints.test",
        "nick_evo": "nick.ferraro@waypoints.test",
        "deals4wheels": "deals.wheels@waypoints.test",
    ]

    static func run(shell: ShellModel) async {
        let options = LaunchOptions.current
        #if DEBUG
        if let handle = options.login {
            await login(handle, env: shell.environment, preview: options.preview)
        }
        #endif
        if let url = options.open {
            _ = await shell.waitUntilSignedIn()
            // Let the tab roots appear so a pushed route has a stack to land on.
            try? await Task.sleep(for: .milliseconds(300))
            shell.open(url: url)
        }
        #if DEBUG
        if options.smoke {
            if await shell.waitUntilSignedIn() {
                await SmokeRunner.run(env: shell.environment)
            } else {
                print("SMOKE FAIL not signed in after 20 s (add -wp-login <handle> or -wp-preview)")
            }
        }
        #endif
    }

    #if DEBUG
    private static func login(_ handle: String, env: AppEnvironment, preview: Bool) async {
        if preview {
            print("-wp-login: ignored with -wp-preview (already signed in as the preview user)")
            return
        }
        let config = CompositionRoot.loadConfig()
        let host = config.supabaseURL.host()?.lowercased() ?? ""
        guard ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else {
            print("-wp-login: refused, Supabase URL \(config.supabaseURL) is not a loopback address")
            return
        }
        let key = handle.lowercased()
        guard let email = key.contains("@") ? key : seedEmails[key] else {
            print("-wp-login: unknown seed handle \(handle); known: \(seedEmails.keys.sorted().joined(separator: ", "))")
            return
        }
        do {
            if let session = await env.auth.currentSession() {
                if session.email?.lowercased() == email {
                    print("-wp-login: already signed in as \(email)")
                    return
                }
                try await env.auth.signOut()
            }
            let session = try await Backend.debugSignIn(env.auth, email: email, password: devPassword)
            print("-wp-login: signed in as \(email) (\(session.userID))")
        } catch {
            print("-wp-login: sign-in as \(email) failed: \(error)")
        }
    }
    #endif
}
