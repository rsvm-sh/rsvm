# rsvm — Rust Version Manager

**English** | [简体中文](README.zh-CN.md)

Manage Rust the [nvm](https://github.com/nvm-sh/nvm) way: download official standalone installers into `~/.rsvm/versions/`, and change `PATH` for the **current shell only**. No rustup, and never calls `rustup default`.

Rust has no Node-style LTS channel. There are three official release lines; rsvm can install the **current latest** of each:

| Channel | Command | Notes |
|---------|---------|-------|
| **stable** | `rsvm install stable` | Production default; a new release about every 6 weeks |
| **beta** | `rsvm install beta` | Preview of the next stable |
| **nightly** | `rsvm install nightly` | Daily builds; directory names include the date so you can install a new one the next day |

You can also pin a specific version: `rsvm install 1.85.0`.

## Install

Requires `curl` and `tar`. From the project directory:

```bash
bash install_sh.sh
```

The script copies files into `~/.rsvm/` (`rsvm.sh`, `rsvm-exec`, `bash_completion`) and writes a lazy-load snippet into your shell config. For zsh that is usually `~/.zshrc`.

Then:

```bash
source ~/.zshrc   # or open a new terminal
rsvm help
```

Override the default directory with:

```bash
export RSVM_DIR="$HOME/.rsvm"
```

## Three channels: install the latest

```bash
rsvm install stable     # current latest stable, e.g. 1.98.0
rsvm install beta       # current latest beta, e.g. 1.99.0-beta.3
rsvm install nightly    # today's nightly, e.g. 1.100.0-nightly-2026-08-30
```

What happens:

1. Query `https://static.rust-lang.org/dist/channel-rust-<channel>.toml` for the **latest right now** (does not reuse a stale alias)
2. Download the official standalone tarball and verify SHA256
3. Install into `~/.rsvm/versions/<exact-version>/`
4. Prepend that version's `bin` to the current shell's `PATH`
5. Update aliases: `stable` / `beta` / `nightly` point at the version just installed

If that exact version is already installed, the download is skipped, but rsvm still `use`s it and refreshes the channel alias.

```bash
rsvm use stable
rsvm use beta
rsvm use nightly
```

`use` follows the alias: it uses the version recorded by the **last** `install <channel>`, and will not download another copy. To pick up the latest on a channel, run `rsvm install <channel>` again.

## Common commands

```bash
rsvm install 1.85.0              # specific version
rsvm install --default stable    # install and set as default
rsvm install --save 1.85.0       # write .rust-version in the current directory
rsvm install                     # no version: read .rust-version

rsvm uninstall 1.85.0            # delete the copy under ~/.rsvm/versions
rsvm uninstall 1.85              # match an installed 1.85.x
rsvm uninstall default

rsvm use 1.85.0
rsvm use                         # read .rust-version
rsvm current
rsvm which 1.85.0
rsvm list                        # installed versions + system + aliases (nvm list style)
rsvm list-remote                 # all remote versions, oldest first
rsvm list-remote 50              # first 50 only
rsvm use system                  # drop rsvm from PATH; fall back to system/rustup rustc
rsvm alias default system        # new terminals default to system

rsvm alias default 1.85.0
rsvm alias default 1.85      # latest installed 1.85.x (same as nvm alias default 18.12)
rsvm alias default 1         # latest installed 1.x (same as nvm alias default 18)
rsvm unalias default

rsvm run 1.85.0 cargo test
rsvm-exec 1.85.0 cargo build
rsvm-exec -- cargo build         # read nearest .rust-version

rsvm unload
```

You cannot uninstall the version currently in use; `rsvm use` another version first. Uninstall also removes aliases that point at that version, and the matching tarball in `~/.rsvm/cache/`.

## `.rust-version`

Like nvm's `.nvmrc`. Walks up from the current directory:

```
1.85.0
```

`stable` / `beta` / `nightly` are also valid. Blank lines and `#` comments are ignored.

- `rsvm install` / `rsvm use` with no version read this file
- `rsvm-exec --` does the same

## Layout

```
~/.rsvm/
  rsvm.sh
  rsvm-exec
  bash_completion
  versions/          # a full toolchain per version
    1.98.0/bin/rustc
    1.99.0-beta.3/
    1.100.0-nightly-2026-08-30/
  alias/
    default
    stable
    beta
    nightly
  cache/             # downloaded dist tarballs
```

## Environment variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `RSVM_DIR` | `~/.rsvm` | rsvm home directory |
| `RSVM_DIST_MIRROR` | `https://static.rust-lang.org/dist` | Dist tarball mirror |

## Differences from rustup / nvm

- **vs rustup**: rsvm keeps toolchains in its own `versions/` directory. Switching only affects the current shell; it does not change rustup's global default. rustup is not required.
- **vs nvm**: `install` / `uninstall` / `use` / aliases / per-project version files follow nvm. `rsvm alias default 1.85` stores the pattern `1.85`; `rsvm use default` then resolves to the latest installed `1.85.x`. Rust has no LTS, so there is no `--lts`; production maps to `stable`.
- Nightlies include a date so the same major.minor.patch (e.g. `1.100.0-nightly`) can still be installed once per day.

## Tests

```bash
bash test/test_suite.sh
```

No network. Channel installs use a local stub version index.
