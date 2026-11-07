#!/usr/bin/env bash
#
# check-no-private.sh - fail when text that must never be published is present.
#
# Usage:
#   script/check-no-private.sh [--tree] [--history] [--dir <path>] [--stdin]
#                              [--require-private-terms]
#
# Modes (without any mode, --tree and --history both run):
#   --tree     the files listed by `git ls-files -co --exclude-standard`
#   --history  the full text of `git log -p --all` (commit messages and added lines), plus
#              the author and committer email of every commit
#   --dir P    every file under directory P (for release packages); a .git directory is skipped
#   --stdin    the text on standard input (for `git diff --cached` and commit messages);
#              it is used on its own and cannot be combined with another mode
#   --require-private-terms
#              exit 2 when the private terms file is missing or holds no term
#
# Output: one line per finding on stdout,
#   <location>:<line>: <rule>: <first 3 characters>…(<length>)
# A finding is never printed in full. A hit of 3 characters or fewer shows one character less
# than its length, so that it is never printed in full either. Exit status: 0 nothing found,
# 1 findings, 2 usage or configuration error.
#
# Rules:
#   secret-token   API keys and tokens (OpenAI style, GitHub, AWS, Slack, Google); an sk- token
#                  must not sit inside a word, so risk-assessment-and-the-like is not one
#   pem-block      a PEM block header
#   cert-der       base64 of a DER certificate
#   email          an email address; a name such as icon_16x16@2x.png (the part after the "@"
#                  ends in an image or document extension) is not an address
#   public-ipv4    a public IPv4 address; reserved, private, loopback, link-local, shared and
#                  documentation ranges, versions (v1.2.3.4, 1.2.3.4.5) and numbers with a
#                  segment above 255 are not
#   user-home      a macOS home directory path
#   apple-team-id  an Apple developer team identifier
#   private-term   a literal from the private terms file
#   author-email   (--history only) a commit author or committer email that is not allowlisted
# Binary files are not scanned; a symlink is scanned through the text of its target.
#
# Private terms: ${OASES_PRIVATE_TERMS_FILE:-script/private-terms.local}, one literal per
# line, case-insensitive, "#" starts a comment. The file stays out of version control.
#
# Allowlist: script/private-allowlist.txt, one entry per line:
#   <path glob><TAB><ERE><TAB><reason>
# It applies to every rule and every entry needs a reason (an empty reason exits 2). The glob
# is matched against the path with shell `case` rules (a "*" also matches "/"). Paths are
# repository relative; for --dir they are relative to that directory; the pseudo paths are
# <stdin>, (message), (author) and (committer). The ERE (grep -E) has to match text on the
# offending line that includes the finding: an entry silences exactly what it names.
# Lines starting with "#" are comments.
#
# Relative file names are resolved from the top level of the git work tree (the current
# directory outside a repository). Needs bash 3.2, git, grep -E, awk, sed and sort.

set -u

# Ignore exported shell functions that could shadow the tools used below.
unset -f awk cat find git grep mktemp readlink sed sort tr wc 2>/dev/null

PROG=check-no-private
TAB=$'\t'
export GIT_OPTIONAL_LOCKS=0

usage() {
  cat <<'EOF'
Usage: check-no-private.sh [--tree] [--history] [--dir <path>] [--stdin]
                           [--require-private-terms]

Scans for secrets and private strings. Without a mode, --tree and --history both run.
  --tree                   files listed by git ls-files -co --exclude-standard
  --history                git log -p --all, plus author and committer emails
  --dir <path>             every file under a directory (release packages)
  --stdin                  text on standard input; cannot be combined with another mode
  --require-private-terms  exit 2 when the private terms file is missing or empty
Exit status: 0 nothing found, 1 findings, 2 usage or configuration error.
EOF
}

die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 2
}

note() {
  printf '%s: note: %s\n' "$PROG" "$*" >&2
}

usage_error() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  usage >&2
  exit 2
}

# --- arguments -------------------------------------------------------------------------------

MODE_TREE=0
MODE_HISTORY=0
MODE_STDIN=0
HAVE_DIR=0
DIR_ARG=
REQUIRE_TERMS=0

