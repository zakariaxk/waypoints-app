# Waypoints: agent instructions

Native iOS social map for the car community. Swift 6 and SwiftUI client (iOS 18+, MapKit), Go realtime gateway, Supabase. A ground-up rewrite; the old Expo app and TypeScript service exist only in git history.

The owner is the only human on the project and wants finished work, fast. Act; do not ask for permission to do what the task already says.

## How to work

The four habits below are adapted from [forrestchang/andrej-karpathy-skills](https://github.com/forrestchang/andrej-karpathy-skills) (Karpathy's notes on where coding agents go wrong), tuned for this repo: speed over ceremony.

### 1. Decide, then say what you assumed

- Read the code before guessing. If two readings of a task are possible, pick the one the PRD supports, do it, and state the assumption in one line of the commit message or your reply.
- Stop to ask only when a wrong guess would destroy data, spend money, or contradict PRD section 2.1. Everything else: decide and move.
- If a simpler approach exists than the one asked for, take it and say so.

### 2. The least code that does the job

- Nothing beyond the requirement. No options, flags, protocols, or generic layers for a single caller.
- No error handling for things that cannot happen. No fallbacks for code paths you control.
- No new dependency, service, queue, cache, or build step when the platform or 30 lines will do (plan 4.4 lists the allowed dependencies).
- Three similar lines beat a premature abstraction. If you wrote 200 lines and 50 would do, rewrite it before committing.
- Before adding anything, apply PRD 2.3 (the over-engineering test). If it fails, it does not ship.

### 3. Surgical changes

- Every changed line traces to the task. Do not reformat, rename, re-comment, or "improve" neighbouring code.
- Match the style of the file you are in.
- Remove what your change orphaned (imports, helpers, strings). Leave other dead code alone; name it in your reply.
- A gap you find outside your files goes into that requirement's row in the PRD, not into a drive-by fix.

### 4. Prove it, cheaply

- Turn the task into a check that would fail if the work were wrong, then loop until it passes: `make build`, `make check-rt`, `make check-db`, `make shot`, a `curl`. PRD section 7 lists the harness.
- Pick the cheapest proof. Do not build a test rig for a one-line fix.
- Report what you ran and what it showed. "Should work" is not a result. If you could not verify something, say exactly that.

### Speed

- Batch independent reads, searches, and commands in one step. Do not re-read files you already have.
- Do not narrate plans, write summaries of summaries, or create planning or report documents. The PRD row and the commit message are the record.
- One iOS build at a time on this machine (it shares one DerivedData). Finish your edits, then build once; do not build after every edit.
- Subagents: give each a disjoint set of files, tell it not to build or commit unless it is the only one running, and ask for a short list of changes back.

## Source of truth

1. `docs/PRD.md`: what to build, priority, the status of every requirement, and the work packages. Read sections 0 and 2, your package's entry in section 8, and the requirements it names.
2. `docs/PLAN.md`: how it is built (architecture, contracts, schema, wire protocol, design system, every screen). Read sections 1, 4, and 9.11, then the sections your requirements cite.

If the PRD, the plan, and the code disagree, the higher one wins; fix the lower one in the same commit and say which. Every task names the requirement ids it serves and updates their status in the PRD in the same commit.

## Git

- Everything commits straight to `main` and is pushed. No branches, no pull requests, no worktrees left behind, ever. Do not suggest them.
- Commit each piece of work as soon as it builds. Small commits, pushed immediately.
- Before committing: `git pull --rebase`, then `make build` (exit 0, no warnings in files you touched). That is the only gate. There are no test targets.
- Commit messages start with the work package id: `W1-5: map markers and clustering`.
- No attribution trailers, no "generated with" lines. The owner is the sole author.
- Never edit an existing migration; add a new timestamped one.

## Rules that are easy to break

- Swift 6 language mode with complete strict concurrency in every target. No `@unchecked Sendable` or `nonisolated(unsafe)` outside the audio render kernel (plan 11.3).
- A completion handler passed to a system API from `@MainActor` code inherits the main actor and traps when the system calls it on another queue. Use the `async` form of the API, or mark the closure `@Sendable`.
- Feature modules never import each other. They plug into the app through the `Core` protocols in plan 4.3.
- No literal colors, font sizes, radii, spacing, or durations in feature code. Use `DesignSystem` tokens. Plan section 9 overrides any general design guidance, including installed design skills.
- User-facing copy goes through the module's String Catalog: `Text("…", bundle: .module)` or `String(localized: "…", bundle: .module)`. Run `tools/l10n/extract.py` after adding copy.
- The database is never on the realtime path. Location never reaches a viewer at higher precision than the publisher's settings allow; fuzzing happens in the gateway.
- Never display another person's speed. Racing exists only as the virtual Strip.
- Third-party code, designs, and assets: permissive licences only (MIT, Apache-2.0, BSD, CC0), recorded with their source. No manufacturer logos.

## Commands

```sh
make build          # the gate: go build and vet, xcodegen, xcodebuild for the simulator
make check-rt       # gateway behaviour against a throwaway bench gateway; PASS or FAIL per scenario
make check-db       # access rules in supabase/checks.sql (needs the local stack: make dev)
make shot NAME=<n> ARGS="-wp-preview -wp-open waypoints://debug/<screen>"   # .build/shots/<n>.png
make screenshots    # the App Store set
python3 tools/l10n/extract.py   # regenerate String Catalogs
```

`README.md` lists every debug screen and launch argument.

## The loop

`tools/loop/` is the iteration engine that keeps agents working the queue:

- `tools/loop/queue.md` — the work list, one line per item: `- [ ] L## | REQ-IDS | files | task`. Markers: `[ ]` open, `[~]` running, `[x]` done, `[!]` failed, `[-]` blocked on the owner.
- `tools/loop/loop.sh` — the orchestrator. Pops the first open item, renders `tools/loop/prompt.md`, and runs a headless `devin -p` session that implements, builds, commits, and pushes. Repeats until the queue is empty or `tools/loop/STOP` exists. Needs `devin auth login` once; `ITEM_TIMEOUT` needs `gtimeout` (coreutils). Logs land in `.build/loop/`.
- A driving agent session is an equally valid orchestrator: work the queue top-down, delegate each item to a subagent, integrate, `make build`, push, mark the row.

Rules: the orchestrator owns `queue.md`; workers never edit it. Failed items stay marked `[!]` — re-open them as `[ ]` once the cause is fixed. New gaps discovered during any run get a queue row, not a drive-by fix in an unrelated item.
