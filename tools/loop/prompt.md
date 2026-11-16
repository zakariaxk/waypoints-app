You are an agent in the Waypoints loop, working inside this repository checkout.

Read `AGENTS.md` first and follow it exactly: straight to `main`, no branches, no PRs, no attribution trailers, commit message starts with the work package id.

## Your item

%ITEM%

## Rules for this run

1. Read `docs/PRD.md` sections 0 and 2 and the rows named above; read `docs/PLAN.md` sections those rows cite. The PRD wins any disagreement; fix the code or the row in your commit and say which.
2. Edit only files in your item's area. If a needed change sits outside it, make the minimal change and say so.
3. Implement the task. Keep to the smallest change that meets the requirement.
4. Before committing: `git pull --rebase`, then `make build` and require exit 0. If your item names database or realtime behavior, also run `make check-db` or `make check-rt` when the local stack is available (it may not be; skip with a note if `make dev` is not already running).
5. Update the PRD status of the requirement ids in your item in the same commit.
6. Commit and `git push origin main`. If the push is rejected, `git pull --rebase` and push again.
7. Do not touch `tools/loop/`. Do not spawn subagents. Do not stop to ask; decide per AGENTS.md section 1.

When done, reply with one line: `RESULT <id> done|partial|blocked: <what changed>`.
