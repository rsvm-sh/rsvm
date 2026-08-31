#!/usr/bin/env bash
# RSVM - Rust Version Manager
# Usage: source rsvm.sh  (cannot be executed directly, same as nvm)
# All internal functions are prefixed with rsvm_ to avoid polluting the global namespace

{ # Wrap the entire file in braces to prevent partial exposure if sourcing fails

# ============================================================
# Layer 1: Constants & environment
# ============================================================

RSVM_DIR="${RSVM_DIR:-$HOME/.rsvm}"
RSVM_VERSIONS_DIR="$RSVM_DIR/versions"
RSVM_ALIAS_DIR="$RSVM_DIR/alias"
RSVM_DEFAULT_ALIAS="$RSVM_ALIAS_DIR/default"
RSVM_CACHE_DIR="${RSVM_CACHE_DIR:-$RSVM_DIR/cache}"
RSVM_DIST_MIRROR="${RSVM_DIST_MIRROR:-https://static.rust-lang.org/dist}"
RSVM_VERSION="0.1.0"

# ============================================================
# Layer 2: Shell integration — PATH manipulation & environment awareness
# (Mirrors nvm's PATH modification and .nvmrc-reading logic)
# ============================================================

# List direct child directories/files. Avoids zsh NOMATCH on empty globs.
rsvm_each_dir() {
  local parent="$1"
  [[ -d "$parent" ]] || return 0
  find "$parent" -mindepth 1 -maxdepth 1 -type d 2>/dev/null
}

rsvm_each_file() {
  local parent="$1"
  [[ -d "$parent" ]] || return 0
  find "$parent" -mindepth 1 -maxdepth 1 -type f 2>/dev/null
}

# Prepend the given version's bin directory to PATH
rsvm_add_to_path() {
  local version_bin="$RSVM_VERSIONS_DIR/$1/bin"
  case ":${PATH}:" in
    *":${version_bin}:"*) ;; # already present, skip
    *) export PATH="$version_bin:$PATH" ;;
  esac
}

# Remove all rsvm-managed paths from PATH
rsvm_strip_path() {
  local new_path=""
  local IFS=":"
  for p in $PATH; do
    case "$p" in
      "$RSVM_VERSIONS_DIR"/*/bin) ;; # drop rsvm paths
      *) new_path="${new_path:+$new_path:}$p" ;;
    esac
  done
  export PATH="$new_path"
}

# True if this rsvm-managed version is currently on PATH (nvm_ls_current analog)
rsvm_is_version_active() {
  local version_bin="$RSVM_VERSIONS_DIR/$1/bin"
  case ":${PATH}:" in
    *":${version_bin}:"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Walk up the directory tree looking for a .rust-version file (like nvm's .nvmrc)
rsvm_find_version_file() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/.rust-version" ]]; then
      echo "$dir/.rust-version"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# Read the first non-empty, non-comment line from a version file
rsvm_read_version_file() {
  local file="$1" line
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -n "$line" ]]; then
      echo "$line"
      return 0
    fi
  done < "$file"
  return 1
}

# Version from .rust-version, if present (like nvm_rc_version)
rsvm_version_from_file() {
  local file
  file=$(rsvm_find_version_file) || return 1
  rsvm_read_version_file "$file"
}

# Detect the user's shell profile file (used by install.sh)
rsvm_detect_profile() {
  local profile_filename
  case "$SHELL" in
    */bash)
      if [[ -f "$HOME/.bash_profile" ]]; then
        profile_filename="$HOME/.bash_profile"
      else
        profile_filename="$HOME/.bashrc"
      fi ;;
    */zsh)   profile_filename="${ZDOTDIR:-$HOME}/.zshrc" ;;
    */fish)  profile_filename="$HOME/.config/fish/config.fish" ;;
    *)       profile_filename="$HOME/.profile" ;;
  esac
  echo "$profile_filename"
}

# ============================================================
# Layer 3: Version management — install state & alias system
# ============================================================

# Create required directories
rsvm_ensure_dirs() {
  mkdir -p "$RSVM_VERSIONS_DIR" "$RSVM_ALIAS_DIR" "$RSVM_ALIAS_DIR/lts" "$RSVM_CACHE_DIR"
}

# Check whether a version is managed by rsvm (has rustc, like nvm's node binary check)
rsvm_version_installed() {
  [[ -x "$RSVM_VERSIONS_DIR/$1/bin/rustc" ]]
}

# Check whether rustup has a given toolchain installed
rsvm_rustup_has() {
  command -v rustup &>/dev/null || return 1
  rustup toolchain list 2>/dev/null | grep -q "^${1}-"
}

# Write an alias to the alias directory (like nvm alias default x.x.x)
rsvm_set_alias() {
  local name="$1" version="$2"
  rsvm_ensure_dirs
  echo "$version" > "$RSVM_ALIAS_DIR/$name"
}

# Read an alias
rsvm_get_alias() {
  local alias_file="$RSVM_ALIAS_DIR/$1"
  [[ -f "$alias_file" ]] && cat "$alias_file"
}

rsvm_is_release_channel() {
  case "$1" in
    stable|beta|nightly) return 0 ;;
    *) return 1 ;;
  esac
}

# "1.100.0-nightly (908501772 2026-08-30)" -> 1.100.0-nightly-2026-08-30
# "1.99.0-beta.3 (hash date)" -> 1.99.0-beta.3
# "1.98.0 (hash date)" -> 1.98.0
rsvm_normalize_rustc_version() {
  local raw="$1" ver date
  ver=$(printf '%s\n' "$raw" | awk '{print $1}')
  date=$(printf '%s\n' "$raw" | awk '{
    if (NF >= 3) { gsub(/[()]/, "", $3); print $3 }
  }')
  case "$ver" in
    *-nightly)
      if [[ -n "$date" ]]; then echo "${ver}-${date}"
      else echo "$ver"
      fi ;;
    *) echo "$ver" ;;
  esac
}

