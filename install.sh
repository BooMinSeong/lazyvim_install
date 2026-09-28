#!/usr/bin/env bash
# LazyVim no-sudo installer
# - Installs everything under ~/.local (no apt, no sudo)
# - Static tools (ripgrep, fd, lazygit, fzf) come from GitHub releases
# - glibc-dependent tools (neovim, tree-sitter CLI, node, C compiler) come from
#   GitHub/nodejs.org when the host glibc is new enough, otherwise from
#   conda-forge via a standalone micromamba binary.
#
# Usage: ./install.sh [options]
#   --backend auto|github|conda  where glibc-dependent tools come from (default: auto)
#   --no-node                    skip Node.js (some Mason LSPs need it)
#   --no-config                  install tools only, don't touch nvim config
#   --no-rc                      don't edit ~/.bashrc / ~/.zshrc
#   --skip-bootstrap             don't run headless plugin/parser/Mason install
#   --uninstall                  remove everything this script installed (config is backed up)
#   --doctor                     show what is installed and where it resolves from
set -euo pipefail

# ---------- settings ----------
PREFIX="${LAZYVIM_PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"
OPT="$PREFIX/opt/lazyvim-tools"
CONDA_ENV="$OPT/conda"
MAMBA="$OPT/micromamba"
STARTER_REPO="https://github.com/LazyVim/starter"
NODE_MAJOR_MIN=20

BACKEND=auto
WITH_NODE=1
WITH_CONFIG=1
WITH_RC=1
BOOTSTRAP=1
ACTION=install

# Minimum host glibc for the official prebuilt binaries (checked with objdump -T)
GLIBC_NVIM=2.34
GLIBC_TS=2.39
GLIBC_NODE=2.28

# ---------- helpers ----------
c_blue=$'\033[1;34m'; c_green=$'\033[1;32m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_off=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$c_blue" "$c_off" "$*"; }
ok()   { printf '%s ✓%s %s\n' "$c_green" "$c_off" "$*"; }
warn() { printf '%s !%s %s\n' "$c_yellow" "$c_off" "$*" >&2; }
die()  { printf '%s ✗%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ver_ge A B  -> true if version A >= B
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

fetch() { # fetch URL OUTFILE
  if have curl; then curl -fL --retry 3 --progress-bar -o "$2" "$1"
  elif have wget; then wget -q --show-progress -O "$2" "$1"
  else die "curl or wget is required"; fi
}

fetch_stdout() {
  if have curl; then curl -fsSL --retry 3 "$1"; else wget -qO- "$1"; fi
}

# latest release tag of a GitHub repo, without the API (avoids rate limits):
# github.com/<repo>/releases/latest redirects to .../tag/<tag>
gh_latest() {
  local url
  if have curl; then
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest")
  else
    url=$(wget -S --spider "https://github.com/$1/releases/latest" 2>&1 | awk '/^  Location: /{l=$2} END{print l}')
  fi
  url="${url%$'\r'}"
  [ -n "$url" ] && [ "${url##*/}" != latest ] || die "cannot resolve latest release of $1"
  echo "${url##*/}"
}

host_glibc() {
  local v
  v=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}') || true
  [ -n "$v" ] || v=$(ldd --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+$') || true
  echo "${v:-0}"
}

link_bin() { # link_bin TARGET NAME
  mkdir -p "$BIN"
  ln -sfn "$1" "$BIN/$2"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------- arch / platform ----------
detect_platform() {
  [ "$(uname -s)" = Linux ] || die "only Linux is supported"
  case "$(uname -m)" in
    x86_64|amd64)  ARCH=x86_64; NVIM_ARCH=x86_64; RG_ARCH=x86_64; LG_ARCH=x86_64; FZF_ARCH=amd64; TS_ARCH=x64;   NODE_ARCH=x64;   CONDA_PLAT=linux-64 ;;
    aarch64|arm64) ARCH=aarch64; NVIM_ARCH=arm64; RG_ARCH=aarch64; LG_ARCH=arm64; FZF_ARCH=arm64; TS_ARCH=arm64; NODE_ARCH=arm64; CONDA_PLAT=linux-aarch64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
  GLIBC=$(host_glibc)
  log "platform: Linux $ARCH, glibc $GLIBC, prefix $PREFIX"
}

# decide backend for a glibc-dependent tool: echo github|conda
pick_backend() { # pick_backend REQUIRED_GLIBC
  case "$BACKEND" in
    github) echo github ;;
    conda)  echo conda ;;
    auto)   if ver_ge "$GLIBC" "$1"; then echo github; else echo conda; fi ;;
  esac
}

# ---------- conda-forge (micromamba) ----------
CONDA_PKGS=()

