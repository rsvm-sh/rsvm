#!/usr/bin/env bash
# install.sh — rsvm installer
# Usage:
#   Local:   bash install_sh.sh
#   Remote:  curl -o- https://raw.githubusercontent.com/rsvm-sh/rsvm/v0.1.0/install_sh.sh | bash

set -e

RSVM_DIR="${RSVM_DIR:-$HOME/.rsvm}"
RSVM_REPO="${RSVM_REPO:-https://github.com/rsvm-sh/rsvm}"
RSVM_VERSION="${RSVM_VERSION:-v0.1.0}"
RSVM_BRANCH="${RSVM_BRANCH:-$RSVM_VERSION}"

# ---------- helpers ----------

rsvm_echo() { echo ">>> $*"; }
rsvm_err()  { echo "!!! $*" >&2; }
rsvm_has()  { command -v "$1" &>/dev/null; }

rsvm_detect_profile() {
  if [[ -n "${PROFILE:-}" ]]; then
    echo "$PROFILE"; return
  fi
  local shell_type="${SHELL##*/}"
  case "$shell_type" in
    bash)
      if [[ -f "$HOME/.bash_profile" ]]; then echo "$HOME/.bash_profile"
      else echo "$HOME/.bashrc"; fi ;;
    zsh)  echo "${ZDOTDIR:-$HOME}/.zshrc" ;;
    fish) echo "$HOME/.config/fish/config.fish" ;;
    *)    echo "$HOME/.profile" ;;
  esac
}

rsvm_github_raw_base() {
  local repo="${RSVM_REPO%.git}"
  repo="${repo%/}"
  case "$repo" in
    https://github.com/*)
      echo "https://raw.githubusercontent.com/${repo#https://github.com/}/${RSVM_BRANCH}"
      ;;
    git@github.com:*)
      echo "https://raw.githubusercontent.com/${repo#git@github.com:}/${RSVM_BRANCH}"
      ;;
    *)
      echo "$repo/raw/$RSVM_BRANCH"
      ;;
  esac
}

# Copy repo source names (rsvm_sh.sh) or installed names (rsvm.sh) into $RSVM_DIR.
rsvm_copy_scripts_from() {
  local src_dir="$1"
  mkdir -p "$RSVM_DIR"

  rsvm_copy_one() {
    local dest="$1"; shift
    local src
    for src in "$@"; do
      if [[ -f "$src" ]]; then
        cp "$src" "$RSVM_DIR/$dest"
        rsvm_echo "Installed $dest"
        return 0
      fi
    done
    rsvm_err "$dest not found"
    return 1
  }

  rsvm_copy_one rsvm.sh "$src_dir/rsvm_sh.sh" "$src_dir/rsvm.sh"
  rsvm_copy_one rsvm-exec "$src_dir/rsvm_exec.sh" "$src_dir/rsvm-exec"
  rsvm_copy_one bash_completion "$src_dir/bash_completion.sh" "$src_dir/bash_completion"
  chmod +x "$RSVM_DIR/rsvm-exec"
}

# Single-quoted heredoc prevents $HOME from expanding at install time
rsvm_source_snippet_bash_zsh() {
  cat <<'EOF'

# >>> rsvm >>>
export RSVM_DIR="$HOME/.rsvm"

_rsvm_lazy_load() {
  unset -f rsvm rustc cargo rustup
  [ -s "$RSVM_DIR/rsvm.sh" ] && source "$RSVM_DIR/rsvm.sh"
  [ -s "$RSVM_DIR/bash_completion" ] && source "$RSVM_DIR/bash_completion"
}

rsvm()    { _rsvm_lazy_load; rsvm    "$@"; }
rustc()  { _rsvm_lazy_load; rustc  "$@"; }
cargo()  { _rsvm_lazy_load; cargo  "$@"; }
rustup() { _rsvm_lazy_load; rustup "$@"; }
# <<< rsvm <<<
EOF
}