# Latest installed version matching a prefix: 1 -> 1.98.0, 1.85 -> 1.85.1
# Like nvm_ls <pattern> | tail -1. Local rsvm versions only.
rsvm_latest_local_matching() {
  local input="$1"
  [[ -n "$input" ]] || return 1

  local re_full='^[0-9]+\.[0-9]+\.[0-9]+(-.*)?$'
  local re_minor='^[0-9]+\.[0-9]+$'
  local re_major='^[0-9]+$'

  if [[ "$input" =~ $re_full ]]; then
    rsvm_version_installed "$input" || return 1
    echo "$input"
    return 0
  fi

  local pattern=""
  if [[ "$input" =~ $re_minor || "$input" =~ $re_major ]]; then
    local escaped
    escaped=$(printf '%s' "$input" | sed 's/\./\\./g')
    pattern="^${escaped}\\."
  else
    return 1
  fi

  local v match="" versions
  versions=$(rsvm_local_versions)
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    rsvm_version_installed "$v" || continue
    printf '%s\n' "$v" | grep -Eq "$pattern" || continue
    match="$v"
  done <<< "$versions"

  [[ -n "$match" ]] || return 1
  echo "$match"
}

# Follow aliases, then local prefix match. local_only=1 skips network channel lookup.
rsvm__resolve() {
  local input="$1" seen="$2" local_only="${3:-0}"
  [[ -n "$input" ]] || return 1

  if [[ "$input" == "system" ]]; then
    echo "system"
    return 0
  fi

  case " ${seen} " in
    *" ${input} "*)
      echo "[rsvm] Circular alias: $input" >&2
      return 1 ;;
  esac
  seen="${seen} ${input}"

  local aliased
  aliased=$(rsvm_get_alias "$input")
  if [[ -n "$aliased" ]]; then
    rsvm__resolve "$aliased" "$seen" "$local_only"
    return
  fi

  local match
  match=$(rsvm_latest_local_matching "$input") && {
    echo "$match"
    return 0
  }

  if rsvm_version_installed "$input"; then
    echo "$input"
    return 0
  fi

  if [[ "$local_only" -eq 1 ]]; then
    echo "$input"
    return 0
  fi

  case "$input" in
    stable|beta|nightly)
      local channel_ver
      channel_ver=$(rsvm_fetch_channel_version "$input")
      if [[ -n "$channel_ver" ]]; then echo "$channel_ver"
      else echo "$input"
      fi ;;
    lts/*)
      rsvm_get_alias "${input#lts/}" ;;
    *)
      echo "$input" ;;
  esac
}

# Resolve a version string: aliases, prefix match, channels (nvm_version analog)
rsvm_resolve_version() {
  rsvm__resolve "$1" "" 0
}

# Aliases + locally installed versions only (no network)
rsvm_resolve_local() {
  rsvm__resolve "$1" "" 1
}

# Uninstall matching: aliases and installed prefixes, no network
rsvm_match_local_version() {
  rsvm_resolve_local "$1"
}

# If no default alias exists, create one (nvm_ensure_default_set)
rsvm_ensure_default_set() {
  local version="$1"
  [[ -n "$version" ]] || return 1
  if [[ -n "$(rsvm_get_alias default)" ]]; then
    return 0
  fi
  rsvm_set_alias default "$version"
  echo "[rsvm] Creating default alias: default -> $version"
}

# Return the currently active Rust version
rsvm_current_version() {
  command -v rustc &>/dev/null \
    && rustc --version 2>/dev/null | awk '{print $2}'
}

# 1.94.0 -> stable, 1.99.0-beta.3 -> beta, 1.100.0-nightly-* -> nightly
rsvm_version_channel() {
  local v="$1"
  case "$v" in
    ""|system) echo "" ;;
    *nightly*|nightly) echo "nightly" ;;
    *beta*|beta) echo "beta" ;;
    stable|[0-9]*) echo "stable" ;;
    *) echo "" ;;
  esac
}

# True if an rsvm-managed versions/*/bin is on PATH
rsvm_is_using_rsvm() {
  case ":${PATH}:" in
    *":${RSVM_VERSIONS_DIR}/"*) return 0 ;;
    *) return 1 ;;
  esac
}

# rustc version with rsvm paths removed (nvm's system node)
rsvm_system_version() {
  (
    rsvm_strip_path
    command -v rustc >/dev/null 2>&1 || exit 1
    rustc --version 2>/dev/null | awk '{print $2}'
  )
}

rsvm_has_system_rust() {
  rsvm_system_version >/dev/null 2>&1
}

rsvm_use_system() {
  if ! rsvm_has_system_rust; then
    echo "[rsvm] N/A: no system version of rustc is installed." >&2
    return 1
  fi
  rsvm_strip_path
  echo "[rsvm] Now using system version of Rust: $(rsvm_system_version)"
}

rsvm_rustup_channel_version() {
  local channel="$1"
  command -v rustup >/dev/null 2>&1 || return 1
  rustup toolchain list 2>/dev/null | grep -q "^${channel}-" || return 1
  rustup run "$channel" rustc --version 2>/dev/null | awk '{print $2}'
}

# List all versions managed by rsvm
rsvm_local_versions() {
  rsvm_ensure_dirs
  local d
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    basename "$d"
  done < <(rsvm_each_dir "$RSVM_VERSIONS_DIR") | sort -V
}