while [ $# -gt 0 ]; do
  case $1 in
    --tree) MODE_TREE=1 ;;
    --history) MODE_HISTORY=1 ;;
    --stdin) MODE_STDIN=1 ;;
    --require-private-terms) REQUIRE_TERMS=1 ;;
    --dir)
      [ $# -ge 2 ] || usage_error "--dir needs a path"
      [ "$HAVE_DIR" -eq 0 ] || usage_error "--dir was given more than once"
      HAVE_DIR=1
      DIR_ARG=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) usage_error "unknown argument: $1" ;;
  esac
  shift
done

if [ "$MODE_STDIN" -eq 1 ] && [ $((MODE_TREE + MODE_HISTORY + HAVE_DIR)) -gt 0 ]; then
  usage_error "--stdin cannot be combined with another scan mode"
fi
if [ "$MODE_STDIN" -eq 0 ] && [ $((MODE_TREE + MODE_HISTORY + HAVE_DIR)) -eq 0 ]; then
  MODE_TREE=1
  MODE_HISTORY=1
fi

if [ "$HAVE_DIR" -eq 1 ] && [ ! -d "$DIR_ARG" ]; then
  die "not a directory: $DIR_ARG"
fi

command -v git >/dev/null 2>&1 || die "git is required"

if ROOT=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$ROOT" ]; then
  IN_REPO=1
else
  ROOT=$PWD
  IN_REPO=0
fi
if [ "$IN_REPO" -eq 0 ] && [ $((MODE_TREE + MODE_HISTORY)) -gt 0 ]; then
  die "not inside a git repository (use --dir <path> to scan a plain directory)"
fi

TERMS_FILE=${OASES_PRIVATE_TERMS_FILE:-$ROOT/script/private-terms.local}
ALLOW_FILE=$ROOT/script/private-allowlist.txt

# --- scratch space ---------------------------------------------------------------------------
# The scratch copies hold scanned text, including unmasked findings. They are removed on every
# exit: a copy of the repository must not pile up in the temp directory (or in a trash folder).

TMP=
cleanup() {
  if [ -n "$TMP" ] && [ -d "$TMP" ]; then
    rm -rf -- "$TMP"
  fi
}
trap cleanup EXIT
trap 'exit 2' HUP INT TERM
TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-no-private.XXXXXX") || die "cannot create a temporary directory"

CONTENT=$TMP/content # every scanned line, one per line
INDEX=$TMP/index     # <first content line> TAB <path for the allowlist> TAB <location> TAB <line>
HITS=$TMP/hits
: >"$CONTENT"
: >"$INDEX"
: >"$HITS"
CN=0 # number of lines in $CONTENT
SCAN_ERR=0
FOUND=0

# --- configuration: allowlist and private terms ------------------------------------------------

ALLOW_N=0
AL_GLOB=()
AL_ERE=()