ensure_micromamba() {
  [ -x "$MAMBA" ] && return
  log "downloading micromamba (static)"
  mkdir -p "$OPT"
  fetch "https://github.com/mamba-org/micromamba-releases/releases/latest/download/micromamba-$CONDA_PLAT" "$MAMBA"
  chmod +x "$MAMBA"
}

install_conda_pkgs() {
  [ "${#CONDA_PKGS[@]}" -gt 0 ] || return 0
  ensure_micromamba
  log "installing from conda-forge: ${CONDA_PKGS[*]}"
  export MAMBA_ROOT_PREFIX="$OPT/mamba-root"
  if [ -d "$CONDA_ENV/conda-meta" ]; then
    "$MAMBA" install -y -q -p "$CONDA_ENV" -c conda-forge --override-channels "${CONDA_PKGS[@]}"
  else
    "$MAMBA" create -y -q -p "$CONDA_ENV" -c conda-forge --override-channels "${CONDA_PKGS[@]}"
  fi
  "$MAMBA" clean -y -a -q >/dev/null 2>&1 || true
}

# ---------- individual tools ----------
install_nvim() {
  if [ "$(pick_backend $GLIBC_NVIM)" = conda ]; then CONDA_PKGS+=(nvim); NVIM_FROM=conda; return; fi
  local tag; tag=$(gh_latest neovim/neovim)
  log "neovim $tag (GitHub)"
  fetch "https://github.com/neovim/neovim/releases/download/$tag/nvim-linux-$NVIM_ARCH.tar.gz" "$TMP/nvim.tgz"
  rm -rf "$OPT/nvim"; mkdir -p "$OPT/nvim"
  tar xzf "$TMP/nvim.tgz" -C "$OPT/nvim" --strip-components=1
  link_bin "$OPT/nvim/bin/nvim" nvim
  NVIM_FROM=github
}

install_treesitter() {
  if [ "$(pick_backend $GLIBC_TS)" = conda ]; then CONDA_PKGS+=(tree-sitter-cli); return; fi
  local tag; tag=$(gh_latest tree-sitter/tree-sitter)
  log "tree-sitter CLI $tag (GitHub)"
  fetch "https://github.com/tree-sitter/tree-sitter/releases/download/$tag/tree-sitter-linux-$TS_ARCH.gz" "$TMP/ts.gz"
  mkdir -p "$OPT/tree-sitter"
  gunzip -c "$TMP/ts.gz" > "$OPT/tree-sitter/tree-sitter"
  chmod +x "$OPT/tree-sitter/tree-sitter"
  link_bin "$OPT/tree-sitter/tree-sitter" tree-sitter
}

install_ripgrep() {
  local tag; tag=$(gh_latest BurntSushi/ripgrep)
  log "ripgrep $tag (static musl)"
  fetch "https://github.com/BurntSushi/ripgrep/releases/download/$tag/ripgrep-$tag-$RG_ARCH-unknown-linux-musl.tar.gz" "$TMP/rg.tgz"
  rm -rf "$OPT/ripgrep"; mkdir -p "$OPT/ripgrep"
  tar xzf "$TMP/rg.tgz" -C "$OPT/ripgrep" --strip-components=1
  link_bin "$OPT/ripgrep/rg" rg
}

install_fd() {
  local tag; tag=$(gh_latest sharkdp/fd)
  log "fd $tag (static musl)"
  fetch "https://github.com/sharkdp/fd/releases/download/$tag/fd-$tag-$RG_ARCH-unknown-linux-musl.tar.gz" "$TMP/fd.tgz"
  rm -rf "$OPT/fd"; mkdir -p "$OPT/fd"
  tar xzf "$TMP/fd.tgz" -C "$OPT/fd" --strip-components=1
  link_bin "$OPT/fd/fd" fd
}

install_lazygit() {
  local tag; tag=$(gh_latest jesseduffield/lazygit)
  log "lazygit $tag (static)"
  fetch "https://github.com/jesseduffield/lazygit/releases/download/$tag/lazygit_${tag#v}_linux_$LG_ARCH.tar.gz" "$TMP/lg.tgz"
  mkdir -p "$OPT/lazygit"
  tar xzf "$TMP/lg.tgz" -C "$OPT/lazygit" lazygit
  link_bin "$OPT/lazygit/lazygit" lazygit
}

install_fzf() {
  local tag; tag=$(gh_latest junegunn/fzf)
  log "fzf $tag (static)"
  fetch "https://github.com/junegunn/fzf/releases/download/$tag/fzf-${tag#v}-linux_$FZF_ARCH.tar.gz" "$TMP/fzf.tgz"
  mkdir -p "$OPT/fzf"
  tar xzf "$TMP/fzf.tgz" -C "$OPT/fzf" fzf
  link_bin "$OPT/fzf/fzf" fzf
}