# rustup *numbered* toolchains only. Channel names (stable/beta/nightly)
# are shown as system / aliases, like nvm does not duplicate system node.
rsvm_rustup_versions() {
  command -v rustup &>/dev/null || return
  rustup toolchain list 2>/dev/null \
    | sed -E 's/^([^ ]+)-[^-]+-[^-]+-[^-]+.*/\1/' \
    | while read -r v; do
        case "$v" in
          stable|beta|nightly|"") continue ;;
        esac
        echo "$v"
      done \
    | sort -V -u
}

# Merge all locally installed versions (rsvm + rustup), deduplicated and sorted
rsvm_installed_versions() {
  { rsvm_local_versions; rsvm_rustup_versions; } \
    | grep -v '^$' | sort -V -u
}

# ============================================================
# Layer 4: Network — remote version fetching
# ============================================================

# Fetch the current version for a given Rust release channel
rsvm_fetch_channel_version() {
  local channel="$1" raw
  raw=$(curl -sf "${RSVM_DIST_MIRROR}/channel-rust-${channel}.toml" 2>/dev/null \
    | awk '/^\[pkg\.rustc\]/{found=1} found && /^version =/{
        split($0, a, "\"")
        print a[2]
        exit
      }')
  [[ -n "$raw" ]] || return 1
  rsvm_normalize_rustc_version "$raw"
}

# Parse rust RELEASES.md on stdin -> version numbers (one per line)
rsvm_parse_releases_md() {
  grep -E '^Version [0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}'
}

# Historical stables from RELEASES.md (one request, no API rate limit)
rsvm_fetch_release_history() {
  local md
  md=$(curl -sfL "https://raw.githubusercontent.com/rust-lang/rust/stable/RELEASES.md" 2>/dev/null) || return 1
  printf '%s\n' "$md" | rsvm_parse_releases_md
}

# Fallback: GitHub releases API
rsvm_fetch_github_releases() {
  local page=1 max_pages=5 data versions
  while (( page <= max_pages )); do
    data=$(curl -sfL "https://api.github.com/repos/rust-lang/rust/releases?per_page=100&page=${page}" 2>/dev/null)
    [[ -z "$data" ]] && break
    versions=$(printf '%s\n' "$data" \
      | grep -oE '"tag_name":[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+[^"]*"' \
      | cut -d'"' -f4)
    [[ -z "$versions" ]] && break
    printf '%s\n' "$versions"
    page=$((page + 1))
  done
}

# Aggregate all remote versions (stable history + current beta/nightly)
rsvm_fetch_remote_versions() {
  echo "[rsvm] Fetching remote version list..." >&2
  local stable beta nightly history
  stable=$(rsvm_fetch_channel_version stable)
  beta=$(rsvm_fetch_channel_version beta)
  nightly=$(rsvm_fetch_channel_version nightly)
  history=$(rsvm_fetch_release_history) || history=$(rsvm_fetch_github_releases)

  if [[ -z "$stable" && -z "$history" ]]; then
    echo "[rsvm] Error: failed to fetch remote versions. Check your network connection." >&2
    return 1
  fi

  { printf '%s\n' "$history"; printf '%s\n' "$stable"; printf '%s\n' "$beta"; printf '%s\n' "$nightly"; } \
    | grep -v '^$' | sort -V -u
}

# Host triple for dist artifacts (e.g. aarch64-apple-darwin)
rsvm_host_triple() {
  local os arch
  os=$(uname -s)
  arch=$(uname -m)
  case "$os" in
    Darwin)
      case "$arch" in
        arm64|aarch64) echo "aarch64-apple-darwin" ;;
        x86_64) echo "x86_64-apple-darwin" ;;
        *) echo "[rsvm] Unsupported architecture: $arch" >&2; return 1 ;;
      esac ;;
    Linux)
      case "$arch" in
        x86_64) echo "x86_64-unknown-linux-gnu" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
        *) echo "[rsvm] Unsupported architecture: $arch" >&2; return 1 ;;
      esac ;;
    *)
      echo "[rsvm] Unsupported OS: $os" >&2; return 1 ;;
  esac
}

rsvm_dist_tarball_name() {
  local version="$1" triple="$2" ext="${3:-xz}"
  case "$version" in
    nightly) echo "rust-nightly-${triple}.tar.${ext}" ;;
    beta) echo "rust-beta-${triple}.tar.${ext}" ;;
    *) echo "rust-${version}-${triple}.tar.${ext}" ;;
  esac
}

