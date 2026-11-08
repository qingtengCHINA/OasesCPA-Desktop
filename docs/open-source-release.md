# Open-source release checklist

What has to be true before this repository is made public, and who does what. Everything that
rewrites history or talks to GitHub is done by the owner by hand; the scripts here only prepare
and check.

## 1. Build configuration

`Config/Base.xcconfig` (committed) holds neutral defaults: no signing team, the bundle
identifier prefix `com.example`, no update channel, no author and no privacy-policy link.
Personal values live only in `Config/Local.xcconfig`, which is git-ignored:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then fill in your own values
xcodegen generate
```

The keys are `DEVELOPMENT_TEAM`, `OASES_BUNDLE_ID_PREFIX`, `OASES_UPDATE_REPOSITORY`
(`owner/name`, empty = no automatic update), optionally `OASES_UPDATE_TEAM_ID`,
`OASES_AUTHOR_NAME`, `OASES_AUTHOR_URL` and `OASES_PRIVACY_POLICY_URL`. URLs are written as
`https:/$()/host/` because `//` starts a comment in `.xcconfig` files. The release scripts read
`OASES_BUNDLE_ID` (default `com.example.cpa.macos`) and refuse the neutral identifier for a
signed release (see `README.md`, "生成 DMG").

## 2. Private-string scanning

- **One scanner.** `script/check-no-private.sh` is a byte-for-byte copy of the Server repo's
  scanner; the Server repo is the source of truth. Update it only with
  `bash script/sync_check_no_private.sh <server-repo>`, which also records the Server commit and
  the script's SHA-256 in `script/check-no-private.source`
  (`check_no_private_contract_test.sh` checks that record). New generic rules go into the Server
  copy first.
- **Private terms.** The owner's literals (domains, addresses, names, the team id, the private
  bundle identifier stem, …) are in `script/private-terms.local` (git-ignored), one per line,
  `#` starts a comment; `OASES_PRIVATE_TERMS_FILE` points the scanner at another file.
  `--require-private-terms` makes a missing or empty file an error (exit 2). The file is never
  printed, quoted or committed; findings are only ever shown masked
  (`<first 3 characters>…(<length>)`).
- **CI.** `.github/workflows/private-scan.yml` writes the repository secret
  `OASES_PRIVATE_TERMS` (the same lines as the local file) into a 0600 file under
  `$RUNNER_TEMP`, sets `OASES_PRIVATE_TERMS_FILE` to it and scans with
  `--require-private-terms`. Pull requests from forks do not get the secret and run the generic
  rules only.
- **Allowlist.** `script/private-allowlist.txt` has three tab-separated columns:
  `<path glob>`, `<ERE>` and a reason. Every row needs a real reason (an empty one exits 2); a
  row only silences the text its ERE matches on the offending line; text on standard input is
  the path `<stdin>`, so rows for fixtures use the glob `*` with a tight ERE. Rows are only for
  verified synthetic values or public identities, never to hide real private data.
- **Commit gate.** Every commit goes through `oases_commit` (rulings C1): it scans the ADDED
  lines of the staged diff and the commit message with `--require-private-terms` before
  `git commit`. Removed and context lines are not scanned, so a commit that removes a private
  string can be made.

## 3. Release scans

Run from the top of the work tree; each must exit 0:

```bash
bash script/check-no-private.sh --tree --require-private-terms
# The commits since f0f2500 (the last commit before the open edition), the same form CI uses:
git log -p -U0 --no-color --no-ext-diff --format= f0f2500..HEAD \
  | grep -E '^\+' | grep -vE '^\+\+\+ ' | bash script/check-no-private.sh --stdin --require-private-terms
git log --format=%B f0f2500..HEAD | bash script/check-no-private.sh --stdin --require-private-terms
git log --format='author: %ae%ncommitter: %ce' f0f2500..HEAD | bash script/check-no-private.sh --stdin --require-private-terms
```

The range starts at `f0f2500`, not at `origin/main`: `origin/main..HEAD` would include the old
commits below. Until the history is rewritten, the full-history scan
(`bash script/check-no-private.sh --history --require-private-terms`) is EXPECTED to fail on
exactly the old commits `7a8183c` → `a99cebc` → `9ca68cb` → `f0f2500` (one straight line, the
whole history before the open edition): their author and committer address is a private
address, and the first commit holds the old bundle identifier stem and one more private term.
The measured result is in `docs/acceptance/history-scan.md`.

## 4. History rewrite (prepared here, run by the owner)

`bash script/prepare_history_rewrite.sh` writes two git-ignored, mode 0600 files and prints the
commands; it runs none of them and changes no ref, index entry or tracked file
(`script/prepare_history_rewrite_test.sh` checks that):

- `script/history-mailmap.local`: one line
  `QingTeng <qingtengCHINA@users.noreply.github.com> <old address>` per address in
  `git log --all --format='%ae%n%ce'` that is not a GitHub noreply address. No `.mailmap` is
  committed: it would publish the old addresses.
- `script/history-replace-text.local`: a `git filter-repo --replace-text` file with one
  case-insensitive rule per private term that occurs anywhere in the history. A term used as
  the bundle identifier stem (`<term>.macos`) becomes the committed neutral stem
  `com.example.cpa` (so the old `<term>.macos` becomes `com.example.cpa.macos`, the scripts'
  default), every other term `REDACTED`.

The printed steps, in this order (the owner runs them before the repository is public):

1. `brew install git-filter-repo` (it is not installed on the development Mac).
2. `git clone --bare --no-local <this repo> "$WORK/rewrite.git"` in a fresh temporary directory.
   A bare copy of the LOCAL repository holds every local branch, including
   `codex/oases-open-edition`, which is not on GitHub yet; cloning a mirror from GitHub would
   miss it.
3. `git filter-repo --mailmap … --replace-text … --replace-message … --replace-refs delete-no-add`
   inside that copy only.
4. Rescan: `git log --all --format='%ae %ce' | sort -u` shows only noreply addresses, and in a
   checkout of the rewritten copy
   `OASES_PRIVATE_TERMS_FILE=<terms file> bash script/check-no-private.sh --history --require-private-terms`
   exits 0.
5. Commit ids change, so `f0f2500` no longer exists: the printed `awk` reads its new id from
   `filter-repo/commit-map`. The first commit after the rewrite has to change the base in
   `.github/workflows/private-scan.yml` (or switch CI to `--history`, which is clean then).
6. Only then, and only by the owner: `git remote add origin …` and
   `git push --force --mirror origin` (printed as comments, never run by a script). Afterwards
   work from a fresh clone; the old work tree keeps the old history and must never be pushed
   again.

Not verified here: `git-filter-repo` itself (not installed; the options are taken from its
documentation). What was checked: applying the replace-text rules to the text of
`git log -p --all` and scanning the result leaves no `private-term` finding (before: 28 in that
text, counting removed lines; after: 0).

## 5. Before publishing

- `README.md` states the network behaviour of the deployed programs (engine update lookups,
  the gateway's model catalog) and what the engine's usage queue carries.
- No push, tag or release is made from this work tree by an implementer; merging and publishing
  are the owner's decisions.
