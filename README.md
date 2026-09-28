# LazyVim 설치 가이드 (sudo 불필요)

`apt`와 `sudo` 없이 LazyVim과 필요한 도구를 모두 `~/.local` 아래에 설치합니다.
권한이 없는 원격 서버나 공용 클러스터에서도 같은 방식으로 쓸 수 있습니다.

## 빠른 시작

### 한 줄 설치

```bash
curl -fsSL https://raw.githubusercontent.com/BooMinSeong/lazyvim_install/main/install.sh | bash
source ~/.bashrc
nvim
```

옵션은 `bash -s --` 뒤에 붙입니다.

```bash
curl -fsSL https://raw.githubusercontent.com/BooMinSeong/lazyvim_install/main/install.sh | bash -s -- --backend conda
```

`curl`이 없으면 `wget -qO- <URL> | bash`를 쓰세요.

### 파일로 받아서 실행

GitHub에 접근할 수 없는 서버에서 쓰거나, 스크립트 내용을 먼저 확인하고 싶을 때 사용합니다.

```bash
# 로컬 PC에서 서버로 스크립트 복사
scp install.sh myserver:~/

# 서버에서 실행
bash ~/install.sh
source ~/.bashrc
nvim
```

설치가 끝나면 플러그인, treesitter 파서, Mason 도구까지 headless 모드로 미리 설치되어 있습니다.
따라서 처음 `nvim`을 실행할 때 설치를 기다리지 않아도 됩니다.

## 서버에 미리 있어야 하는 것

| 도구 | 용도 | 비고 |
|---|---|---|
| `git` ≥ 2.19 | lazy.nvim의 partial clone | 거의 모든 서버에 있음 |
| `curl` 또는 `wget` | 다운로드 | |
| `tar`, `gzip` | 압축 해제 | |
| `unzip` | 일부 Mason 패키지 | 없으면 경고만 출력 |

C 컴파일러(`cc`/`gcc`/`clang`)가 없으면 스크립트가 conda-forge에서 `gcc`를 자동으로 설치합니다.

## 설치되는 것

| 도구 | 출처 | 비고 |
|---|---|---|
| neovim | GitHub 릴리스 / conda-forge | 호스트 glibc ≥ 2.34이면 GitHub에서 받음 |
| tree-sitter CLI | GitHub 릴리스 / conda-forge | 호스트 glibc ≥ **2.39**이면 GitHub에서 받음 |
| node (LTS) | nodejs.org / conda-forge | 시스템 node가 v20 이상이면 그대로 사용 |
| C 컴파일러 | 시스템 / conda-forge `gcc` | 파서 컴파일에 필요 |
| ripgrep, fd | GitHub (musl 정적 빌드) | glibc와 무관 |
| lazygit, fzf | GitHub (Go 정적 빌드) | glibc와 무관 |
| LazyVim starter | github.com/LazyVim/starter | `~/.config/nvim` |

### 왜 백엔드가 두 가지인가

공식 바이너리가 요구하는 glibc 버전은 `objdump -T`로 확인했습니다. 구형 서버에서는 공식 바이너리가 실행되지 않습니다.

| 배포판 | glibc | nvim 공식 | tree-sitter 공식 |
|---|---|---|---|
| Ubuntu 24.04 | 2.39 | ✅ | ✅ |
| Ubuntu 22.04 | 2.35 | ✅ | ❌ → conda |
| Ubuntu 20.04 | 2.31 | ❌ → conda | ❌ → conda |
| RHEL/Rocky 8 | 2.28 | ❌ → conda | ❌ → conda |
| CentOS 7 | 2.17 | ❌ → conda | ❌ → conda |

`--backend auto`(기본값)는 도구별로 호스트 glibc를 비교해서 공식 바이너리를 쓸 수 없는 도구만 conda-forge에서 받습니다.
conda-forge 패키지는 오래된 glibc 기준으로 빌드되어 있습니다.
conda 설치에는 정적 바이너리인 `micromamba`를 쓰므로 Anaconda나 Miniconda가 필요 없습니다.

> conda 백엔드로 `gcc`까지 받으면 디스크를 약 1.2GB 사용합니다. 서버에 이미 `gcc`가 있으면 이 부분은 설치하지 않습니다.

## 옵션

```
--backend auto|github|conda  glibc 의존 도구의 출처 (기본 auto)
--no-node                    Node.js 설치 생략 (pyright 같은 일부 LSP는 node 필요)
--no-config                  도구만 설치하고 nvim 설정은 건드리지 않음 (dotfiles를 따로 관리할 때)
--no-rc                      ~/.bashrc, ~/.zshrc 수정 안 함
--skip-bootstrap             headless 플러그인/파서/Mason 사전 설치 생략
--doctor                     각 도구가 어디서 실행되는지와 버전 출력
--uninstall                  이 스크립트로 설치한 도구 삭제 (nvim 설정은 백업)
```

설치 위치는 `LAZYVIM_PREFIX=/path bash install.sh` 형식으로 바꿀 수 있습니다 (기본값 `~/.local`).

## 디렉터리 구조

```
~/.local/bin/                 nvim, rg, fd, lazygit, fzf, tree-sitter, node, npm (심볼릭 링크)
~/.local/opt/lazyvim-tools/   실제 바이너리 (nvim/, ripgrep/, conda/, micromamba ...)
~/.config/nvim/               LazyVim 설정 (starter)
~/.local/share/nvim/          플러그인(lazy/), 파서(site/parser/), Mason 도구(mason/)
```