install_node() {
  [ "$WITH_NODE" = 1 ] || return 0
  # keep a system node if it's recent enough and not one we installed
  if have node && [ "$(readlink -f "$(command -v node)")" != "$(readlink -f "$BIN/node" 2>/dev/null)" ]; then
    local cur; cur=$(node --version | tr -d v)
    if ver_ge "$cur" "$NODE_MAJOR_MIN"; then ok "using existing node v$cur"; return; fi
    warn "existing node v$cur is older than $NODE_MAJOR_MIN, installing a user-local LTS"
  fi
  if [ "$(pick_backend $GLIBC_NODE)" = conda ]; then CONDA_PKGS+=("nodejs=24"); return; fi
  local idx ver
  idx=$(fetch_stdout https://nodejs.org/dist/index.json)
  ver=$(printf '%s\n' "$idx" | grep -oE '"version":"v[0-9.]+"[^}]*"lts":"[A-Za-z]+"' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sed -n 1p)
  [ -n "$ver" ] || die "cannot resolve latest Node.js LTS"
  log "node $ver LTS (nodejs.org)"
  fetch "https://nodejs.org/dist/$ver/node-$ver-linux-$NODE_ARCH.tar.xz" "$TMP/node.txz"
  rm -rf "$OPT/node"; mkdir -p "$OPT/node"
  tar xJf "$TMP/node.txz" -C "$OPT/node" --strip-components=1
  for b in node npm npx; do link_bin "$OPT/node/bin/$b" "$b"; done
}

install_cc() {
  # nvim-treesitter compiles parsers with `tree-sitter build`, which needs a C compiler
  if [ "$BACKEND" != conda ]; then
    for c in cc gcc clang; do
      if have "$c"; then ok "C compiler: $(command -v "$c")"; return; fi
    done
  fi
  warn "no C compiler found, installing gcc from conda-forge"
  CONDA_PKGS+=(gcc)
  NEED_CONDA_CC=1
}

link_conda_bins() {
  [ -d "$CONDA_ENV/bin" ] || return 0
  local b
  for b in nvim tree-sitter node npm npx; do
    [ -e "$CONDA_ENV/bin/$b" ] && link_bin "$CONDA_ENV/bin/$b" "$b"
  done
  if [ "${NEED_CONDA_CC:-0}" = 1 ]; then
    local gcc_bin=""
    if [ -e "$CONDA_ENV/bin/gcc" ]; then gcc_bin="$CONDA_ENV/bin/gcc"
    else gcc_bin=$(ls "$CONDA_ENV"/bin/*-conda-linux-gnu-gcc 2>/dev/null | head -1); fi
    [ -n "$gcc_bin" ] || die "conda gcc installed but no gcc binary found"
    link_bin "$gcc_bin" cc
    link_bin "$gcc_bin" gcc
  fi
}

# ---------- shell rc ----------
RC_BEGIN="# >>> lazyvim-nosudo >>>"
RC_END="# <<< lazyvim-nosudo <<<"

setup_rc() {
  [ "$WITH_RC" = 1 ] || return 0
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || { [ "$rc" = "$HOME/.bashrc" ] || continue; touch "$rc"; }
    remove_rc_block "$rc"
    cat >> "$rc" <<EOF
$RC_BEGIN
export PATH="$BIN:\$PATH"
export EDITOR=nvim
$RC_END
EOF
    ok "PATH block written to $rc"
  done
}

remove_rc_block() {
  [ -f "$1" ] || return 0
  if grep -qF "$RC_BEGIN" "$1"; then
    sed -i "/^$RC_BEGIN\$/,/^$RC_END\$/d" "$1"
  fi
}

# ---------- nvim config ----------
NVIM_DIRS=("$HOME/.config/nvim" "$HOME/.local/share/nvim" "$HOME/.local/state/nvim" "$HOME/.cache/nvim")

backup_nvim_dirs() {
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  local d
  for d in "${NVIM_DIRS[@]}"; do
    if [ -e "$d" ]; then
      mv "$d" "$d.bak-$ts"
      ok "backed up $d -> $d.bak-$ts"
    fi
  done
}

install_starter() {
  [ "$WITH_CONFIG" = 1 ] || return 0
  have git || die "git is required"
  backup_nvim_dirs
  log "cloning LazyVim starter"
  git clone --depth 1 -q "$STARTER_REPO" "$HOME/.config/nvim"
  rm -rf "$HOME/.config/nvim/.git"
  ok "config at ~/.config/nvim"
}

bootstrap() {
  [ "$WITH_CONFIG" = 1 ] && [ "$BOOTSTRAP" = 1 ] || return 0
  local nvim="$BIN/nvim"
  export PATH="$BIN:$PATH"
  log "installing plugins (headless Lazy sync)"
  "$nvim" --headless "+Lazy! sync" +qa 2>&1 | tail -5; echo || warn "Lazy sync reported errors"

  # LazyVim starts async parser installs during the sync above, and +qa can kill
  # them half-way, so install synchronously and retry until nothing is missing.
  local i missing
  for i in 1 2 3; do
    log "installing treesitter parsers (pass $i)"
    "$nvim" --headless \
      -c 'lua local ok, err = pcall(function()
            require("nvim-treesitter").install(LazyVim.opts("nvim-treesitter").ensure_installed or {}, { summary = true }):wait(900000)
          end)
          if not ok then io.stderr:write("treesitter: " .. tostring(err) .. "\n") end' \
      -c 'qa' 2>&1 | grep -E -i 'error|installed [0-9]+/' || true
    missing=$("$nvim" --headless \
      -c 'lua local ts = require("nvim-treesitter")
          local have = {}
          for _, l in ipairs(ts.get_installed()) do have[l] = true end
          local miss = {}
          for _, l in ipairs(LazyVim.opts("nvim-treesitter").ensure_installed or {}) do
            if not have[l] then miss[#miss + 1] = l end
          end
          io.stdout:write(table.concat(miss, " "))' \
      -c 'qa' 2>/dev/null) || true
    [ -z "$missing" ] && { ok "all treesitter parsers installed"; break; }
    warn "missing parsers: $missing"
  done

  log "installing Mason tools"
  "$nvim" --headless \
    -c 'lua local ok, err = pcall(function()
          require("lazy").load({ plugins = { "mason.nvim" } })
          local want = LazyVim.opts("mason.nvim").ensure_installed or {}
          if #want > 0 then vim.cmd("MasonInstall " .. table.concat(want, " ")) end
        end)
        if not ok then io.stderr:write("mason: " .. tostring(err) .. "\n") end' \
    -c 'qa' 2>&1 | tail -5; echo || warn "Mason install reported errors"
}

# ---------- doctor ----------
doctor() {
  export PATH="$BIN:$PATH"
  local t p
  printf '%-12s %-45s %s\n' TOOL PATH VERSION
  for t in nvim git tree-sitter cc rg fd lazygit fzf node npm curl unzip tar; do
    if p=$(command -v "$t" 2>/dev/null); then
      local v
      case $t in
        unzip) v=$(unzip -v 2>&1 | sed -n 1p) || true ;;
        *)     v=$("$t" --version 2>&1 | sed -n 1p) || true ;;
      esac
      printf '%-12s %-45s %s\n' "$t" "$p" "$v"
    else
      printf '%-12s %s\n' "$t" "${c_red}missing${c_off}"
    fi
  done
  if [ -d "$HOME/.local/share/nvim/site/parser" ]; then
    echo "treesitter parsers: $(ls "$HOME/.local/share/nvim/site/parser" | wc -l)"
  fi
}

# ---------- uninstall ----------
uninstall() {
  log "removing tools in $OPT and their symlinks in $BIN"
  local l
  for l in "$BIN"/*; do
    [ -L "$l" ] || continue
    case "$(readlink "$l")" in "$OPT"/*) rm -f "$l"; ok "removed $l" ;; esac
  done
  rm -rf "$OPT"
  remove_rc_block "$HOME/.bashrc"; remove_rc_block "$HOME/.zshrc"
  backup_nvim_dirs
  ok "uninstalled (nvim config/data moved to *.bak-*)"
}

# ---------- main ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --backend) BACKEND="$2"; shift ;;
    --backend=*) BACKEND="${1#*=}" ;;
    --no-node) WITH_NODE=0 ;;
    --no-config) WITH_CONFIG=0 ;;
    --no-rc) WITH_RC=0 ;;
    --skip-bootstrap) BOOTSTRAP=0 ;;
    --uninstall) ACTION=uninstall ;;
    --doctor) ACTION=doctor ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
case "$BACKEND" in auto|github|conda) ;; *) die "--backend must be auto, github or conda" ;; esac

case "$ACTION" in
  doctor) doctor; exit 0 ;;
  uninstall) uninstall; exit 0 ;;
esac

detect_platform
for t in git tar gzip; do have "$t" || die "$t is required"; done
have unzip || warn "unzip not found: some Mason packages will fail to install"

mkdir -p "$BIN" "$OPT"
NVIM_FROM=""
install_nvim
install_treesitter
install_ripgrep
install_fd
install_lazygit
install_fzf
install_node
install_cc
install_conda_pkgs
link_conda_bins

setup_rc
install_starter
"$BIN/nvim" --version >/dev/null 2>&1 || die "nvim does not run on this host"
ok "$("$BIN/nvim" --version | sed -n 1p)"
bootstrap

echo
doctor
echo
ok "done. open a new shell (or: source ~/.bashrc) and run: nvim"
