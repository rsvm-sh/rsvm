#!/usr/bin/env bash
# install.sh —— rsvm installer
# Usage:
#   Local:   bash install.sh
#   Remote:  curl -o- https://your-host/install.sh | bash

set -e

RSVM_DIR="${RSVM_DIR:-$HOME/.rsvm}"
RSVM_REPO="${RSVM_REPO:-https://github.com/rsvm-sh/rsvm}"
RSVM_BRANCH="${RSVM_BRANCH:-main}"

# ---------- helpers ----------

rsvm_echo() { echo ">>> $*"; }
rsvm_err()  { echo "!!! $*" >&2; }
rsvm_has()  { command -v "$1" &>/dev/null; }

rsvm_detect_profile() {
  if [[ -n "${PROFILE:-}" ]] && [[ -f "$PROFILE" ]]; then
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

# Local dev mode: copy files from the same directory as this script
install_rsvm_from_local() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  rsvm_echo "Installing from local directory: $script_dir"
  mkdir -p "$RSVM_DIR"

  copy_one() {
    local dest="$1"; shift
    local src
    for src in "$@"; do
      if [[ -f "$src" ]]; then
        cp "$src" "$RSVM_DIR/$dest"
        rsvm_echo "Copied $dest"
        return 0
      fi
    done
    rsvm_err "$dest not found, skipping"
    return 1
  }
  copy_one rsvm.sh "$script_dir/rsvm_sh.sh" "$script_dir/rsvm.sh"
  copy_one rsvm-exec "$script_dir/rsvm_exec.sh" "$script_dir/rsvm-exec"
  copy_one bash_completion "$script_dir/bash_completion.sh" "$script_dir/bash_completion"

  chmod +x "$RSVM_DIR/rsvm-exec"
}

# Clone or update from Git
install_rsvm_from_git() {
  rsvm_echo "Installing from Git to $RSVM_DIR ..."

  if [[ -d "$RSVM_DIR/.git" ]]; then
    # Already a git repo — just update
    rsvm_echo "Existing git repo found, pulling latest..."
    git -C "$RSVM_DIR" pull --ff-only --quiet

  elif [[ -d "$RSVM_DIR" ]]; then
    # Directory exists but is not a git repo
    # Copy only script files to preserve user data (versions/, cache/)
    rsvm_echo "$RSVM_DIR exists (not a git repo), updating script files only..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    git clone --depth=1 --quiet --branch "$RSVM_BRANCH" "$RSVM_REPO" "$tmp_dir"
    [[ -f "$tmp_dir/rsvm_sh.sh" ]] && cp "$tmp_dir/rsvm_sh.sh" "$RSVM_DIR/rsvm.sh"
    [[ -f "$tmp_dir/rsvm.sh" ]] && cp "$tmp_dir/rsvm.sh" "$RSVM_DIR/rsvm.sh"
    [[ -f "$tmp_dir/rsvm_exec.sh" ]] && cp "$tmp_dir/rsvm_exec.sh" "$RSVM_DIR/rsvm-exec"
    [[ -f "$tmp_dir/rsvm-exec" ]] && cp "$tmp_dir/rsvm-exec" "$RSVM_DIR/rsvm-exec"
    [[ -f "$tmp_dir/bash_completion.sh" ]] && cp "$tmp_dir/bash_completion.sh" "$RSVM_DIR/bash_completion"
    [[ -f "$tmp_dir/bash_completion" ]] && cp "$tmp_dir/bash_completion" "$RSVM_DIR/bash_completion"
    chmod +x "$RSVM_DIR/rsvm-exec"
    rm -rf "$tmp_dir"

  else
    # Fresh install
    git clone --depth=1 --branch "$RSVM_BRANCH" "$RSVM_REPO" "$RSVM_DIR"
    chmod +x "$RSVM_DIR/rsvm-exec"
  fi
}

# Fallback: download via curl
install_rsvm_from_curl() {
  rsvm_echo "Downloading via curl..."
  mkdir -p "$RSVM_DIR"
  local base_url="$RSVM_REPO/raw/$RSVM_BRANCH"
  for f in rsvm.sh rsvm-exec bash_completion; do
    curl -sf "$base_url/$f" -o "$RSVM_DIR/$f" \
      && rsvm_echo "Downloaded $f" \
      || rsvm_err "Failed to download $f"
  done
  chmod +x "$RSVM_DIR/rsvm-exec"
}

inject_profile() {
  local profile; profile=$(rsvm_detect_profile)
  local marker="# >>> rsvm >>>"

  if grep -qF "$marker" "$profile" 2>/dev/null; then
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
  rsvm_echo "Installing RSVM - Rust Version Manager"
  rsvm_echo "Target directory: $RSVM_DIR"

  # Priority:
  # 1. Local files exist (dev mode) → copy directly
  # 2. git available               → clone / pull
  # 3. curl available              → download
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [[ -f "$script_dir/rsvm_sh.sh" || -f "$script_dir/rsvm.sh" ]]; then
    install_rsvm_from_local
  elif rsvm_has git; then
    install_rsvm_from_git
  elif rsvm_has curl; then
    install_rsvm_from_curl
  else
    rsvm_err "git or curl is required. Please install one and retry."
    exit 1
  fi

  inject_profile
  rsvm_echo "Installation complete!"
}

main "$@"
