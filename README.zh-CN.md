# rsvm — Rust Version Manager

[![CI](https://github.com/rsvm-sh/rsvm/actions/workflows/ci.yml/badge.svg)](https://github.com/rsvm-sh/rsvm/actions/workflows/ci.yml)

[English](README.md) | **简体中文**

按 [nvm](https://github.com/nvm-sh/nvm) 的方式管理 Rust：自己下载官方独立安装包，装进 `~/.rsvm/versions/`，只改**当前 shell** 的 `PATH`。不依赖 rustup，也不会调用 `rustup default`。

Rust 没有 Node 那种 LTS 通道。官方只有三条发布线，rsvm 都支持装**当前最新版**：

| 通道 | 命令 | 说明 |
|------|------|------|
| **stable** | `rsvm install stable` | 生产默认，约每 6 周发一版 |
| **beta** | `rsvm install beta` | 下一个 stable 的预发布 |
| **nightly** | `rsvm install nightly` | 每日构建；目录名带日期，方便第二天再装新的 |

也可以钉死具体版本：`rsvm install 1.85.0`。

## 安装

需要 `curl`、`tar`。在项目目录执行：

```bash
bash install_sh.sh
```

脚本会把文件拷到 `~/.rsvm/`（`rsvm.sh`、`rsvm-exec`、`bash_completion`），并在 shell 配置里写入懒加载片段。zsh 用户一般是 `~/.zshrc`。

然后：

```bash
source ~/.zshrc   # 或新开一个终端
rsvm help
```

默认目录可用环境变量改：

```bash
export RSVM_DIR="$HOME/.rsvm"
```

## 三个通道：装最新版

```bash
rsvm install stable     # 当前 latest stable，例如 1.98.0
rsvm install beta       # 当前 latest beta，例如 1.99.0-beta.3
rsvm install nightly    # 当天 nightly，例如 1.100.0-nightly-2026-08-30
```

行为：

1. 向 `https://static.rust-lang.org/dist/channel-rust-<channel>.toml` 查询**此刻**的最新版（不会沿用旧 alias）
2. 下载官方 standalone tarball，校验 SHA256
3. 安装到 `~/.rsvm/versions/<具体版本>/`
4. 把该版本的 `bin` 插到当前 shell 的 `PATH` 前面
5. 更新 alias：`stable` / `beta` / `nightly` 指向刚装的具体版本

已经装过同一具体版本时会跳过下载，但仍会 `use` 并刷新通道 alias。

```bash
rsvm use stable
rsvm use beta
rsvm use nightly
```

`use` 走 alias：用的是**上次** `install <通道>` 记下的版本，不会隐式再下一份。要跟上通道最新，再跑一次 `rsvm install <通道>`。

## 常用命令

```bash
rsvm install 1.85.0              # 指定版本
rsvm install --default stable    # 装完同时设为 default
rsvm install --save 1.85.0       # 写入当前目录 .rust-version
rsvm install                     # 不传版本时读 .rust-version

rsvm uninstall 1.85.0            # 只删 ~/.rsvm/versions 里的副本
rsvm uninstall 1.85              # 匹配本地已装的 1.85.x
rsvm uninstall default

rsvm use 1.85.0
rsvm use                         # 读 .rust-version
rsvm current
rsvm which 1.85.0
rsvm list                        # 已安装版本 + system + alias（nvm list 风格）
rsvm list-remote                 # 全部远端版本，从旧到新
rsvm list-remote 50              # 只显示前 50 个
rsvm use system                  # 不用 rsvm 的 PATH，回到系统/rustup 的 rustc
rsvm alias default system        # 新终端默认用 system

rsvm alias default 1.85.0
rsvm alias default 1.85      # 已安装的最新 1.85.x（和 nvm alias default 18.12 一样）
rsvm alias default 1         # 已安装的最新 1.x（和 nvm alias default 18 一样）
rsvm unalias default

rsvm run 1.85.0 cargo test
rsvm-exec 1.85.0 cargo build
rsvm-exec -- cargo build         # 读最近的 .rust-version

rsvm unload
```

当前正在用的版本不能卸载，需要先 `rsvm use` 到别的版本。卸载会删掉指向该版本的 alias，以及 `~/.rsvm/cache/` 里对应的 tarball。

## `.rust-version`

和 nvm 的 `.nvmrc` 一样，从当前目录往上找：

```
1.85.0
```

也可以写 `stable` / `beta` / `nightly`。空行和 `#` 注释会忽略。

- `rsvm install` / `rsvm use` 不传版本时读这个文件
- `rsvm-exec --` 同样读取

## 目录

```
~/.rsvm/
  rsvm.sh
  rsvm-exec
  bash_completion
  versions/          # 每个版本一份完整 toolchain
    1.98.0/bin/rustc
    1.99.0-beta.3/
    1.100.0-nightly-2026-08-30/
  alias/
    default
    stable
    beta
    nightly
  cache/             # 下载的 dist tarball
```

## 环境变量

| 变量 | 默认 | 含义 |
|------|------|------|
| `RSVM_DIR` | `~/.rsvm` | rsvm 主目录 |
| `RSVM_DIST_MIRROR` | `https://static.rust-lang.org/dist` | 发行包镜像 |

## 和 rustup / nvm 的差别

- **相对 rustup**：rsvm 把 toolchain 放在自己的 `versions/` 里，切换只影响当前 shell，不改 rustup 的全局 default。不必先装 rustup。
- **相对 nvm**：`install` / `uninstall` / `use` / alias / 项目版本文件 对齐 nvm。`rsvm alias default 1.85` 会保存模式 `1.85`，`rsvm use default` 时再解析成当前已安装的最新 `1.85.x`。Rust 没有 LTS，所以没有 `--lts`；生产对应的是 `stable`。
- nightly 带日期是为了同一大版本号（例如 `1.100.0-nightly`）在不同天仍能各装一份。

## 测试

```bash
bash test/test_suite.sh
```

不访问网络；通道安装用本地 stub 的版本索引。
