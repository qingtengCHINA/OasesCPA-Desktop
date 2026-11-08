#!/usr/bin/env bash
#
# check_xcodeproj_membership.sh - the generated Xcode project must match the sources.
#
# Compares FULL relative paths, not file names: every Swift file under Sources/ and Tests/ must
# be referenced by OasesCPA.xcodeproj/project.pbxproj at its own path (a file with the same name
# in another folder does not count), and every file the project references (group-relative or
# project-relative) must still exist. The project must not pin a development team either (the
# team is build-time configuration, see Config/Base.xcconfig). Run `xcodegen generate` after
# adding, moving or removing files. Needs bash 3.2, plutil and python3 (both part of the Xcode
# command line tools that xcodegen needs anyway).

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
PBXPROJ="$ROOT/OasesCPA.xcodeproj/project.pbxproj"
[ -f "$PBXPROJ" ] || { echo "missing OasesCPA.xcodeproj/project.pbxproj" >&2; exit 1; }
command -v plutil >/dev/null 2>&1 || { echo "plutil is needed to read the project" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is needed to read the project" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/xcodeproj-membership.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT

# The paths of every file reference, relative to the repository root, one per line: groups
# contribute their `path`, `<group>` references are relative to their group,
# `SOURCE_ROOT` references to the root; products and SDK files are skipped.
if ! plutil -convert json -o "$work/project.json" "$PBXPROJ" 2>/dev/null; then
  echo "the Xcode project cannot be read" >&2
  exit 1
fi
if ! python3 -I -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    project = json.load(handle)
objects = project["objects"]
main_group = objects[project["rootObject"]]["mainGroup"]
paths = []
def visit(identifier, base, seen):
    if identifier in seen or identifier not in objects:
        return
    seen.add(identifier)
    item = objects[identifier]
    tree = item.get("sourceTree")
    path = item.get("path")
    if tree == "SOURCE_ROOT":
        here = path or ""
    elif tree == "<group>":
        here = (base + "/" + path if base else path) if path else base
    else:
        here = None
    kind = item.get("isa")
    if kind in ("PBXGroup", "PBXVariantGroup", "XCVersionGroup"):
        for child in item.get("children", []):
            visit(child, here if here is not None else base, seen)
    elif kind == "PBXFileReference" and here:
        paths.append(here)
visit(main_group, "", set())
for path in sorted(set(paths)):
    print(path)
' "$work/project.json" > "$work/referenced.txt"; then
  echo "the Xcode project cannot be read" >&2
  exit 1
fi

failures=0
checked=0
while IFS= read -r -d '' file; do
  relative=${file#"$ROOT"/}
  checked=$((checked + 1))
  if ! LC_ALL=C grep -qxF -e "$relative" "$work/referenced.txt"; then
    echo "not in the Xcode project: $relative"
    failures=$((failures + 1))
  fi
done < <(find "$ROOT/Sources" "$ROOT/Tests" -type f -name '*.swift' -print0 | LC_ALL=C sort -z)

while IFS= read -r relative; do
  [ -n "$relative" ] || continue
  if [ ! -e "$ROOT/$relative" ]; then
    echo "the Xcode project references a missing file: $relative"
    failures=$((failures + 1))
  fi
done < "$work/referenced.txt"

team_lines=$(LC_ALL=C grep -cE 'DEVELOPMENT_TEAM = [A-Z0-9]{10}' "$PBXPROJ")
if [ "$team_lines" -gt 0 ]; then
  # The value itself is never printed.
  echo "the Xcode project pins a development team in $team_lines place(s); keep it in Config/Local.xcconfig"
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "xcodeproj membership: $failures problem(s) in $checked Swift files; run xcodegen generate" >&2
  exit 1
fi
echo "xcodeproj membership: $checked Swift files referenced at their paths, no missing references, no pinned team"
