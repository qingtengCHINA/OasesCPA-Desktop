# Full-history scan before the history rewrite (Task 22)

Recorded 2026-11-08 on branch `codex/oases-open-edition` (45 commits after `f0f2500`), with the
owner's private terms file. Findings are described by rule, commit and location only; no
finding text, not even in the scanner's masked form, is reproduced here.

Every commit id on this page (`f0f2500`, `7a8183c`, `a99cebc`, `9ca68cb`) is a pre-rewrite id:
it exists only BEFORE the history rewrite. After the rewrite the `f0f2500..HEAD` range scans
below can no longer be run; CI (`.github/workflows/private-scan.yml`) uses `--history`, which
names no commit id, and that scan must then be clean.

## Scans that must be clean

| Command | Exit | Findings |
|---|---|---|
| `bash script/check-no-private.sh --tree --require-private-terms` | 0 | 0 |
| added lines of `git log -p -U0 --format= f0f2500..HEAD` through `--stdin --require-private-terms` (the CI form, rulings C1/H7) | 0 | 0 |
| `git log --format=%B f0f2500..HEAD` through `--stdin --require-private-terms` | 0 | 0 |
| `git log --format='author: %ae%ncommitter: %ce' f0f2500..HEAD` through `--stdin --require-private-terms` | 0 | 0 |

## Scans that are expected to fail until the rewrite

`bash script/check-no-private.sh --history --require-private-terms`: exit 1, 15 findings, all
in the four old commits `7a8183c` → `a99cebc` → `9ca68cb` → `f0f2500` (a straight line; `main`,
`origin/main` and the three `codex/oases-cpa-0.1.x` branches point into it):

| Rule | Count | Where |
|---|---|---|
| `author-email` | 2 | one address, as author and as committer; the scanner reports each address once (at `f0f2500`), and `git log --format='%h %ae%n%h %ce' f0f2500` shows the same single non-noreply address for both roles of all four old commits |
| `private-term` | 11 | one term, the old bundle identifier stem, added in `7a8183c`: `project.yml` (2), `OasesCPA.xcodeproj/project.pbxproj` (6), `Sources/OasesCPA/Services/KeychainStore.swift`, `script/build_and_run.sh`, `script/package_release.sh` |
| `private-term` | 2 | one other term, added in `7a8183c`: `README.md`, `Sources/OasesCPA/Views/SettingsView.swift` |

No other rule fires anywhere in the history, and no finding comes from a commit after
`f0f2500` (those commits only remove the old strings).

The two full-text forms of the brief count removed lines too, and therefore also fail:
`git log -p --format=fuller --all ^f0f2500 | … --stdin` reports 13 `private-term` findings (the
lines that removed the stem and the other term), and `git log -p --format='commit %H' f0f2500 |
… --stdin --require-private-terms` reports 15 (13 of the stem, 2 of the other term). The
added-lines form above is the one CI and the commit gate use.

## After the rewrite

`script/prepare_history_rewrite.sh` found 1 address for the mailmap and 2 terms for the
replace-text file (the stem → `com.example.cpa`, the other term → `REDACTED`). Applying those
rules to the text of `git log -p --all --format=%B` and scanning it with `--stdin
--require-private-terms` gave 0 findings (28 before, counting removed lines). The rewrite itself
(`git filter-repo`) and the rescan of the rewritten history have not been run: the owner runs
them (`docs/open-source-release.md`, section 4). From then on the release scans are the
post-rewrite ones of `docs/open-source-release.md`, section 3 (`--tree`, `--history`, and the
e-mail lines of `git log --all`), the same as CI; all must exit 0.
