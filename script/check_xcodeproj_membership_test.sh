#!/usr/bin/env bash
#
# check_xcodeproj_membership_test.sh - tests of script/check_xcodeproj_membership.sh.
#
# Synthetic repositories under $OASES_SCRATCH (left in place), each with a copy of the check
# and a small hand-written project.pbxproj in the layout xcodegen writes (groups with `path`,
# `<group>`-relative file references). Checks: a matching project passes; a Swift file whose
# NAME is in the project but in another folder fails; a reference to a file that no longer
# exists fails; a name xcodegen quotes ("A+B.swift") passes; a pinned team fails without
# printing its value. Needs bash 3.2, plutil, python3.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
OASES_SCRATCH=${OASES_SCRATCH:-${TMPDIR:-/tmp}/oases-b-scratch}
mkdir -p "$OASES_SCRATCH" || { echo "cannot create $OASES_SCRATCH" >&2; exit 1; }
WORK=$(mktemp -d "$OASES_SCRATCH/membership-test.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
expect_status() { # <name> <expected> <actual>
  if [ "$3" -eq "$2" ]; then ok "$1"; else not_ok "$1 (expected exit $2, got $3)"; fi
}
expect_contains() { # <name> <haystack> <needle>
  case $2 in *"$3"*) ok "$1" ;; *) not_ok "$1: $2" ;; esac
}
expect_not_contains() { # <name> <haystack> <needle>
  case $2 in *"$3"*) not_ok "$1: $2" ;; *) ok "$1" ;; esac
}

# <dir> <extra build settings line or empty>: a repository whose project references
# Sources/App/Views/Main.swift, Sources/App/Models/A+B.swift (quoted), Sources/App/Info.plist
# and Tests/AppTests/MainTests.swift.
new_repo() {
  local dir="$1" settings="$2"
  mkdir -p "$dir/script" "$dir/OasesCPA.xcodeproj" "$dir/Sources/App/Views" "$dir/Sources/App/Models" "$dir/Tests/AppTests"
  cp "$REPO/script/check_xcodeproj_membership.sh" "$dir/script/"
  printf 'struct Main {}\n' > "$dir/Sources/App/Views/Main.swift"
  printf 'struct AB {}\n' > "$dir/Sources/App/Models/A+B.swift"
  printf '<plist/>\n' > "$dir/Sources/App/Info.plist"
  printf 'struct MainTests {}\n' > "$dir/Tests/AppTests/MainTests.swift"
  cat > "$dir/OasesCPA.xcodeproj/project.pbxproj" <<EOF
// !\$*UTF8*\$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {
		F001 /* Main.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Main.swift; sourceTree = "<group>"; };
		F002 /* A+B.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "A+B.swift"; sourceTree = "<group>"; };
		F003 /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist; path = Info.plist; sourceTree = "<group>"; };
		F004 /* MainTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MainTests.swift; sourceTree = "<group>"; };
		F005 /* App.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; path = App.app; sourceTree = BUILT_PRODUCTS_DIR; };
		G000 = {
			isa = PBXGroup;
			children = (
				G001 /* Sources */,
				G005 /* Tests */,
				G006 /* Products */,
			);
			sourceTree = "<group>";
		};
		G001 /* Sources */ = {
			isa = PBXGroup;
			children = (
				G002 /* App */,
			);
			path = Sources;
			sourceTree = "<group>";
		};
		G002 /* App */ = {
			isa = PBXGroup;
			children = (
				G003 /* Views */,
				G004 /* Models */,
				F003 /* Info.plist */,
			);
			path = App;
			sourceTree = "<group>";
		};
		G003 /* Views */ = {
			isa = PBXGroup;
			children = (
				F001 /* Main.swift */,
			);
			path = Views;
			sourceTree = "<group>";
		};
		G004 /* Models */ = {
			isa = PBXGroup;
			children = (
				F002 /* A+B.swift */,
			);
			path = Models;
			sourceTree = "<group>";
		};
		G005 /* Tests */ = {
			isa = PBXGroup;
			children = (
				F004 /* MainTests.swift */,
			);
			path = Tests/AppTests;
			sourceTree = "<group>";
		};
		G006 /* Products */ = {
			isa = PBXGroup;
			children = (
				F005 /* App.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
		P000 /* Project object */ = {
			isa = PBXProject;
			buildConfigurationList = C000;
			mainGroup = G000;
			productRefGroup = G006 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
			);
		};
		C000 = {
			isa = XCConfigurationList;
			buildConfigurations = (
				B000 /* Debug */,
			);
		};
		B000 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				SWIFT_VERSION = 6.0;$settings
			};
			name = Debug;
		};
	};
	rootObject = P000 /* Project object */;
}
EOF
}

check() { (bash "$1/script/check_xcodeproj_membership.sh" 2>&1); }

# 1. A matching project passes (a quoted name included; products are not files on disk).
R1="$WORK/match"
new_repo "$R1" ""
out=$(check "$R1"); status=$?
expect_status "a matching project passes" 0 "$status"
expect_contains "it counts the Swift files" "$out" "3 Swift files"

# 2. The same NAME in another folder is not a reference.
R2="$WORK/duplicate-name"
new_repo "$R2" ""
mkdir -p "$R2/Sources/App/Legacy"
printf 'struct Main2 {}\n' > "$R2/Sources/App/Legacy/Main.swift"
out=$(check "$R2"); status=$?
expect_status "a same-named file in another folder fails" 1 "$status"
expect_contains "it names that path" "$out" "not in the Xcode project: Sources/App/Legacy/Main.swift"
expect_not_contains "the referenced file is not reported" "$out" "not in the Xcode project: Sources/App/Views/Main.swift"

# 3. A reference to a file that no longer exists.
R3="$WORK/stale"
new_repo "$R3" ""
mkdir -p "$WORK/stale-trash"
mv "$R3/Sources/App/Info.plist" "$WORK/stale-trash/Info.plist"
out=$(check "$R3"); status=$?
expect_status "a stale reference fails" 1 "$status"
expect_contains "it names the missing file" "$out" "the Xcode project references a missing file: Sources/App/Info.plist"

# 4. A moved Swift file: the old path is stale and the new one is missing.
R4="$WORK/moved"
new_repo "$R4" ""
mkdir -p "$R4/Sources/App/Screens"
mv "$R4/Sources/App/Views/Main.swift" "$R4/Sources/App/Screens/Main.swift"
out=$(check "$R4"); status=$?
expect_status "a moved file fails" 1 "$status"
expect_contains "the new path is reported" "$out" "not in the Xcode project: Sources/App/Screens/Main.swift"
expect_contains "the old path is reported" "$out" "missing file: Sources/App/Views/Main.swift"

# 5. A pinned development team fails; the value is not printed.
TEAM=$(printf '%s%s' ABCDE 12345)
R5="$WORK/team"
new_repo "$R5" "
				DEVELOPMENT_TEAM = $TEAM;"
out=$(check "$R5"); status=$?
expect_status "a pinned team fails" 1 "$status"
expect_contains "it says so" "$out" "pins a development team in 1 place(s)"
expect_not_contains "the team value is not printed" "$out" "$TEAM"

# 6. The real project passes.
out=$(bash "$REPO/script/check_xcodeproj_membership.sh" 2>&1); status=$?
expect_status "this repository's project passes" 0 "$status"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
