#!/usr/bin/env bash
#
# check_xcodeproj_membership.sh - the generated Xcode project must match the sources.
#
# Every Swift file under Sources/ and Tests/ must be referenced by
# OasesCPA.xcodeproj/project.pbxproj as `path = <name>;` (xcodegen quotes names that hold
# characters such as "+": `path = "<name>";`), and the project must not pin a development
# team (the team is build-time configuration, see Config/Base.xcconfig). Run
# `xcodegen generate` after adding or removing Swift files. Needs bash 3.2.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
PBXPROJ="$ROOT/OasesCPA.xcodeproj/project.pbxproj"
[ -f "$PBXPROJ" ] || { echo "missing OasesCPA.xcodeproj/project.pbxproj" >&2; exit 1; }

failures=0
checked=0
while IFS= read -r -d '' file; do
  name=$(basename "$file")
  checked=$((checked + 1))
  if ! LC_ALL=C grep -qF -e "path = $name;" -e "path = \"$name\";" "$PBXPROJ"; then
    echo "not in the Xcode project: ${file#"$ROOT"/}"
    failures=$((failures + 1))
  fi
done < <(find "$ROOT/Sources" "$ROOT/Tests" -type f -name '*.swift' -print0 | LC_ALL=C sort -z)

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
echo "xcodeproj membership: $checked Swift files referenced, no pinned team"
