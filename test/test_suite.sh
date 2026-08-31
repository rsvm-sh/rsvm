#!/usr/bin/env bash
# test/rsvm_test.sh — rsvm unit tests
# Usage: bash test/rsvm_test.sh

PASS=0; FAIL=0

# ---------- test helpers ----------

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        expected : $expected"
    echo "        actual   : $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" pattern="$2" actual="$3"
  if echo "$actual" | grep -q "$pattern"; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc (pattern not found: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

fake_toolchain() {
  local ver="$1"
  mkdir -p "$RSVM_DIR/versions/$ver/bin"
  printf '#!/bin/sh\necho rustc %s\n' "$ver" > "$RSVM_DIR/versions/$ver/bin/rustc"
  printf '#!/bin/sh\necho cargo %s\n' "$ver" > "$RSVM_DIR/versions/$ver/bin/cargo"
  chmod +x "$RSVM_DIR/versions/$ver/bin/rustc" "$RSVM_DIR/versions/$ver/bin/cargo"
}

# ---------- isolated environment ----------

export RSVM_DIR="$(mktemp -d /tmp/rsvm_test_XXXXXX)"
export RSVM_NO_USE=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Prefer repo source name; fall back to installed name
if [[ -f "$ROOT/rsvm_sh.sh" ]]; then
  source "$ROOT/rsvm_sh.sh"
else
  source "$ROOT/rsvm.sh"
fi
fake_toolchain "1.70.0"
fake_toolchain "1.75.0"

echo "=== rsvm test suite ==="
echo ""

# ---------- alias system ----------
echo "-- alias --"
rsvm alias default 1.75.0
assert_eq "alias write"          "1.75.0" "$(rsvm_get_alias default)"
assert_eq "alias read via rsvm"   "1.75.0" "$(rsvm alias default)"

# ---------- version resolution ----------
echo "-- rsvm_resolve_version --"
assert_eq "resolve default alias"   "1.75.0" "$(rsvm_resolve_version default)"
assert_eq "resolve exact version"   "1.70.0" "$(rsvm_resolve_version 1.70.0)"

# ---------- nvm-style partial alias (latest installed x / x.y) ----------
echo "-- alias partial --"
fake_toolchain "1.75.1"
rsvm alias default 1.75 >/dev/null
assert_eq "alias stores the pattern 1.75" "1.75" "$(rsvm_get_alias default)"
assert_eq "default 1.75 resolves to latest 1.75.x" "1.75.1" "$(rsvm_resolve_version default)"
assert_eq "use-style prefix 1.75 is latest patch" "1.75.1" "$(rsvm_latest_local_matching 1.75)"
assert_eq "prefix 1 is latest installed 1.x" "1.75.1" "$(rsvm_latest_local_matching 1)"

set_out=$(rsvm alias default 1.75 2>&1)
assert_contains "alias set shows resolved version" "(-> 1.75.1)" "$set_out"

rsvm_strip_path
rsvm use 1.75 >/dev/null
assert_contains "rsvm use 1.75 selects latest 1.75.x" "1.75.1" "$PATH"
rsvm_strip_path

warn_out=$(rsvm alias default 9.99 2>&1)
assert_contains "missing prefix warns" "WARNING" "$warn_out"
assert_eq "missing prefix is still stored" "9.99" "$(rsvm_get_alias default)"

rsvm alias default 1.75.0 >/dev/null
assert_eq "restore exact default alias" "1.75.0" "$(rsvm_get_alias default)"
assert_eq "which 1.75 points at latest 1.75.x" \
  "$RSVM_DIR/versions/1.75.1/bin/rustc" "$(rsvm which 1.75)"

# ---------- system + channel tags ----------
echo "-- system / channel --"
assert_eq "1.75.0 is stable" "stable" "$(rsvm_version_channel 1.75.0)"
assert_eq "beta tag" "beta" "$(rsvm_version_channel 1.99.0-beta.3)"
assert_eq "nightly tag" "nightly" "$(rsvm_version_channel 1.100.0-nightly-2026-08-30)"
assert_eq "resolve system" "system" "$(rsvm_resolve_version system)"

rsvm_add_to_path "1.75.0"
assert_eq "current is rsvm version when on PATH" "1.75.0" "$(rsvm current)"
rsvm use system >"$RSVM_DIR/sys.out" 2>&1
sys_out=$(cat "$RSVM_DIR/sys.out")
assert_contains "use system message" "Now using system version of Rust" "$sys_out"
assert_eq "current is system after use system" "system" "$(rsvm current)"
case ":$PATH:" in
  *":$RSVM_DIR/versions/"*) echo "  FAIL  system still has rsvm on PATH"; FAIL=$((FAIL + 1)) ;;
  *) echo "  PASS  use system strips rsvm PATH"; PASS=$((PASS + 1)) ;;