# Parse a channel toml: prints version<TAB>url<TAB>hash
rsvm_parse_channel_file() {
  local file="$1" triple="$2"
  awk -v triple="$triple" '
    BEGIN { target_sec = "[pkg.rust.target." triple "]" }
    $0 == "[pkg.rustc]" { rs=1; next }
    rs && /^\[/ { rs=0 }
    rs && /^version =/ {
      split($0, a, "\"")
      n = split(a[2], b, " ")
      ver=b[1]
      if (ver ~ /-nightly$/ && n >= 3) {
        gsub(/[()]/, "", b[3])
        if (b[3] != "") ver=ver "-" b[3]
      }
    }
    $0 == target_sec { ts=1; next }
    ts && /^\[/ { ts=0 }
    ts && /^xz_url =/ { split($0, a, "\""); xz_url=a[2] }
    ts && /^xz_hash =/ { split($0, a, "\""); xz_hash=a[2] }
    ts && /^url =/ { split($0, a, "\""); gz_url=a[2] }
    ts && /^hash =/ { split($0, a, "\""); gz_hash=a[2] }
    END {
      if (xz_url != "") { print ver "\t" xz_url "\t" xz_hash; exit 0 }
      if (gz_url != "") { print ver "\t" gz_url "\t" gz_hash; exit 0 }
      exit 1
    }
  ' "$file"
}

# Expand 1.75 / 1 to the latest matching remote version (like nvm install 18)
rsvm_expand_partial_version() {
  local input="$1" pattern match versions
  local re_full='^[0-9]+\.[0-9]+\.[0-9]+(-.*)?$'
  local re_minor='^[0-9]+\.[0-9]+$'
  local re_major='^[0-9]+$'
  if [[ "$input" =~ $re_full ]]; then
    echo "$input"
    return 0
  fi
  if [[ "$input" =~ $re_minor || "$input" =~ $re_major ]]; then
    local escaped
    escaped=$(printf '%s' "$input" | sed 's/\./\\./g')
    pattern="^${escaped}\\."
  else
    echo "$input"
    return 0
  fi
  versions=$(rsvm_fetch_remote_versions) || return 1
  match=$(printf '%s\n' "$versions" | grep -E "$pattern" | tail -1)
  if [[ -z "$match" ]]; then
    echo "[rsvm] Version '$input' not found - try \`rsvm ls-remote\` to browse available versions." >&2
    return 3
  fi
  echo "$match"
}

# Look up dist artifact. Prints version<TAB>url<TAB>hash
rsvm_lookup_dist() {
  local requested="$1"
  local triple="$2"
  local toml tmp line

  rsvm_ensure_dirs
  tmp=$(mktemp "${TMPDIR:-/tmp}/rsvm_channel.XXXXXX") || return 1

  if curl -sf "${RSVM_DIST_MIRROR}/channel-rust-${requested}.toml" -o "$tmp" 2>/dev/null; then
    line=$(rsvm_parse_channel_file "$tmp" "$triple") && {
      rm -f "$tmp"
      echo "$line"
      return 0
    }
  fi
  rm -f "$tmp"

  local file url hash
  file=$(rsvm_dist_tarball_name "$requested" "$triple" xz)
  url="${RSVM_DIST_MIRROR}/${file}"
  hash=$(curl -sf "${url}.sha256" 2>/dev/null | awk '{print $1}')
  printf '%s\t%s\t%s\n' "$requested" "$url" "$hash"
}

rsvm_sha256() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    return 1
  fi
}

rsvm_download() {
  local url="$1" dest="$2"
  echo "[rsvm] Downloading $url"
  curl -fL --progress-bar -o "$dest" "$url"
}

# Extract standalone installer tarball into $RSVM_VERSIONS_DIR/$version
rsvm_install_from_tarball() {
  local version="$1" tarball="$2"
  local dest="$RSVM_VERSIONS_DIR/$version"
  local tmp pkg install_sh rc=0

  rsvm_ensure_dirs
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/rsvm_extract.XXXXXX") || return 1

  echo "[rsvm] Installing Rust $version to $dest"
  if ! tar -xf "$tarball" -C "$tmp"; then
    echo "[rsvm] Failed to extract $tarball" >&2
    rm -rf "$tmp"
    return 1
  fi

  local pkg
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    if [[ -f "$pkg/install.sh" ]]; then
      install_sh="$pkg/install.sh"
      break
    fi
  done < <(rsvm_each_dir "$tmp")

  if [[ -z "${install_sh:-}" ]]; then
    echo "[rsvm] install.sh not found in tarball" >&2
    rm -rf "$tmp"
    return 1
  fi

  rm -rf "$dest"
  mkdir -p "$dest"

  if ! sh "$install_sh" --prefix="$dest" --disable-ldconfig --without=rust-docs; then
    rm -rf "$dest"
    mkdir -p "$dest"
    if ! sh "$install_sh" --prefix="$dest" --disable-ldconfig; then
      echo "[rsvm] Standalone installer failed" >&2
      rm -rf "$dest" "$tmp"
      return 1
    fi
  fi

  rm -rf "$tmp"

  if [[ ! -x "$dest/bin/rustc" ]]; then
    echo "[rsvm] Install finished but $dest/bin/rustc is missing" >&2
    rm -rf "$dest"
    return 1
  fi
  return $rc
}

# ============================================================
# Layer 5: Command implementations
# ============================================================

# rsvm use [<version>]  — uses .rust-version if version is omitted
rsvm_use() {
  local requested="${1:-}" version

  if [[ -z "$requested" ]]; then
    requested=$(rsvm_version_from_file) || true
  fi

  if [[ "$requested" == "system" ]]; then
    rsvm_use_system
    return
  fi

  version=$(rsvm_resolve_version "$requested")

  if [[ -z "$version" ]]; then
    echo "[rsvm] Usage: rsvm use <version>" >&2
    echo "       (or add a .rust-version file)" >&2
    return 1
  fi

  if [[ "$version" == "system" ]]; then
    rsvm_use_system
    return
  fi

  if rsvm_version_installed "$version"; then
    rsvm_strip_path
    rsvm_add_to_path "$version"
    echo "[rsvm] Now using Rust $version"
    return 0
  fi

  if rsvm_rustup_has "$version"; then
    rustup default "$version" &>/dev/null
    echo "[rsvm] (via rustup) Now using Rust $version"
    return 0
  fi

  echo "[rsvm] Version $version is not installed. Run 'rsvm list-remote' to see available versions." >&2
  return 1
}

rsvm_print_alias() {
  local name="$1" target="$2" resolved
  resolved=$(rsvm_resolve_local "$target")
  if [[ -n "$resolved" && "$resolved" != "$target" ]]; then
    printf "%-20s -> %s (-> %s)\n" "$name" "$target" "$resolved"
  else
    printf "%-20s -> %s\n" "$name" "$target"
  fi
}

# rsvm alias [name] [version]
# Stores the given pattern (e.g. 1.85). Resolve to latest installed 1.85.x on use.
rsvm_alias() {
  local name="${1:-}" target="${2:-}"
  rsvm_ensure_dirs

  if [[ -z "$name" ]]; then
    local f
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      rsvm_print_alias "$(basename "$f")" "$(cat "$f")"
    done < <(rsvm_each_file "$RSVM_ALIAS_DIR")
    return 0
  fi

  if [[ "$name" == */* ]]; then
    echo "[rsvm] Aliases in subdirectories are not supported." >&2
    return 1
  fi

  if [[ -z "$target" ]]; then
    local stored
    stored=$(rsvm_get_alias "$name")
    if [[ -z "$stored" ]]; then
      echo "[rsvm] Alias '$name' not found" >&2
      return 1
    fi
    echo "$stored"
    return 0
  fi

  rsvm_set_alias "$name" "$target"

  local resolved=""
  resolved=$(rsvm_latest_local_matching "$target" 2>/dev/null || true)
  if [[ -z "$resolved" ]] && rsvm_version_installed "$target"; then
    resolved="$target"
  fi
  if [[ -z "$resolved" ]] && [[ -n "$(rsvm_get_alias "$target")" ]]; then
    resolved=$(rsvm_resolve_local "$target")
  fi

  if [[ "$target" == "system" ]]; then
    if rsvm_has_system_rust; then
      resolved="system"
    else
      echo "[rsvm] ! WARNING: Version 'system' is not installed." >&2
    fi
  elif [[ -z "$resolved" ]] && ! rsvm_is_release_channel "$target"; then
    echo "[rsvm] ! WARNING: Version '$target' is not installed." >&2
  fi

  if [[ -n "$resolved" && "$resolved" != "$target" ]]; then
    echo "[rsvm] Alias '$name' -> '$target' (-> $resolved)"
  else
    echo "[rsvm] Alias '$name' -> '$target'"
  fi
}

rsvm_list_print_alias() {
  local name="$1" target="$2"
  local resolved sys star=""
  if [[ -z "$target" ]]; then
    printf "%s -> N/A\n" "$name"
    return
  fi
  if [[ "$target" == "system" ]]; then
    sys=$(rsvm_system_version)
    if [[ -z "$sys" ]]; then
      printf "%s -> system (-> N/A)\n" "$name"
      return
    fi
    rsvm_is_using_rsvm || star=" *"
    printf "%s -> system (-> %s%s)\n" "$name" "$sys" "$star"
    return
  fi
  if rsvm_is_release_channel "$target"; then
    local ch_ver
    ch_ver=$(rsvm_rustup_channel_version "$target" 2>/dev/null || true)
    if [[ -z "$ch_ver" ]]; then
      ch_ver=$(rsvm_resolve_local "$target")
    fi
    if [[ -n "$ch_ver" && "$ch_ver" != "$target" ]]; then
      [[ "$ch_ver" == "$(rsvm_system_version 2>/dev/null)" ]] && ! rsvm_is_using_rsvm && star=" *"
      rsvm_is_using_rsvm && [[ "$ch_ver" == "$(rsvm_current_version)" ]] && star=" *"
      printf "%s -> %s (-> %s%s)\n" "$name" "$target" "$ch_ver" "$star"
      return
    fi
  fi
  resolved=$(rsvm_resolve_local "$target")
  if rsvm_is_using_rsvm && [[ "$resolved" == "$(rsvm_current_version)" ]]; then
    star=" *"
  fi
  if [[ -n "$resolved" && "$resolved" != "$target" ]]; then
    if rsvm_version_installed "$resolved" || rsvm_rustup_has "$resolved"; then
      printf "%s -> %s (-> %s%s)\n" "$name" "$target" "$resolved" "$star"
    else
      printf "%s -> %s (-> N/A)\n" "$name" "$target"
    fi
  else
    printf "%s -> %s%s\n" "$name" "$target" "$star"
  fi
}

# rsvm list / rsvm ls  — nvm-style: versions, system, then aliases
rsvm_list() {
  rsvm_ensure_dirs
  local cur using_rsvm sys versions def
  cur=$(rsvm_current_version)
  using_rsvm=0
  rsvm_is_using_rsvm && using_rsvm=1
  sys=$(rsvm_system_version 2>/dev/null || true)
  def=$(rsvm_get_alias default)
  versions=$(rsvm_installed_versions)

  echo ""
  if [[ -z "$versions" ]]; then
    echo "(no rsvm versions installed)"
  else
    while IFS= read -r v; do
      [[ -z "$v" ]] && continue
      local mark="   "
      local suffix="" ch
      ch=$(rsvm_version_channel "$v")
      [[ -n "$ch" ]] && suffix=" ($ch)"
      if [[ "$using_rsvm" -eq 1 && "$v" == "$cur" ]]; then
        mark="-> "
      fi
      [[ -n "$def" && "$(rsvm_resolve_local "$def")" == "$v" ]] && suffix="${suffix} *"
      if rsvm_version_installed "$v"; then
        suffix="${suffix} [rsvm]"
      else
        suffix="${suffix} [rustup]"
      fi
      printf "  %s %s%s\n" "$mark" "$v" "$suffix"
    done <<< "$versions"
  fi

  if [[ -n "$sys" ]]; then
    local sys_mark="   "
    [[ "$using_rsvm" -eq 0 ]] && sys_mark="-> "
    printf "  %s system (-> %s)\n" "$sys_mark" "$sys"
  fi

  echo ""
  local printed=" "
  local name f target
  for name in default stable beta nightly; do
    target=$(rsvm_get_alias "$name")
    if [[ -z "$target" && "$name" != "default" ]]; then
      if rsvm_rustup_channel_version "$name" >/dev/null 2>&1; then
        target="$name"
      fi
    fi
    rsvm_list_print_alias "$name" "$target"
    printed="${printed}${name} "
  done
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    name=$(basename "$f")
    case " $printed " in
      *" $name "*) continue ;;
    esac
    rsvm_list_print_alias "$name" "$(cat "$f")"
  done < <(rsvm_each_file "$RSVM_ALIAS_DIR")
  echo ""
}

# rsvm list-remote / rsvm ls-remote
# No arg: print every known version (nvm-style). Optional N limits the count.
rsvm_list_remote() {
  local limit="${1:-0}"
  local cur stable beta nightly history versions
  cur=$(rsvm_current_version)

  echo "[rsvm] Fetching remote version list..." >&2
  stable=$(rsvm_fetch_channel_version stable)
  beta=$(rsvm_fetch_channel_version beta)
  nightly=$(rsvm_fetch_channel_version nightly)
  history=$(rsvm_fetch_release_history) || history=$(rsvm_fetch_github_releases)

  if [[ -z "$stable" && -z "$history" ]]; then
    echo "[rsvm] Error: failed to fetch remote versions. Check your network connection." >&2
    return 1
  fi

  versions=$(
    { printf '%s\n' "$history"; printf '%s\n' "$stable"; printf '%s\n' "$beta"; printf '%s\n' "$nightly"; } \
      | grep -v '^$' | sort -V -u
  )

  echo ""
  local count=0 v mark extra
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    if [[ "$limit" -gt 0 && "$count" -ge "$limit" ]]; then
      break
    fi
    mark="   "
    extra=""
    [[ "$v" == "$cur" ]] && mark="-> "
    [[ "$v" == "$stable" ]] && extra=" (stable)"
    [[ "$v" == "$beta" ]] && extra=" (beta)"
    [[ "$v" == "$nightly" ]] && extra=" (nightly)"
    if rsvm_version_installed "$v"; then
      extra="${extra} [installed]"
    fi
    printf "  %s %-22s%s\n" "$mark" "$v" "$extra"
    count=$((count + 1))
  done <<< "$versions"

  echo ""
  if [[ "$limit" -gt 0 ]]; then
    echo "Showing $count versions. Use 'rsvm list-remote' to show all."
    echo ""
  fi
}

# rsvm current
rsvm_current() {
  if ! rsvm_is_using_rsvm; then
    echo "system"
    return
  fi
  local v; v=$(rsvm_current_version)
  if [[ -z "$v" ]]; then
    echo "system"; return
  fi
  echo "$v"
}

# rsvm which [version]
rsvm_which() {
  if [[ -n "${1:-}" ]]; then
    local version bin
    version=$(rsvm_resolve_local "$1")
    if [[ "$version" == "system" ]]; then
      (
        rsvm_strip_path
        command -v rustc 2>/dev/null
      ) || { echo "[rsvm] system rustc not found" >&2; return 1; }
      return
    fi
    bin="$RSVM_VERSIONS_DIR/$version/bin/rustc"
    if [[ -x "$bin" ]]; then echo "$bin"
    else echo "[rsvm] Version $1 not found" >&2; return 1; fi
  else
    command -v rustc 2>/dev/null || { echo "[rsvm] rustc not found" >&2; return 1; }
  fi
}

# rsvm install [<version>]
# Download the official standalone toolchain into $RSVM_DIR/versions (nvm-style).
# Switches the current shell via PATH; does not call rustup default.
rsvm_install() {
  local set_default=0 save_file=0 alias_name="" requested=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --default) set_default=1; shift ;;
      --save) save_file=1; shift ;;
      --alias=*) alias_name="${1#--alias=}"; shift ;;
      --alias)
        if [[ -z "${2:-}" ]]; then
          echo "[rsvm] --alias requires a name" >&2; return 1
        fi
        alias_name="$2"; shift 2 ;;
      -*)
        echo "[rsvm] Unknown option: $1" >&2; return 1 ;;
      *)
        requested="$1"; shift
        if [[ $# -gt 0 ]]; then
          echo "[rsvm] Unexpected extra arguments: $*" >&2; return 1
        fi
        break ;;
    esac
  done

  if [[ -z "$requested" ]]; then
    requested=$(rsvm_version_from_file) || true
  fi

  if [[ -z "$requested" ]]; then
    echo "[rsvm] Usage: rsvm install [<version>]" >&2
    echo "       Uses .rust-version if version is omitted." >&2
    return 1
  fi

  local version="" url="" hash="" channel_name="" triple artifact art_ver cache_file actual

  rsvm_ensure_dirs

  if rsvm_is_release_channel "$requested"; then
    channel_name="$requested"
    if ! command -v curl >/dev/null 2>&1; then
      echo "[rsvm] curl is required to install Rust" >&2
      return 1
    fi
    triple=$(rsvm_host_triple) || return 1
    echo "[rsvm] Looking up latest $channel_name..."
    artifact=$(rsvm_lookup_dist "$channel_name" "$triple") || {
      echo "[rsvm] Failed to resolve latest $channel_name. Check your network connection." >&2
      return 3
    }
    IFS=$'\t' read -r version url hash <<< "$artifact"
    if [[ -z "$version" ]]; then
      echo "[rsvm] Failed to resolve latest $channel_name" >&2
      return 1
    fi
    echo "[rsvm] Latest $channel_name is $version"
  else
    case "$requested" in
      default) version=$(rsvm_get_alias default) ;;
      *)
        local aliased
        aliased=$(rsvm_get_alias "$requested")
        if [[ -n "$aliased" ]]; then
          version="$aliased"
        else
          version=$(rsvm_expand_partial_version "$requested") || return $?
        fi ;;
    esac
  fi

  if [[ -z "$version" ]]; then
    echo "[rsvm] Unable to resolve version '$requested'" >&2
    return 1
  fi

  if rsvm_version_installed "$version"; then
    echo "[rsvm] Rust $version is already installed"
  else
    if ! command -v curl >/dev/null 2>&1; then
      echo "[rsvm] curl is required to install Rust" >&2
      return 1
    fi

    if [[ -z "$url" ]]; then
      triple=$(rsvm_host_triple) || return 1
      echo "[rsvm] Downloading and installing Rust $version..."
      artifact=$(rsvm_lookup_dist "$version" "$triple") || {
        echo "[rsvm] Version '$requested' not found - try \`rsvm ls-remote\` to browse available versions." >&2
        return 3
      }
      IFS=$'\t' read -r art_ver url hash <<< "$artifact"
      [[ -n "$art_ver" ]] && version="$art_ver"
    else
      echo "[rsvm] Downloading and installing Rust $version..."
    fi

    if rsvm_version_installed "$version"; then
      echo "[rsvm] Rust $version is already installed"
    else
      cache_file="$RSVM_CACHE_DIR/$(basename "$url")"

      if [[ -f "$cache_file" && -n "$hash" ]]; then
        actual=$(rsvm_sha256 "$cache_file" 2>/dev/null || true)
        if [[ "$actual" != "$hash" ]]; then
          rm -f "$cache_file"
        fi
      fi

      if [[ ! -f "$cache_file" ]]; then
        if ! rsvm_download "$url" "$cache_file"; then
          rm -f "$cache_file"
          local fallback
          fallback="${RSVM_DIST_MIRROR}/$(rsvm_dist_tarball_name "$version" "$triple" xz)"
          if [[ "$url" != "$fallback" ]] && rsvm_download "$fallback" "$cache_file"; then
            url="$fallback"
            hash=$(curl -sf "${url}.sha256" 2>/dev/null | awk '{print $1}')
          else
            echo "[rsvm] Failed to download Rust $version" >&2
            rm -f "$cache_file"
            return 1
          fi
        fi
      fi

      if [[ -n "$hash" ]]; then
        actual=$(rsvm_sha256 "$cache_file") || {
          echo "[rsvm] No sha256 tool found; skipping checksum" >&2
          actual="$hash"
        }
        if [[ "$actual" != "$hash" ]]; then
          echo "[rsvm] Checksum mismatch for $(basename "$cache_file")" >&2
          echo "        expected: $hash" >&2
          echo "        actual:   $actual" >&2
          rm -f "$cache_file"
          return 1
        fi
      fi

      rsvm_install_from_tarball "$version" "$cache_file" || return 1
    fi
  fi

  rsvm_use "$version" || return 1
  rsvm_ensure_default_set "$version"

  if [[ -n "$channel_name" ]]; then
    rsvm_set_alias "$channel_name" "$version"
    echo "[rsvm] Alias '$channel_name' -> '$version'"
  fi

  if [[ $set_default -eq 1 ]]; then
    rsvm_set_alias default "$version"
    echo "[rsvm] Alias 'default' -> '$version'"
  fi
  if [[ -n "$alias_name" ]]; then
    rsvm_set_alias "$alias_name" "$version"
    echo "[rsvm] Alias '$alias_name' -> '$version'"
  fi
  if [[ $save_file -eq 1 ]]; then
    echo "$version" > "$PWD/.rust-version"
    echo "[rsvm] Wrote $version to .rust-version"
  fi
}

# Delete an alias (nvm unalias)
rsvm_unalias() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "[rsvm] Usage: rsvm unalias <name>" >&2
    return 1
  fi
  if [[ ! -f "$RSVM_ALIAS_DIR/$name" ]]; then
    echo "[rsvm] Alias '$name' does not exist." >&2
    return 1
  fi
  rm -f "$RSVM_ALIAS_DIR/$name"
  echo "[rsvm] Deleted alias '$name'"
}

# Remove cached dist tarballs for a version
rsvm_clear_version_cache() {
  local version="$1" f
  [[ -d "$RSVM_CACHE_DIR" ]] || return 0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$(basename "$f")" in
      rust-"${version}"-*) rm -f "$f" ;;
    esac
  done < <(rsvm_each_file "$RSVM_CACHE_DIR")
}

# rsvm uninstall <version> — remove from $RSVM_DIR/versions only (nvm-style)
rsvm_uninstall() {
  if [[ $# -ne 1 || -z "${1:-}" ]]; then
    echo "[rsvm] Usage: rsvm uninstall <version>" >&2
    return 1
  fi

  if [[ "$1" == "system" ]]; then
    echo "[rsvm] Cannot uninstall system Rust." >&2
    return 1
  fi

  local requested="$1"
  local version
  version=$(rsvm_match_local_version "$requested")

  if [[ -z "$version" ]]; then
    echo "[rsvm] Usage: rsvm uninstall <version>" >&2
    return 1
  fi

  if rsvm_is_version_active "$version"; then
    echo "[rsvm] Cannot uninstall currently-active Rust version, $version (inferred from $requested)." >&2
    return 1
  fi

  if ! rsvm_version_installed "$version"; then
    if [[ "$version" != "$requested" ]]; then
      echo "[rsvm] Version '$version' (inferred from $requested) is not installed." >&2
    else
      echo "[rsvm] Version '$requested' is not installed." >&2
    fi
    return 1
  fi

  local dest="$RSVM_VERSIONS_DIR/$version"
  if [[ ! -w "$dest" ]]; then
    echo "[rsvm] Cannot uninstall, incorrect permissions on installation folder." >&2
    echo "       $dest" >&2
    return 1
  fi

  rsvm_clear_version_cache "$version"
  rm -rf "${RSVM_VERSIONS_DIR:?}/$version"
  echo "[rsvm] Uninstalled Rust $version"

  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ "$(cat "$f")" == "$version" ]]; then
      rsvm_unalias "$(basename "$f")"
    fi
  done < <(rsvm_each_file "$RSVM_ALIAS_DIR")
}

# rsvm run <version> <command...>
rsvm_run() {
  local requested="${1:-}"; shift
  if [[ -z "$requested" ]]; then
    echo "[rsvm] Usage: rsvm run <version> <command>" >&2; return 1
  fi
  local version
  version=$(rsvm_resolve_local "$requested")
  if [[ "$version" == "system" || "$requested" == "system" ]]; then
    (
      rsvm_strip_path
      "$@"
    )
    return
  fi
  if rsvm_rustup_has "$version"; then
    rustup run "$version" "$@"
  elif rsvm_version_installed "$version"; then
    PATH="$RSVM_VERSIONS_DIR/$version/bin:$PATH" "$@"
  else
    echo "[rsvm] Version $requested is not installed" >&2; return 1
  fi
}

# rsvm unload — remove all rsvm functions and variables from the current shell
rsvm_unload() {
  rsvm_strip_path

  local fns
  fns=$(declare -F | awk '{print $3}' | grep '^rsvm_')
  while IFS= read -r fn; do
    unset -f "$fn"
  done <<< "$fns"

  unset RSVM_DIR RSVM_VERSIONS_DIR RSVM_ALIAS_DIR RSVM_DEFAULT_ALIAS RSVM_VERSION RSVM_CACHE_DIR RSVM_DIST_MIRROR

  unset -f rsvm
  echo "[rsvm] Unloaded from current shell"
}

# rsvm help
rsvm_help() {
  cat <<EOF

RSVM - Rust Version Manager ${RSVM_VERSION}

Usage: rsvm <command> [args]

Version management:
  install stable            Install the latest stable (updates the 'stable' alias)
  install beta              Install the latest beta (updates the 'beta' alias)
  install nightly           Install the latest nightly (updates the 'nightly' alias)
  install [<version>]       Download and install a version into \$RSVM_DIR/versions.
                            Uses .rust-version if version is omitted.
                            After install, switches the current shell via PATH
                            (does not change rustup's global default).
    --default               Set the default alias to this version
    --save                  Write the version to .rust-version
    --alias=<name>          Create an alias for this version
  uninstall <version>       Uninstall a version from \$RSVM_DIR/versions.
                            Refuses if that version is active in the current shell.
                            Also removes aliases that pointed at it.
  use [<version>]           Switch Rust version in the current shell.
                            Uses .rust-version if version is omitted.
                            \`rsvm use system\` drops rsvm from PATH (nvm-style).
  current                   Show the active version (\`system\` if rsvm is not on PATH)
  which [version]           Show the path to rustc

Listing:
  list, ls                  List installed versions, system, and aliases
  list-remote [n], ls-remote [n]
                            List remote versions (all, oldest first; n limits count)

Aliases:
  alias [name] [version]    Get or set an alias.
                            Partial versions match the latest installed:
                              rsvm alias default 1       # latest installed 1.x
                              rsvm alias default 1.85    # latest installed 1.85.x
                              rsvm alias default system  # use system rustc by default
  unalias <name>            Delete an alias

Execution:
  run <version> <cmd>       Run a command under a specific version

Shell:
  unload                    Remove all rsvm functions and variables from the current shell

Help:
  help                      Show this help

Environment:
  RSVM_DIR          rsvm home directory (default: ~/.rsvm)
  RSVM_DIST_MIRROR  Rust dist mirror (default: https://static.rust-lang.org/dist)

EOF
}

# ============================================================
# Layer 6: Main dispatcher — the single public entry point
# (mirrors nvm()'s main function)
# ============================================================

rsvm() {
  local cmd="${1:-help}"
  [[ "$#" -gt 0 ]] && shift

  case "$cmd" in
    install|i)              rsvm_install "$@" ;;
    uninstall)              rsvm_uninstall "$@" ;;
    use)                    rsvm_use "$@" ;;
    current)                rsvm_current ;;
    which)                  rsvm_which "$@" ;;
    list|ls)                rsvm_list ;;
    list-remote|ls-remote)  rsvm_list_remote "$@" ;;
    alias)                  rsvm_alias "$@" ;;
    unalias)                rsvm_unalias "$@" ;;
    run)                    rsvm_run "$@" ;;
    unload)                 rsvm_unload ;;
    help|--help|-h)         rsvm_help ;;
    --version|-v)           echo "rsvm $RSVM_VERSION" ;;
    *)
      echo "[rsvm] Unknown command: $cmd" >&2
      echo "Run 'rsvm help' for available commands." >&2
      return 1 ;;
  esac
}

# nvm-style: honour `alias default` when the file is sourced.
# Tests and scripts can skip with RSVM_NO_USE=1.
if [[ "${RSVM_NO_USE:-}" != "1" ]]; then
  _rsvm_def=$(rsvm_get_alias default)
  if [[ -n "$_rsvm_def" ]]; then
    rsvm_use "$_rsvm_def" >/dev/null 2>&1 || true
  fi
  unset _rsvm_def
fi

} # end brace wrapper
