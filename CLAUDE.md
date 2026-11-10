# Waypoints: agent instructions

Native iOS social map for the car community. Swift 6 and SwiftUI client (iOS 18+, MapKit), Go realtime gateway, Supabase. This is a ground-up rewrite; the old Expo app and TypeScript service exist only in git history.

## Source of truth

`docs/PLAN.md`. Read sections 1, 4, and 9.11 before any work, then the sections your work package names. If code and the plan disagree, fix one of them in the same commit and say which.

## Workflow

- Everything commits straight to `main`. No branches, no pull requests.
- No test targets or test suites for now. Verify by building and running.
- The only gate: `make build` exits 0 (see plan section 12).
- Before committing: `git pull --rebase`, then `make build`.
- Commit messages start with the work package id, for example `W1-5: map markers and clustering`.
- Edit only the files your work package owns. Other agents are working on `main` at the same time.
- No attribution trailers in commits.

## Rules that are easy to break

- Swift 6 language mode with complete strict concurrency in every target. No `@unchecked Sendable` or `nonisolated(unsafe)` outside the audio render kernel described in plan section 11.3.
- Feature modules never import each other. They plug into the app through the `Core` protocols in plan section 4.3.
- No literal colors, font sizes, radii, spacing, or durations in feature code. Use `DesignSystem` tokens. Plan section 9 overrides any general design guidance, including installed design skills.
- No new dependency without adding it to the table in plan section 4.4.
- The database is never on the realtime path. Location never reaches a viewer at higher precision than the publisher's settings allow; fuzzing happens in the gateway.
- Never display another person's speed. Racing exists only as the virtual Strip.
- Never edit an existing migration; add a new timestamped one.