esac

rsvm alias default system >/dev/null
assert_eq "default stores system" "system" "$(rsvm_get_alias default)"
assert_eq "default resolves to system" "system" "$(rsvm_resolve_version default)"
list_out=$(rsvm list 2>&1)
assert_contains "list shows system" "system" "$list_out"
assert_contains "list tags stable channel" "(stable)" "$list_out"
assert_contains "list prints default alias" "default -> system" "$list_out"

if rsvm uninstall system >/dev/null 2>&1; then
  echo "  FAIL  uninstall system should fail"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  cannot uninstall system"
  PASS=$((PASS + 1))
fi
rsvm alias default 1.75.0 >/dev/null

# ---------- local version listing ----------
echo "-- rsvm_local_versions --"
local_list=$(rsvm_local_versions)
assert_contains "lists 1.70.0" "1.70.0" "$local_list"
assert_contains "lists 1.75.0" "1.75.0" "$local_list"

empty_versions=$(mktemp -d)
old_versions_dir="$RSVM_VERSIONS_DIR"
RSVM_VERSIONS_DIR="$empty_versions"
empty_list=$(rsvm_local_versions)
RSVM_VERSIONS_DIR="$old_versions_dir"
rmdir "$empty_versions"
assert_eq "empty versions dir lists nothing" "" "$empty_list"