rsvm_source_snippet_fish() {
  cat <<'EOF'

# >>> rsvm >>>
set -x RSVM_DIR $HOME/.rsvm
functions --erase rsvm
function rsvm
    functions --erase rsvm rustc cargo rustup
    [ -s $RSVM_DIR/rsvm.sh ]; and source $RSVM_DIR/rsvm.sh
    rsvm $argv
end
# <<< rsvm <<<
EOF
}

# ---------- install ----------

install_rsvm_from_local() {
  local script_dir="$1"
  rsvm_echo "Installing from local directory: $script_dir"
  rsvm_copy_scripts_from "$script_dir"
}

# Clone a throwaway copy and install only the script files (keeps versions/ cache/).
install_rsvm_from_git() {
  rsvm_echo "Installing from Git ($RSVM_REPO @ $RSVM_BRANCH) ..."

  if [[ -d "$RSVM_DIR/.git" ]]; then
    rsvm_echo "Existing git repo found, pulling latest..."
    git -C "$RSVM_DIR" fetch --depth=1 --quiet origin "$RSVM_BRANCH"
    git -C "$RSVM_DIR" checkout -q "$RSVM_BRANCH" 2>/dev/null \
      || git -C "$RSVM_DIR" checkout -q "FETCH_HEAD"
    rsvm_copy_scripts_from "$RSVM_DIR"
    return
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d)
  git clone --depth=1 --quiet --branch "$RSVM_BRANCH" "$RSVM_REPO" "$tmp_dir"
  rsvm_copy_scripts_from "$tmp_dir"
  rm -rf "$tmp_dir"
}

install_rsvm_from_curl() {
  rsvm_echo "Downloading via curl ($RSVM_BRANCH) ..."
  local raw tmp_dir
  raw=$(rsvm_github_raw_base)
  tmp_dir=$(mktemp -d)
  curl -fsSL "$raw/rsvm_sh.sh" -o "$tmp_dir/rsvm_sh.sh"
  curl -fsSL "$raw/rsvm_exec.sh" -o "$tmp_dir/rsvm_exec.sh"
  curl -fsSL "$raw/bash_completion.sh" -o "$tmp_dir/bash_completion.sh"
  rsvm_copy_scripts_from "$tmp_dir"
  rm -rf "$tmp_dir"
}

inject_profile() {
  local profile; profile=$(rsvm_detect_profile)
  local marker="# >>> rsvm >>>"
  mkdir -p "$(dirname "$profile")"

  if [[ -f "$profile" ]] && grep -qF "$marker" "$profile" 2>/dev/null; then
    rsvm_echo "Profile $profile already contains rsvm, skipping"
    return
  fi

  rsvm_echo "Injecting rsvm init into $profile ..."
  if [[ "${SHELL##*/}" == "fish" ]]; then
    rsvm_source_snippet_fish >> "$profile"
  else
    rsvm_source_snippet_bash_zsh >> "$profile"
  fi
  rsvm_echo "Done. To apply now, run:"
  rsvm_echo "  source $profile"
}

# ---------- main ----------

main() {
  rsvm_echo "Installing RSVM - Rust Version Manager $RSVM_VERSION"
  rsvm_echo "Target directory: $RSVM_DIR"

  # 1. Local checkout (dev) — copy from this directory
  # 2. git — clone the tagged ref (curl | bash)
  # 3. curl — download individual files
  local script_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi

  if [[ -n "$script_dir" && ( -f "$script_dir/rsvm_sh.sh" || -f "$script_dir/rsvm.sh" ) ]]; then
    install_rsvm_from_local "$script_dir"
  elif rsvm_has git; then
    install_rsvm_from_git
  elif rsvm_has curl; then
    install_rsvm_from_curl
  else
    rsvm_err "git or curl is required. Please install one and retry."
    exit 1
  fi

  if [[ ! -f "$RSVM_DIR/rsvm.sh" ]]; then
    rsvm_err "Install failed: $RSVM_DIR/rsvm.sh is missing"
    exit 1
  fi

  inject_profile
  rsvm_echo "Installation complete!"
}

main "$@"