`~/.bashrc`와 `~/.zshrc`에는 아래 블록 하나만 추가됩니다. 스크립트를 다시 실행해도 블록이 중복되지 않습니다.

```bash
# >>> lazyvim-nosudo >>>
export PATH="$HOME/.local/bin:$PATH"
export EDITOR=nvim
# <<< lazyvim-nosudo <<<
```

## 기존 설치 처리

스크립트는 기존 LazyVim/nvim 데이터를 **삭제하지 않고** 타임스탬프를 붙여 백업합니다.

```
~/.config/nvim      -> ~/.config/nvim.bak-YYYYmmdd-HHMMSS
~/.local/share/nvim -> ~/.local/share/nvim.bak-...
~/.local/state/nvim -> ~/.local/state/nvim.bak-...
~/.cache/nvim       -> ~/.cache/nvim.bak-...
```

- 최근 파일 기록(`~/.local/state/nvim/shada`)은 새 설치에도 복사합니다. `<leader>fp` Projects 목록이 이 기록으로 만들어지기 때문입니다.
- 기존 `lua/config/*.lua`나 `lua/plugins/*.lua`를 수정해서 쓰고 있었다면 백업에서 새 `~/.config/nvim`으로 옮기세요.
- `/opt`, `/usr/local/bin`처럼 root 권한으로 설치한 nvim/lazygit은 지울 수 없습니다. `~/.local/bin`이 PATH 맨 앞에 있으므로 새로 설치한 버전이 우선 실행됩니다.
- 스크립트를 다시 실행하면 그 시점의 설정도 새로 백업되고, 설정은 LazyVim starter로 다시 설치됩니다. 도구만 업데이트하려면 `--no-config`를 쓰세요.
- 이전 설치에서 `~/.bashrc`에 직접 넣은 PATH 줄(예: `/opt/nvim-linux-x86_64/bin`)은 수정하지 않습니다. 새 PATH 블록이 앞쪽에 오므로 동작에는 영향이 없지만, 정리하려면 해당 줄을 직접 지우세요.
- 문제가 없는 것을 확인했다면 백업은 `rm -rf ~/.config/nvim.bak-* ~/.local/share/nvim.bak-* ~/.local/state/nvim.bak-* ~/.cache/nvim.bak-*`로 지우면 됩니다.

## 설치 확인

```bash
bash install.sh --doctor        # 각 도구 경로와 버전 확인
nvim +"checkhealth lazyvim"     # 모든 항목이 OK여야 함
```

`:checkhealth snacks`에 나오는 `magick`, `mmdc`, kitty graphics 오류는 이미지와 다이어그램 렌더링용 선택 기능이므로 무시해도 됩니다.

## 문제 해결

**일부 treesitter 파서가 누락됨 (`ENOTEMPTY: Could not rename temp`)**
`Lazy! sync` 단계에서 LazyVim이 비동기로 파서 설치를 시작합니다. 이때 headless nvim이 종료되면 설치가 중간 상태로 남을 수 있습니다.
스크립트는 누락된 파서를 확인하면서 최대 3회 재시도합니다. 그래도 누락되면 nvim 안에서 `:TSUpdate`를 실행하세요.

**`<leader>fp` Projects 목록이 비어 있음**
Projects 목록은 최근에 연 파일 중 `.git`, `package.json`, `Makefile` 등이 있는 루트 폴더와 `~/dev`, `~/projects` 아래 폴더로 만들어집니다.
새 서버에서는 기록이 없어 목록이 비어 있으니, 프로젝트 파일을 몇 개 열어보면 목록이 채워집니다.
이전 버전의 스크립트로 재설치해서 기록이 사라졌다면 백업에서 복원하세요:
`cp -a ~/.local/state/nvim.bak-<날짜>/shada ~/.local/state/nvim/`

**`nvim does not run on this host`**
`--backend conda`로 다시 실행하세요.

**GitHub 접근이 막힌 서버**
프록시가 있으면 `export https_proxy=http://proxy:port`를 설정한 뒤 실행하세요.
인터넷이 전혀 안 되는 서버에서는 같은 아키텍처와 비슷한 glibc를 가진 머신에서 설치한 뒤 `~/.local/opt/lazyvim-tools`, `~/.local/share/nvim`, `~/.config/nvim`을 통째로 복사하면 됩니다.

**아이콘이 깨져 보임**
Nerd Font는 서버가 아니라 **SSH 접속에 쓰는 로컬 터미널**에 설치해야 합니다.

**NFS 홈 디렉터리가 느린 경우**
`LAZYVIM_PREFIX=/scratch/$USER/.local`처럼 로컬 디스크를 지정할 수 있습니다. 이 경우 nvim 데이터는 XDG 기본값인 `~/.local/share/nvim`에 그대로 남습니다.

## 검증한 환경

2026-09-28, Ubuntu 24.04 x86_64 (glibc 2.39) 기준:
- `--backend github`: 격리된 HOME에서 처음부터 설치하고 checkhealth lazyvim 전 항목 OK 확인
- `--backend conda`: 시스템 gcc를 쓰지 않고 conda gcc로 파서 24개 컴파일 성공
- `--uninstall`: 심볼릭 링크, 도구, rc 블록 제거 후 설정 백업 확인
- 실제 설치: nvim 0.12.5, tree-sitter 0.27.0, node 24.21.0, rg 15.2.0, fd 10.5.0, lazygit 0.65.1, fzf 0.74.4

실제 구형 glibc 서버(RHEL8, CentOS7 등)와 aarch64 환경에서는 아직 실행해보지 않았습니다.