if command -v zsh >/dev/null 2>&1; then
  zsh_list=$(zsh -c '
    export RSVM_DIR="'"$RSVM_DIR"'"
    source "'"$ROOT"'/rsvm_sh.sh"
    ev=$(mktemp -d)
    RSVM_VERSIONS_DIR="$ev"
    rsvm_local_versions
    rmdir "$ev"
  ' 2>&1)
  if [[ -z "$zsh_list" ]]; then
    echo "  PASS  zsh empty versions dir does not NOMATCH"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  zsh empty versions dir: $zsh_list"
    FAIL=$((FAIL + 1))
  fi
fi

md_versions=$(printf '%s\n' "Version 1.98.0 (2026-08-20)" "not a version" "Version 1.97.1 (2026-07-16)" | rsvm_parse_releases_md)
assert_contains "parse RELEASES.md 1.98.0" "1.98.0" "$md_versions"
assert_contains "parse RELEASES.md 1.97.1" "1.97.1" "$md_versions"

# ---------- install detection ----------
echo "-- rsvm_version_installed --"
rsvm_version_installed "1.70.0" \
  && { echo "  PASS  1.70.0 is installed"; PASS=$((PASS + 1)); } \
  || { echo "  FAIL  1.70.0 should be installed"; FAIL=$((FAIL + 1)); }

rsvm_version_installed "9.99.0" \
  && { echo "  FAIL  9.99.0 should not be installed"; FAIL=$((FAIL + 1)); } \
  || { echo "  PASS  9.99.0 is not installed"; PASS=$((PASS + 1)); }

mkdir -p "$RSVM_DIR/versions/incomplete/bin"
rsvm_version_installed "incomplete" \
  && { echo "  FAIL  dir without rustc should not count as installed"; FAIL=$((FAIL + 1)); } \
  || { echo "  PASS  incomplete install is not treated as installed"; PASS=$((PASS + 1)); }

# ---------- rsvm which ----------
echo "-- rsvm which --"
which_out=$(rsvm which 1.75.0 2>&1)
assert_contains "rsvm which returns correct path" "1.75.0" "$which_out"

# ---------- PATH manipulation ----------
echo "-- shell integration --"
original_path="$PATH"
rsvm_add_to_path "1.75.0"
assert_contains "add_to_path injects version" "1.75.0" "$PATH"
rsvm_strip_path
[[ "$PATH" == "$original_path" ]] \
  && { echo "  PASS  strip_path restores PATH"; PASS=$((PASS + 1)); } \
  || { echo "  FAIL  strip_path did not fully clean PATH"; FAIL=$((FAIL + 1)); }

# ---------- .rust-version file lookup ----------
echo "-- .rust-version file --"
tmpdir=$(mktemp -d)
echo "1.73.0" > "$tmpdir/.rust-version"
pushd "$tmpdir" >/dev/null
found=$(rsvm_find_version_file)
assert_contains ".rust-version file found" ".rust-version" "$found"
from_file=$(rsvm_version_from_file)
assert_eq "read .rust-version" "1.73.0" "$from_file"
printf '# comment\n\n  1.80.0  \n' > "$tmpdir/.rust-version"
assert_eq "skip comments/whitespace in .rust-version" "1.80.0" "$(rsvm_read_version_file "$tmpdir/.rust-version")"
popd >/dev/null
rm -rf "$tmpdir"

# ---------- dist helpers ----------
echo "-- dist helpers --"
triple=$(rsvm_host_triple)
assert_contains "host triple is non-empty" "." "$triple"
assert_eq "tarball name" \
  "rust-1.85.0-${triple}.tar.xz" \
  "$(rsvm_dist_tarball_name 1.85.0 "$triple" xz)"
assert_eq "nightly tarball name" \
  "rust-nightly-${triple}.tar.xz" \
  "$(rsvm_dist_tarball_name nightly "$triple" xz)"

toml=$(mktemp)
cat > "$toml" <<EOF
[pkg.rustc]
version = "1.85.0 (abc 2025-01-01)"

[pkg.rust.target.${triple}]
available = true
url = "https://example.com/rust.gz"
hash = "aaa"
xz_url = "https://example.com/rust.xz"
xz_hash = "bbb"
EOF
parsed=$(rsvm_parse_channel_file "$toml" "$triple")
assert_eq "parse channel version" "1.85.0" "$(printf '%s\n' "$parsed" | cut -f1)"
assert_eq "parse channel xz url" "https://example.com/rust.xz" "$(printf '%s\n' "$parsed" | cut -f2)"
assert_eq "parse channel xz hash" "bbb" "$(printf '%s\n' "$parsed" | cut -f3)"
rm -f "$toml"

rsvm_is_release_channel stable \
  && { echo "  PASS  stable is a release channel"; PASS=$((PASS + 1)); } \
  || { echo "  FAIL  stable should be a release channel"; FAIL=$((FAIL + 1)); }
rsvm_is_release_channel 1.85.0 \
  && { echo "  FAIL  1.85.0 should not be a release channel"; FAIL=$((FAIL + 1)); } \
  || { echo "  PASS  numbered version is not a release channel"; PASS=$((PASS + 1)); }

assert_eq "normalize stable" "1.98.0" \
  "$(rsvm_normalize_rustc_version "1.98.0 (88d9e12ae 2026-08-18)")"
assert_eq "normalize beta" "1.99.0-beta.3" \
  "$(rsvm_normalize_rustc_version "1.99.0-beta.3 (cbae9b4ca 2026-08-28)")"
assert_eq "normalize nightly with date" "1.100.0-nightly-2026-08-30" \
  "$(rsvm_normalize_rustc_version "1.100.0-nightly (908501772 2026-08-30)")"

nightly_toml=$(mktemp)
cat > "$nightly_toml" <<EOF
[pkg.rustc]
version = "1.100.0-nightly (908501772 2026-08-30)"

[pkg.rust.target.${triple}]
available = true
xz_url = "https://example.com/rust-nightly.xz"
xz_hash = "ccc"
EOF
nightly_parsed=$(rsvm_parse_channel_file "$nightly_toml" "$triple")
assert_eq "parse nightly version includes date" "1.100.0-nightly-2026-08-30" \
  "$(printf '%s\n' "$nightly_parsed" | cut -f1)"
rm -f "$nightly_toml"

# ---------- nvm-style install: already installed + flags ----------
echo "-- rsvm install (local, no network) --"
rsvm install 1.75.0 >"$RSVM_DIR/install.out" 2>&1
install_out=$(cat "$RSVM_DIR/install.out")
assert_contains "already installed is a no-download" "already installed" "$install_out"
assert_contains "already installed still uses version" "Now using Rust 1.75.0" "$install_out"
assert_contains "PATH has rsvm version after install" "1.75.0" "$PATH"

install_def=$(rsvm install --default 1.70.0 2>&1)
assert_eq " --default sets alias" "1.70.0" "$(rsvm_get_alias default)"
assert_contains "--default uses current shell" "Now using Rust 1.70.0" "$install_def"

save_dir=$(mktemp -d)
pushd "$save_dir" >/dev/null
echo "1.75.0" > .rust-version
from_rc=$(rsvm install --save --alias=legacy 2>&1)
assert_contains "install with no args reads .rust-version" "Now using Rust 1.75.0" "$from_rc"
assert_eq "--save writes concrete version" "1.75.0" "$(cat .rust-version)"
assert_eq "--alias creates alias" "1.75.0" "$(rsvm_get_alias legacy)"
popd >/dev/null
rm -rf "$save_dir"

no_ver_dir=$(mktemp -d)
pushd "$no_ver_dir" >/dev/null
if rsvm install >/dev/null 2>&1; then
  echo "  FAIL  install without version/.rust-version should fail"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  install without version/.rust-version fails"
  PASS=$((PASS + 1))
fi
popd >/dev/null
rm -rf "$no_ver_dir"

# ---------- channel latest install (stubbed index, no download) ----------
echo "-- rsvm install stable/beta/nightly --"
rsvm_strip_path
rsvm alias stable 1.70.0 >/dev/null
fake_toolchain "1.98.0"
rsvm_lookup_dist() {
  case "$1" in
    stable)  printf '%s\t%s\t%s\n' "1.98.0" "https://example.invalid/rust-stable.xz" "aaa" ;;
    beta)    printf '%s\t%s\t%s\n' "1.99.0-beta.3" "https://example.invalid/rust-beta.xz" "bbb" ;;
    nightly) printf '%s\t%s\t%s\n' "1.100.0-nightly-2026-08-30" "https://example.invalid/rust-nightly.xz" "ccc" ;;
    *)       printf '%s\t%s\t%s\n' "$1" "https://example.invalid/rust.xz" "ddd" ;;
  esac
}

