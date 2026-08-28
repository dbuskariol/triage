#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor/GRDB.swift"
EXPECTED_GRDB_SOURCE_HASH="a884ed4d3fe5cf382e34e1f6e162ca57a4c4ca00f07d8e37fca988c439fda6cf"
EXPECTED_SQLCIPHER_REVISION="f879fffaaa3ad3541a77830daad4a28726dfa927"
XCODE_LOCK="$ROOT_DIR/Triage.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SWIFTPM_LOCK="$ROOT_DIR/Package.resolved"

fail() {
  printf 'Vendored dependency verification failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "$VENDOR_DIR/LICENSE" ]] || fail 'GRDB upstream license is missing'
[[ -f "$VENDOR_DIR/Package.swift" ]] || fail 'GRDB package manifest is missing'
/usr/bin/grep -Fq 'url: "https://github.com/sqlcipher/SQLCipher.swift.git"' "$VENDOR_DIR/Package.swift" \
  || fail 'GRDB is not linked to SQLCipher.swift'
/usr/bin/grep -Fq '.define("SQLITE_HAS_CODEC")' "$VENDOR_DIR/Package.swift" \
  || fail 'GRDB is not compiled with SQLCipher support'
/usr/bin/grep -Fq '.define("SQLCipher")' "$VENDOR_DIR/Package.swift" \
  || fail 'GRDB does not import SQLCipher'
/usr/bin/grep -Fq 'name: "GRDBSQLCipher"' "$VENDOR_DIR/Package.swift" \
  || fail 'GRDB SQLCipher bridge is missing'
[[ ! -e "$VENDOR_DIR/Sources/GRDBSQLite" ]] \
  || fail 'GRDB system SQLite bridge must not ship beside SQLCipher'

SOURCE_HASH="$(
  (
    cd "$VENDOR_DIR"
    /usr/bin/find GRDB Sources -type f -print0 \
    | LC_ALL=C /usr/bin/sort -z \
    | /usr/bin/xargs -0 /usr/bin/shasum -a 256 \
    | /usr/bin/shasum -a 256 \
    | /usr/bin/awk '{print $1}'
  )
)"
[[ "$SOURCE_HASH" == "$EXPECTED_GRDB_SOURCE_HASH" ]] \
  || fail 'GRDB upstream source fingerprint does not match the reviewed baseline'

for lock_file in "$XCODE_LOCK" "$SWIFTPM_LOCK"; do
  [[ -f "$lock_file" ]] || fail "dependency lockfile is missing: $lock_file"
  /usr/bin/grep -Fq "\"revision\" : \"$EXPECTED_SQLCIPHER_REVISION\"" "$lock_file" \
    || fail "SQLCipher is not revision-locked in $lock_file"
done

printf 'Verified GRDB 7.11.1 with SQLCipher 4.18.0.\n'