load_allowlist() {
  [ -f "$ALLOW_FILE" ] || return 0
  local shown=${ALLOW_FILE#"$ROOT"/} lineno=0 line glob rest ere reason
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    case $line in
      '' | '#'*) continue ;;
      *[![:space:]]*) ;;
      *) continue ;;
    esac
    case $line in
      *"$TAB"*"$TAB"*) ;;
      *) die "$shown:$lineno: expected <path glob><TAB><ERE><TAB><reason>" ;;
    esac
    glob=${line%%"$TAB"*}
    rest=${line#*"$TAB"}
    ere=${rest%%"$TAB"*}
    reason=${rest#*"$TAB"}
    reason=${reason#"${reason%%[![:space:]]*}"}
    reason=${reason%"${reason##*[![:space:]]}"}
    [ -n "$glob" ] || die "$shown:$lineno: the path glob is empty"
    [ -n "$ere" ] || die "$shown:$lineno: the pattern is empty"
    [ -n "$reason" ] || die "$shown:$lineno: every allowlist entry needs a reason"
    printf '' | LC_ALL=C grep -E "--regexp=$ere" >/dev/null 2>&1
    [ $? -le 1 ] || die "$shown:$lineno: the pattern is not a valid extended regular expression"
    AL_GLOB[$ALLOW_N]=$glob
    AL_ERE[$ALLOW_N]=$ere
    ALLOW_N=$((ALLOW_N + 1))
  done <"$ALLOW_FILE"
}

HAVE_TERMS=0

load_terms() {
  local shown=${TERMS_FILE#"$ROOT"/}
  if [ -f "$TERMS_FILE" ]; then
    LC_ALL=C awk '
      { sub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
      $0 == "" || substr($0, 1, 1) == "#" { next }
      { print }
    ' "$TERMS_FILE" >"$TMP/terms" || die "cannot read the private terms file: $shown"
    if [ -s "$TMP/terms" ]; then
      HAVE_TERMS=1
      return 0
    fi
    if [ "$REQUIRE_TERMS" -eq 1 ]; then
      die "private terms are required but $shown holds no term"
    fi
    note "$shown holds no term; the private-term rule is skipped"
    return 0
  fi
  if [ "$REQUIRE_TERMS" -eq 1 ]; then
    die "private terms are required but $shown is missing"
  fi
  note "$shown not found; the private-term rule is skipped"
}

load_allowlist
load_terms

# --- building the text to scan -----------------------------------------------------------------
# Every source is flattened into $CONTENT (one scanned line per line) with $INDEX recording
# which path, location and line number each stretch of lines came from.

cannot_read() {
  printf '%s: cannot read %s\n' "$PROG" "$1" >&2
  SCAN_ERR=1
}

# corpus_add_file <file> <path for the allowlist> <location> <grep flag: -I skips binary, -a not>
corpus_add_file() {
  local src=$1 m=$2 d=$3 flag=$4 count target rc
  m=${m//[$'\t\n']/?}
  d=${d//[$'\t\n']/?}
  if [ -L "$src" ]; then
    target=$(readlink "$src") || {
      cannot_read "$d"
      return 0
    }
    printf '%s\n' "$target" >>"$CONTENT"
    count=1
  elif [ -f "$src" ]; then
    count=$(LC_ALL=C grep "$flag" -c '' -- "$src" 2>/dev/null)
    rc=$?
    if [ "$rc" -gt 1 ]; then
      cannot_read "$d"
      return 0
    fi
    [ "${count:-0}" -gt 0 ] || return 0
    LC_ALL=C grep "$flag" -h '' -- "$src" >>"$CONTENT" 2>/dev/null
  else
    return 0
  fi
  printf '%s\t%s\t%s\t%s\n' $((CN + 1)) "$m" "$d" 1 >>"$INDEX"
  CN=$((CN + count))
}

collect_stdin() {
  cat >"$TMP/stdin.in" || die "cannot read standard input"
  corpus_add_file "$TMP/stdin.in" '<stdin>' '<stdin>' -a
}

collect_tree() {
  local p
  git -C "$ROOT" ls-files -z --cached --others --exclude-standard >"$TMP/tree.lst" ||
    die "git ls-files failed"
  while IFS= read -r -d '' p; do
    corpus_add_file "$ROOT/$p" "$p" "$p" -I
  done <"$TMP/tree.lst"
}

collect_dir() {
  local abs shown p rel
  abs=$(cd "$DIR_ARG" 2>/dev/null && pwd -P) || die "not a directory: $DIR_ARG"
  shown=${DIR_ARG%/}
  find "$abs" -name .git -prune -o \( -type f -o -type l \) -print >"$TMP/dir.lst" ||
    die "cannot list $DIR_ARG"
  LC_ALL=C sort -o "$TMP/dir.lst" "$TMP/dir.lst"
  while IFS= read -r p; do
    rel=${p#"$abs"/}
    if [ ! -f "$p" ] && [ ! -L "$p" ]; then
      cannot_read "$p"
      continue
    fi
    if [ "$shown" = . ]; then
      corpus_add_file "$p" "$rel" "$rel" -I
    else
      corpus_add_file "$p" "$rel" "$shown/$rel" -I
    fi
  done <"$TMP/dir.lst"
}

# Flattens `git log -p -U0` (see collect_history for the format) into $CONTENT and $INDEX.
HISTORY_AWK='
function clean(p) {
  sub(/\t.*$/, "", p)
  if (substr(p, 1, 2) == "a/" || substr(p, 1, 2) == "b/") p = substr(p, 3)
  return p
}
function segment(path, first) {
  printf "%d\t%s\t%s:%s\t%d\n", cn + 1, path, sha7, path, first >> idxfile
}
function put(text) {
  print text >> cfile
  cn++
}
BEGIN {
  cn = cn0 + 0
  start = cn
  cfile = ENVIRON["CHECK_CONTENT"]
  idxfile = ENVIRON["CHECK_INDEX"]
  state = 0
}
substr($0, 1, 3) == "\001C " {
  sha7 = substr($0, 4, 7)
  state = 1
  opened = 0
  next
}
state == 1 {
  p = index($0, "\001E")
  if (p != 1) {
    if (!opened) {
      segment("(message)", 1)
      opened = 1
    }
    put(p == 0 ? $0 : substr($0, 1, p - 1))
  }
  if (p > 0) {
    state = 2
    hdr = 0
  }
  next
}
state == 2 {
  if (substr($0, 1, 11) == "diff --git ") {
    hdr = 1
    path = ""
    oldpath = ""
    opened = 0
    next
  }
  if (substr($0, 1, 3) == "@@ ") {
    hdr = 0
    opened = 0
    ln = match($0, /\+[0-9]+/) ? substr($0, RSTART + 1, RLENGTH - 1) + 0 : 1
    next
  }
  if (hdr) {
    if (substr($0, 1, 4) == "--- ") oldpath = substr($0, 5)
    else if (substr($0, 1, 4) == "+++ ") path = substr($0, 5)
    next
  }
  if (substr($0, 1, 1) == "+") {
    if (!opened) {
      segment(clean(path == "/dev/null" ? oldpath : path), ln)
      opened = 1
    }
    put(substr($0, 2))
  }
  next
}
END { print cn - start }
'

# Every added line and every commit message of every commit on every ref. The format puts the
# message between SOH marks so that it can be told apart from the patch; -U0 leaves only added
# and removed lines, and removed lines were scanned when they were added. The options pin the
# output against user configuration (prefixes, renames, textconv, color, signatures, root).
#
# Attributes (a .gitattributes with "-diff" or "binary", common for Xcode projects) make
# `git log -p` print "Binary files differ" instead of the text, which would hide the history.
# The empty tree as attribute source ignores the ones in the work tree (git 2.40 and newer,
# found by probing); an older git falls back to --text. A global or system attributes file
# is switched off too. The one source left is .git/info/attributes of this very clone, which
# only its owner can create.
#
# NUL bytes (git calls a file text unless its first 8000 bytes hold a NUL) become spaces
# before awk reads the log: awk would stop a line at a NUL and drop what follows.
collect_history() {
  local added empty attr_opt= text_opt=
  empty=$(git -C "$ROOT" hash-object -t tree /dev/null 2>/dev/null)
  if [ -n "$empty" ] &&
    git -C "$ROOT" --attr-source="$empty" rev-parse --git-dir >/dev/null 2>&1; then
    attr_opt=--attr-source=$empty
  else
    text_opt=--text
  fi
  GIT_ATTR_NOSYSTEM=1 git -C "$ROOT" ${attr_opt:+"$attr_opt"} -c core.quotepath=off \
    -c core.attributesFile=/dev/null log --all --root -p -U0 --no-color --no-ext-diff \
    --no-textconv --no-renames --no-show-signature --src-prefix=a/ --dst-prefix=b/ \
    ${text_opt:+"$text_opt"} --format='%x01C %H%n%B%x01E' >"$TMP/history.log" ||
    die "git log failed"
  LC_ALL=C tr '\000' ' ' <"$TMP/history.log" >"$TMP/history.txt" ||
    die "cannot read the git history"
  added=$(CHECK_CONTENT=$CONTENT CHECK_INDEX=$INDEX LC_ALL=C awk -v cn0="$CN" \
    "$HISTORY_AWK" "$TMP/history.txt") || die "cannot read the git history"
  CN=$((CN + added))
}

if [ "$MODE_STDIN" -eq 1 ]; then collect_stdin; fi
if [ "$MODE_TREE" -eq 1 ]; then collect_tree; fi
if [ "$HAVE_DIR" -eq 1 ]; then collect_dir; fi
if [ "$MODE_HISTORY" -eq 1 ]; then collect_history; fi

actual=$(wc -l <"$CONTENT" | tr -d ' ')
[ "$actual" -eq "$CN" ] || die "the text being scanned changed during the scan; run it again"

# The scanned text is text by construction: NUL bytes (piped input, files that git or grep
# still treat as text) become spaces, so that no tool below stops at one or answers with
# "binary file matches" instead of the findings. Line numbers do not change.
LC_ALL=C tr '\000' ' ' <"$CONTENT" >"$TMP/content.text" || die "cannot prepare the scanned text"
CONTENT=$TMP/content.text

# --- rules -------------------------------------------------------------------------------------
# Patterns that would match their own source text are written in pieces.

RE_SECRET='(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}'
RE_PEM='-----BEGIN [A-Z0-9 ]+-----'
RE_DER='MII[A-Za-z0-9+/]{60,}'
RE_EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
RE_IPV4='[vV]?[0-9]+(\.[0-9]+){3,}'
RE_HOME='/Use''rs/[^/ ]+'
RE_TEAM='DEVELOPMENT_TEAM *= *[A-Z0-9]{10}|team_id"? *[:=] *"?[A-Z0-9]{10}'

# Turns `grep -n -o` output (<line>:<match>) into <line> TAB <rule order> TAB <rule> TAB <match>,
# dropping what the rule itself exempts.
FILTER_AWK='
function public_ipv4(s,   p, n, i, a, b, c, d) {
  if (s ~ /^[vV]/) return 0
  n = split(s, p, ".")
  if (n != 4) return 0
  for (i = 1; i <= 4; i++) {
    if (length(p[i]) > 3) return 0
    p[i] += 0
    if (p[i] > 255) return 0
  }
  a = p[1]; b = p[2]; c = p[3]; d = p[4]
  if (a == 0 && b == 0 && c == 0 && d == 0) return 0
  if (a == 255 && b == 255 && c == 255 && d == 255) return 0
  if (a == 127 || a == 10) return 0
  if (a == 172 && b >= 16 && b <= 31) return 0
  if (a == 192 && b == 168) return 0
  if (a == 169 && b == 254) return 0
  if (a == 100 && b >= 64 && b <= 127) return 0
  if (a == 192 && b == 0 && c == 2) return 0
  if (a == 198 && b == 51 && c == 100) return 0
  if (a == 203 && b == 0 && c == 113) return 0
  return 1
}
{
  i = index($0, ":")
  n = substr($0, 1, i - 1)
  if (i < 2 || n !~ /^[0-9]+$/) exit 2
  f = substr($0, i + 1)
  if (rule == "secret-token") {
    # The sk- pattern carries the character in front of it (its left boundary); drop it.
    if (f ~ /^[^A-Za-z0-9]/) f = substr(f, 2)
  } else if (rule == "email") {
    k = f
    sub(/^.*\./, "", k)
    if (tolower(k) ~ /^(png|jpe?g|gif|svg|webp|heic|pdf|ico|icns)$/) next
  } else if (rule == "public-ipv4") {
    if (!public_ipv4(f)) next
  }
  printf "%s\t%s\t%s\t%s\n", n, ord, rule, f
}
'

# scan_rule <rule> <order> <grep options...>
scan_rule() {
  local rule=$1 ord=$2 rc
  shift 2
  LC_ALL=C grep -a -n -o "$@" "$CONTENT" >"$TMP/grep.out"
  rc=$?
  [ "$rc" -le 1 ] || die "grep failed while applying the $rule rule"
  [ -s "$TMP/grep.out" ] || return 0
  LC_ALL=C awk -v rule="$rule" -v ord="$ord" "$FILTER_AWK" "$TMP/grep.out" >>"$HITS" ||
    die "awk failed while applying the $rule rule"
}

# --- reporting -----------------------------------------------------------------------------------

# mask <text>: the first 3 characters and the length, never the whole text.
mask() {
  local s=$1 len keep
  len=${#s}
  if [ "$len" -gt 3 ]; then
    keep=3
  elif [ "$len" -gt 0 ]; then
    keep=$((len - 1))
  else
    keep=0
  fi
  printf '%s…(%d)' "${s:0:$keep}" "$len"
}

# is_allowed <path> <finding> <content line, or 0> <text when no content line>
is_allowed() {
  local i=0 glob ere text= have_text=0 covered
  while [ "$i" -lt "$ALLOW_N" ]; do
    glob=${AL_GLOB[$i]}
    ere=${AL_ERE[$i]}
    i=$((i + 1))
    case $1 in
      $glob) ;;
      *) continue ;;
    esac
    if [ "$have_text" -eq 0 ]; then
      if [ "$3" -gt 0 ]; then
        text=$(LC_ALL=C sed -n -e "${3}p" -e "${3}q" "$CONTENT")
      else
        text=$4
      fi
      have_text=1
    fi
    while IFS= read -r covered; do
      case $covered in
        *"$2"*) return 0 ;;
      esac
    done < <(printf '%s\n' "$text" | LC_ALL=C grep -a -o -E "--regexp=$ere")
  done
  return 1
}

# emit <path> <location> <line> <rule> <finding> <content line, or 0> <text when no content line>
emit() {
  if [ "$ALLOW_N" -gt 0 ] && is_allowed "$1" "$5" "$6" "$7"; then
    return 0
  fi
  printf '%s:%s: %s: %s\n' "$2" "$3" "$4" "$(mask "$5")"
  FOUND=$((FOUND + 1))
}

# resolve <content line>: sets R_MATCH, R_DISPLAY and R_LINE from the index.
resolve() {
  local rec
  rec=$(LC_ALL=C awk -F'\t' -v n="$1" '
    $1 + 0 > n { exit }
    { m = $2; d = $3; s = $1 + 0; f = $4 + 0 }
    END { printf "%s\t%s\t%d\n", m, d, f + n - s }
  ' "$INDEX")
  R_MATCH=${rec%%"$TAB"*}
  rec=${rec#*"$TAB"}
  R_DISPLAY=${rec%%"$TAB"*}
  R_LINE=${rec#*"$TAB"}
}

report_hits() {
  local rec n rule frag
  [ -s "$HITS" ] || return 0
  LC_ALL=C sort -t "$TAB" -k1,1n -k2,2n "$HITS" >"$TMP/hits.sorted"
  while IFS= read -r rec; do
    n=${rec%%"$TAB"*}
    rec=${rec#*"$TAB"}
    rec=${rec#*"$TAB"}
    rule=${rec%%"$TAB"*}
    frag=${rec#*"$TAB"}
    resolve "$n"
    emit "$R_MATCH" "$R_DISPLAY" "$R_LINE" "$rule" "$frag" "$n" ''
  done <"$TMP/hits.sorted"
}

# Each distinct author and committer email is reported once, with the newest commit that uses it.
report_identities() {
  local rec role sha email
  git -C "$ROOT" log --all --format='%H%x09%ae%x09%ce' >"$TMP/idents" || die "git log failed"
  LC_ALL=C awk -F'\t' '
    $2 != "" && !(("a" $2) in seen) { seen["a" $2] = 1; print "author\t" substr($1, 1, 7) "\t" $2 }
    $3 != "" && !(("c" $3) in seen) { seen["c" $3] = 1; print "committer\t" substr($1, 1, 7) "\t" $3 }
  ' "$TMP/idents" >"$TMP/idents.uniq" || die "cannot read the git history"
  while IFS= read -r rec; do
    role=${rec%%"$TAB"*}
    rec=${rec#*"$TAB"}
    sha=${rec%%"$TAB"*}
    email=${rec#*"$TAB"}
    emit "($role)" "$sha:$role" 1 author-email "$email" 0 "$email"
  done <"$TMP/idents.uniq"
}

if [ "$CN" -gt 0 ]; then
  scan_rule secret-token 1 -E "--regexp=$RE_SECRET"
  scan_rule pem-block 2 -E "--regexp=$RE_PEM"
  scan_rule cert-der 3 -E "--regexp=$RE_DER"
  scan_rule email 4 -E "--regexp=$RE_EMAIL"
  scan_rule public-ipv4 5 -E "--regexp=$RE_IPV4"
  scan_rule user-home 6 -E "--regexp=$RE_HOME"
  scan_rule apple-team-id 7 -E "--regexp=$RE_TEAM"
  if [ "$HAVE_TERMS" -eq 1 ]; then
    scan_rule private-term 8 -i -F -f "$TMP/terms"
  fi
  report_hits
fi
if [ "$MODE_HISTORY" -eq 1 ]; then
  report_identities
fi

if [ "$FOUND" -gt 0 ]; then
  printf '%s: %d finding(s)\n' "$PROG" "$FOUND" >&2
  exit 1
fi
if [ "$SCAN_ERR" -ne 0 ]; then
  die "some files could not be read; the scan is incomplete"
fi
exit 0