rsvm install stable >"$RSVM_DIR/stable.out" 2>&1
stable_out=$(cat "$RSVM_DIR/stable.out")
assert_contains "stable looks up live channel" "Latest stable is 1.98.0" "$stable_out"
assert_eq "stable alias tracks latest, not stale alias" "1.98.0" "$(rsvm_get_alias stable)"
assert_contains "stable install uses current shell PATH" "1.98.0" "$PATH"

fake_toolchain "1.99.0-beta.3"
rsvm_strip_path
rsvm install beta >"$RSVM_DIR/beta.out" 2>&1
beta_out=$(cat "$RSVM_DIR/beta.out")
assert_contains "beta looks up live channel" "Latest beta is 1.99.0-beta.3" "$beta_out"
assert_eq "beta alias tracks latest" "1.99.0-beta.3" "$(rsvm_get_alias beta)"

fake_toolchain "1.100.0-nightly-2026-08-30"
rsvm_strip_path
rsvm install nightly >"$RSVM_DIR/nightly.out" 2>&1
nightly_out=$(cat "$RSVM_DIR/nightly.out")
assert_contains "nightly looks up live channel" "Latest nightly is 1.100.0-nightly-2026-08-30" "$nightly_out"
assert_eq "nightly alias tracks dated build" "1.100.0-nightly-2026-08-30" "$(rsvm_get_alias nightly)"

# ---------- install from a fake standalone tarball ----------
echo "-- rsvm_install_from_tarball --"
pkg=$(mktemp -d)
mkdir -p "$pkg/rust-9.0.0-test"
cat > "$pkg/rust-9.0.0-test/install.sh" <<'EOS'
#!/bin/sh
prefix=""
for arg in "$@"; do
  case "$arg" in
    --prefix=*) prefix="${arg#--prefix=}" ;;
  esac
done
mkdir -p "$prefix/bin"
printf '#!/bin/sh\necho rustc 9.0.0\n' > "$prefix/bin/rustc"
printf '#!/bin/sh\necho cargo 9.0.0\n' > "$prefix/bin/cargo"
chmod +x "$prefix/bin/rustc" "$prefix/bin/cargo"
EOS
tar -cf "$pkg/rust-9.0.0-test.tar" -C "$pkg" rust-9.0.0-test
rsvm_install_from_tarball "9.0.0" "$pkg/rust-9.0.0-test.tar"
rsvm_version_installed "9.0.0" \
  && { echo "  PASS  tarball install created rustc"; PASS=$((PASS + 1)); } \
  || { echo "  FAIL  tarball install did not create rustc"; FAIL=$((FAIL + 1)); }
assert_eq "tarball rustc is executable output" "rustc 9.0.0" "$("$RSVM_DIR/versions/9.0.0/bin/rustc")"
rm -rf "$pkg"

# ---------- nvm-style uninstall ----------
echo "-- rsvm uninstall --"
rsvm_strip_path

if rsvm uninstall >/dev/null 2>&1; then
  echo "  FAIL  uninstall without version should fail"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  uninstall without version fails"
  PASS=$((PASS + 1))
fi

missing_out=$(rsvm uninstall 9.99.0 2>&1) || true
assert_contains "missing version is not installed" "is not installed" "$missing_out"
rsvm_version_installed "1.75.0" \
  && { echo "  PASS  uninstall missing does not remove others"; PASS=$((PASS + 1)); } \
  || { echo "  FAIL  1.75.0 should still be installed"; FAIL=$((FAIL + 1)); }

rsvm_add_to_path "1.75.0"
active_out=$(rsvm uninstall 1.75.0 2>&1) || true
assert_contains "refuses active version" "Cannot uninstall currently-active" "$active_out"
rsvm_version_installed "1.75.0" \
  && { echo "  PASS  active version remains installed"; PASS=$((PASS + 1)); } \
  || { echo "  FAIL  active version was removed"; FAIL=$((FAIL + 1)); }

rsvm_strip_path
rsvm alias extra 1.70.0 >/dev/null
mkdir -p "$RSVM_CACHE_DIR"
touch "$RSVM_CACHE_DIR/rust-1.70.0-aarch64-apple-darwin.tar.xz"
un_out=$(rsvm uninstall 1.70.0 2>&1)
assert_contains "uninstall message" "Uninstalled Rust 1.70.0" "$un_out"
assert_contains "removes aliases pointing at version" "Deleted alias" "$un_out"
rsvm_version_installed "1.70.0" \
  && { echo "  FAIL  1.70.0 should have been uninstalled"; FAIL=$((FAIL + 1)); } \
  || { echo "  PASS  rsvm-managed version directory is removed"; PASS=$((PASS + 1)); }
[[ -e "$RSVM_CACHE_DIR/rust-1.70.0-aarch64-apple-darwin.tar.xz" ]] \
  && { echo "  FAIL  cache tarball should be removed"; FAIL=$((FAIL + 1)); } \
  || { echo "  PASS  version cache tarball is removed"; PASS=$((PASS + 1)); }
[[ -f "$RSVM_ALIAS_DIR/extra" ]] \
  && { echo "  FAIL  extra alias should be deleted"; FAIL=$((FAIL + 1)); } \
  || { echo "  PASS  aliases pointing at uninstalled version are deleted"; PASS=$((PASS + 1)); }
[[ -f "$RSVM_ALIAS_DIR/default" ]] \
  && { echo "  FAIL  default alias pointing at 1.70.0 should be deleted"; FAIL=$((FAIL + 1)); } \
  || { echo "  PASS  default alias pointing at uninstalled version is deleted"; PASS=$((PASS + 1)); }

fake_toolchain "1.80.1"
partial_out=$(rsvm uninstall 1.80 2>&1)
assert_contains "partial version infers installed" "Uninstalled Rust 1.80.1" "$partial_out"
rsvm_version_installed "1.80.1" \
  && { echo "  FAIL  1.80.1 should have been uninstalled via partial match"; FAIL=$((FAIL + 1)); } \
  || { echo "  PASS  partial version matches local install"; PASS=$((PASS + 1)); }

alias_out=$(rsvm uninstall default 2>&1) || true
assert_contains "uninstall default with no alias" "is not installed" "$alias_out"

rsvm alias foo 1.75.0 >/dev/null
unalias_out=$(rsvm unalias foo 2>&1)
assert_contains "unalias deletes alias" "Deleted alias 'foo'" "$unalias_out"
[[ -f "$RSVM_ALIAS_DIR/foo" ]] \
  && { echo "  FAIL  foo alias should be gone"; FAIL=$((FAIL + 1)); } \
  || { echo "  PASS  rsvm unalias removes the alias file"; PASS=$((PASS + 1)); }

# rustup-managed versions are left alone (uninstall is rsvm-dir only)
rsvm_version_installed "1.75.0" \
  && { echo "  PASS  other rsvm versions remain after uninstall"; PASS=$((PASS + 1)); } \
  || { echo "  FAIL  1.75.0 should still be present"; FAIL=$((FAIL + 1)); }

# ---------- cleanup ----------
rm -rf "$RSVM_DIR"

echo ""
echo "=============================="
echo "Result: PASS=$PASS  FAIL=$FAIL"
echo "=============================="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
