#!/usr/bin/env bash
#
# DevKit AI 一体化安装配置脚本（在目标鲲鹏服务器上运行）
# 职责：下载包 → 安装（devkitai 本体 / skills 包 / TUI）→ 配置 config.yaml → 更新 skills → 启动 server
#
# 用法：$0 [all|download|install|config|update|start]
#   all      = download && install && config && update && start（默认）
#   download = 下载 devkitai / skills / TUI 安装包
#   install  = 安装 devkitai 本体、skills 包、TUI
#   config   = 交互式配置 config.yaml（模型 / 上下文 / server 端口）
#   update   = 更新 skills
#   start    = 启动 devkitai server（就绪轮询），并可联动启动 TUI
#
set -euo pipefail

# ==================== 变量区（运行前按环境填写） ====================
# --- 下载/安装相关 ---
# devkitai 后端安装包直链（华为云 OBS）
DEVKITAI_URL="${DEVKITAI_URL:-https://kunpeng-repo.obs.cn-north-4.myhuaweicloud.com/Kunpeng%20DevKit/Kunpeng%20DevKit%2026.2.T103/DevKit-AI-26.2.T103-Linux-Kunpeng.tar.gz}"
SKILLS_URL="${SKILLS_URL:-}"
# TUI 前端：默认留空，运行时通过 GitCode releases API 自动解析；也可用 TUI_URL 显式指定直链
TUI_URL="${TUI_URL:-}"
TUI_REPO="${TUI_REPO:-Blackn/DevKit_AI_Frontend_Release}"  # TUI 的 GitCode 仓库（owner/repo）
TUI_VERSION="${TUI_VERSION:-0.4.3}"                        # 解析失败时兜底使用的版本号

DEVKITAI_FNAME="${DEVKITAI_FNAME:-}"
SKILLS_FNAME="${SKILLS_FNAME:-}"
TUI_FNAME="${TUI_FNAME:-}"

LOGIN_USER="${LOGIN_USER:-${SUDO_USER:-${USER:-$(id -un)}}}"
INSTALL_DIR="${INSTALL_DIR:-${HOME}/devkitai}"   # devkitai 本体安装目录
PUSH_DIR="${PUSH_DIR:-${HOME}/.devkitai/pkgs}"   # skills 包存放目录
DOWN_DIR="${DOWN_DIR:-${HOME}/.devkitai/downloads}"

# --- 配置相关 ---
CONFIG_YAML="${CONFIG_YAML:-}"   # 默认自动指向 devkitai 解压目录内 config/config.yaml

# 默认获取当前 host IP
IFACE_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
[ -n "${IFACE_IP}" ] || IFACE_IP="0.0.0.0"
HOST_BIND="${HOST_BIND:-${IFACE_IP}}"

# server.port 支持环境变量覆盖；为空时自动分配空闲端口
DEVKITAI_SERVICE_PORT="${DEVKITAI_SERVICE_PORT:-}"

# chat 大模型默认值配置
CHAT_MODEL_NAME="${CHAT_MODEL_NAME:-}"
CHAT_MODEL_PROVIDER="${CHAT_MODEL_PROVIDER:-}"
CHAT_MODEL_ID="${CHAT_MODEL_ID:-}"
CHAT_BASE_URL="${CHAT_BASE_URL:-}"
CHAT_API_KEY_PLAIN="${CHAT_API_KEY_PLAIN:-}"

# 上下文最大 Token 默认值
MAX_CONTEXT_TOKENS="${MAX_CONTEXT_TOKENS:-1000000}"

# ==================== 小工具 ====================
say() { printf '\033[1;32m[%s]\033[0m %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '\033[1;33m[%s] WARN: %s\033[0m\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '\033[1;31m[%s] ERROR: %s\033[0m\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }
section() { printf '\n\033[1;36m================ %s ================\033[0m\n' "$*"; }

extract_fname() {
  local u="$1"
  [ -n "${u}" ] || { echo ""; return 0; }
  basename "${u%%\?*}"
}

devkitai_fname="${DEVKITAI_FNAME:-$(extract_fname "${DEVKITAI_URL}")}"
skills_fname="${SKILLS_FNAME:-$(extract_fname "${SKILLS_URL}")}"
tui_fname="${TUI_FNAME:-$(extract_fname "${TUI_URL}")}"

# 增强型查找：宽松递归查找 devkitai 可执行文件
find_devkitai_bin() {
  # 0. 优先检测指定的具体绝对路径（历史部署兼容）
  local exact_path="${HOME}/devkitai/DevKit-AI-26.2.RC1-Linux-Kunpeng/devkitai"
  if [ -x "${exact_path}" ]; then
    echo "${exact_path}"
    return 0
  fi

  local exact_path="${HOME}/devkitai/DevKit-AI-26.2.T103-Linux-Kunpeng/devkitai"
  if [ -x "${exact_path}" ]; then
    echo "${exact_path}"
    return 0
  fi

  # 0.5 增加：递归查找 ${HOME}/devkitai/ 目录下的 devkitai 可执行文件
  local home_dir="${HOME}/devkitai"
  if [ -d "${home_dir}" ]; then
    local home_hit
    home_hit="$(find "${home_dir}" -type f -name devkitai -perm -111 2>/dev/null | head -n 1)"
    if [ -n "${home_hit}" ]; then
      echo "${home_hit}"
      return 0
    fi
  fi

  # 1. 直接检查安装根目录
  if [ -x "${INSTALL_DIR}/devkitai" ]; then
    echo "${INSTALL_DIR}/devkitai"
    return 0
  fi

  # 2. 解压包顶层目录
  if [ -n "${devkitai_fname}" ]; then
    local top
    top="${INSTALL_DIR}/$(basename "${devkitai_fname}" .tar.gz)"
    if [ -x "${top}/devkitai" ]; then
      echo "${top}/devkitai"
      return 0
    fi
  fi

  # 3. 递归查找 INSTALL_DIR 下任意深度的 devkitai 可执行文件
  local hit
  hit="$(find "${INSTALL_DIR}" -maxdepth 5 -type f -name devkitai -perm -111 2>/dev/null | head -n 1)"
  if [ -n "${hit}" ]; then
    echo "${hit}"
    return 0
  fi

  # 4. 兜底检查当前用户 home 下默认位置
  if [ -x "${HOME}/devkitai/devkitai" ]; then
    echo "${HOME}/devkitai/devkitai"
    return 0
  fi

  return 1
}

# 自动推导 config.yaml 位置
find_config_yaml() {
  if [ -n "${CONFIG_YAML}" ] && [ -f "${CONFIG_YAML}" ]; then
    echo "${CONFIG_YAML}"
    return 0
  fi

  local bin_path
  bin_path="$(find_devkitai_bin 2>/dev/null || true)"
  if [ -n "${bin_path}" ]; then
    local bin_dir
    bin_dir="$(dirname "${bin_path}")"
    if [ -f "${bin_dir}/config/config.yaml" ]; then
      echo "${bin_dir}/config/config.yaml"
      return 0
    fi
  fi

  # 尝试在 INSTALL_DIR 目录下匹配
  local cfg_hit
  cfg_hit="$(find "${INSTALL_DIR}" -maxdepth 5 -type f -path "*/config/config.yaml" 2>/dev/null | head -n 1)"
  if [ -n "${cfg_hit}" ]; then
    echo "${cfg_hit}"
    return 0
  fi

  return 1
}

# 读取 config.yaml 中 server.port（无则输出空）
read_config_port() {
  local cfg
  cfg="$(find_config_yaml 2>/dev/null || true)"
  if [ -n "${cfg}" ] && [ -f "${cfg}" ]; then
    sed -n '/^server:/,/^[^ #]/p' "${cfg}" | grep -m1 -E '^\s+port: ' | awk '{print $2}' | tr -d '"'
  fi
}

is_port_free() {
  local port="$1"
  local py
  py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo none)"

  if [ "${py}" != "none" ]; then
    "${py}" - "$port" <<'PYEOF' >/dev/null 2>&1
import socket, sys
port = int(sys.argv[1])
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    try:
        s.bind(('0.0.0.0', port))
        sys.exit(0)
    except OSError:
        sys.exit(1)
PYEOF
  else
    if { { command -v ss >/dev/null 2>&1 && ss -ltn; command -v netstat >/dev/null 2>&1 && netstat -ltn; } 2>/dev/null | grep -E ":${port}([[:space:]]|$)" >/dev/null 2>&1; }; then
      return 1
    else
      return 0
    fi
  fi
}

find_free_port() {
  local start_port="${1:-8125}"
  local target_port=""
  local py
  py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo none)"

  if [ "${py}" != "none" ]; then
    target_port="$("${py}" - "$start_port" <<'PYEOF'
import socket, sys
port = int(sys.argv[1])
while port < 65535:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        try:
            s.bind(('0.0.0.0', port))
            print(port)
            sys.exit(0)
        except OSError:
            port += 1
sys.exit(1)
PYEOF
)"
  else
    local port="$start_port"
    while [ "$port" -lt 65535 ]; do
      if is_port_free "$port"; then
        target_port="$port"
        break
      fi
      port=$((port + 1))
    done
  fi

  if [ -n "${target_port}" ]; then
    echo "${target_port}"
  else
    die "Could not find an available free port"
  fi
}

# 检查关键目录对当前用户是否可写（避免 root 历史安装 / 目录属主错位导致的失败）
check_dir_writable() {
  local d="$1" label="$2" testf
  if [ -e "${d}" ] && [ ! -w "${d}" ]; then
    die "The ${label} directory ${d} is not writable by the current user ($(id -un)); it may be a leftover from a previous root installation. Run: sudo chown -R \$(id -un):\$(id -gn) ${d}"
  fi
  mkdir -p "${d}" 2>/dev/null || die "Cannot create the ${label} directory ${d} (check parent directory permissions)"
  testf="${d}/.write_test_$$"
  if ! touch "${testf}" 2>/dev/null; then
    die "The ${label} directory ${d} is not writable by the current user ($(id -un)); check ownership and permissions"
  fi
  rm -f "${testf}"
}

# 检测当前用户是否具备安装 git 的系统级权限（root / 安装了 sudo 可尝试）。
# 返回 0 表示可尝试安装；返回 1 表示无任何安装途径，调用方应跳过 git 安装步骤。
have_pkg_permission() {
  [ "$(id -u)" = "0" ] && return 0
  command -v sudo >/dev/null 2>&1 && return 0
  return 1
}

# ==================== 下载 ====================
download() {
  for _caf in "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem" "/etc/ssl/certs/ca-certificates.crt"; do
    if [ -f "${_caf}" ]; then
      export SSL_CERT_FILE="${_caf}"
      export CURL_CA_BUNDLE="${_caf}"
      break
    fi
  done
  local url="$1" dest="$2" tmp
  tmp="${dest}.part"
  if [ -s "${dest}" ]; then say "${dest##*/} already exists, skipping download"; return 0; fi
  say "Downloading: ${url##*/}"
  mkdir -p "$(dirname "${dest}")"
  curl -fSLk --retry 3 --connect-timeout 15 -o "${tmp}" "${url}" || die "Download failed: ${url##*/}"
  [ -s "${tmp}" ] || die "Downloaded an empty file: ${url##*/}"
  mv "${tmp}" "${dest}"
}

get_pkg() {
  local src="$1" dest="$2"
  case "${src}" in
    http://*|https://*)
      download "${src}" "${dest}" ;;
    *)
      if [ -s "${dest}" ]; then say "${dest##*/} already exists, skipping preparation"; return 0; fi
      [ -f "${src}" ] || die "Local path not found: ${src}"
      mkdir -p "$(dirname "${dest}")"
      cp -f "${src}" "${dest}"
      say "Ready: ${dest##*/}"
      ;;
  esac
}

# 自动解析 TUI 安装包直链：
#   1. 若显式设置了 TUI_URL，直接使用；
#   2. 否则查询 GitCode releases API，取最新匹配 linux-arm64 的安装包；
#   3. 均失败时按 TUI_VERSION 构造兜底直链。
resolve_tui_url() {
  if [ -n "${TUI_URL}" ]; then
    echo "${TUI_URL}"
    return 0
  fi

  local api_url json_file py resolved fallback_url
  api_url="https://gitcode.com/api/v5/repos/${TUI_REPO}/releases"
  json_file="$(mktemp)"
  if curl -fsSLk --retry 2 --connect-timeout 15 -o "${json_file}" "${api_url}" 2>/dev/null; then
    py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo none)"
    resolved=""
    if [ "${py}" != "none" ]; then
      resolved="$(PY_TUI_FILE="${json_file}" TUI_VERSION="${TUI_VERSION}" "${py}" - <<'PYEOF' 2>/dev/null || true
import json, os, sys
try:
    data = json.load(open(os.environ["PY_TUI_FILE"], encoding="utf-8"))
except Exception:
    sys.exit(1)
want = os.environ.get("TUI_VERSION", "")
for rel in data:
    tag = rel.get("tag_name", "") or ""
    for asset in rel.get("assets", []) or []:
        name = asset.get("name", "") or ""
        url = asset.get("browser_download_url", "") or ""
        if name.startswith("kunpeng-devkit-ai-tui-") and "linux-arm64.tar.gz" in name:
            if want and want not in tag and want not in name:
                continue
            print(url)
            sys.exit(0)
sys.exit(1)
PYEOF
)"
    else
      resolved="$(grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*kunpeng-devkit-ai-tui-[^"]*linux-arm64\.tar\.gz"' "${json_file}" 2>/dev/null | sed -E 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' | head -n 1 || true)"
    fi
    rm -f "${json_file}"
    if [ -n "${resolved}" ]; then
      say "Resolved TUI package via GitCode releases API: ${resolved##*/}" >&2
      echo "${resolved}"
      return 0
    fi
  else
    rm -f "${json_file}"
  fi

  fallback_url="https://gitcode.com/${TUI_REPO}/releases/download/v${TUI_VERSION}/kunpeng-devkit-ai-tui-${TUI_VERSION}-linux-arm64.tar.gz"
  warn "Unable to auto-resolve the TUI direct link; will use the v${TUI_VERSION} package (set the TUI_URL environment variable to specify a direct link if this fails)" >&2
  echo "${fallback_url}"
}

cmd_download() {
  [ -n "${DEVKITAI_URL}" ] || die "DEVKITAI_URL is not set"
  check_dir_writable "${DOWN_DIR}" "download"

  section "Downloading packages (saved to ${DOWN_DIR})"

  if [ -n "${DEVKITAI_URL}" ]; then
    devkitai_fname="${DEVKITAI_FNAME:-$(extract_fname "${DEVKITAI_URL}")}"
    say "----- devkitai backend -----"
    get_pkg "${DEVKITAI_URL}" "${DOWN_DIR}/${devkitai_fname}"
  fi

  if [ -n "${SKILLS_URL}" ]; then
    skills_fname="${SKILLS_FNAME:-$(extract_fname "${SKILLS_URL}")}"
    say "----- skills package -----"
    get_pkg "${SKILLS_URL}" "${DOWN_DIR}/${skills_fname}"
  fi

  # --- DevKit AI TUI ---
  # 先按既定命名规则推导预期文件名，若包已存在于下载目录则直接跳过解析与下载
  local tui_url tui_pkg
  if [ -n "${TUI_FNAME}" ]; then
    tui_pkg="${DOWN_DIR}/${TUI_FNAME}"
  elif [ -n "${TUI_URL}" ]; then
    tui_pkg="${DOWN_DIR}/$(extract_fname "${TUI_URL}")"
  else
    tui_pkg="${DOWN_DIR}/kunpeng-devkit-ai-tui-${TUI_VERSION}-linux-arm64.tar.gz"
  fi
  tui_fname="${tui_pkg##*/}"

  if [ -s "${tui_pkg}" ]; then
    say "----- DevKit AI TUI -----"
    say "${tui_fname} already exists in ${DOWN_DIR}, skipping download"
  else
    tui_url="$(resolve_tui_url)"
    if [ -n "${tui_url}" ]; then
      tui_fname="${TUI_FNAME:-$(extract_fname "${tui_url}")}"
      say "----- DevKit AI TUI -----"
      get_pkg "${tui_url}" "${DOWN_DIR}/${tui_fname}"
    fi
  fi

  say "Download complete, package directory: ${DOWN_DIR}"
}

# ==================== 安装 ====================
cmd_install() {
  local devkit_bin
  devkit_bin="$(find_devkitai_bin 2>/dev/null || true)"
  check_dir_writable "${INSTALL_DIR}" "install"
  check_dir_writable "${PUSH_DIR}" "skills"

  section "Installing devkitai"
  if [ -n "${devkit_bin}" ] && [ -x "${devkit_bin}" ]; then
    say "Already installed: ${devkit_bin}, skipping extraction"
  else
    if [ -n "${devkitai_fname}" ] && [ -s "${DOWN_DIR}/${devkitai_fname}" ]; then
      say "Extracting ${devkitai_fname} → ${INSTALL_DIR}"
      mkdir -p "${INSTALL_DIR}"
      tar -xzf "${DOWN_DIR}/${devkitai_fname}" -C "${INSTALL_DIR}"
    else
      die "Missing package ${devkitai_fname}; run download first or check ${DOWN_DIR}"
    fi
    devkit_bin="$(find_devkitai_bin 2>/dev/null || true)"
  fi
  [ -n "${devkit_bin}" ] && [ -x "${devkit_bin}" ] || die "devkitai executable not found; check ${INSTALL_DIR} and the downloaded package"
  say "devkitai executable: ${devkit_bin}"

  section "Placing skills package"
  if [ -n "${skills_fname}" ] && [ -s "${DOWN_DIR}/${skills_fname}" ]; then
    if [ -s "${PUSH_DIR}/${skills_fname}" ]; then
      say "${PUSH_DIR}/${skills_fname} already exists, skipping"
    else
      say "Placing ${skills_fname} → ${PUSH_DIR}/"
      mkdir -p "${PUSH_DIR}"
      cp -f "${DOWN_DIR}/${skills_fname}" "${PUSH_DIR}/"
    fi
  else
    say "No skills package configured (SKILLS_URL is empty), skipping"
  fi

  section "Installing DevKit AI TUI"
  local tui_installed="false"

  # 若 tui_fname 为空，尝试从下载目录扫描，或重新解析 URL
  if [ -z "${tui_fname}" ]; then
    local hit
    hit="$(find "${DOWN_DIR}" -maxdepth 1 -type f -name 'kunpeng-devkit-ai-tui-*linux-arm64.tar.gz' 2>/dev/null | head -n 1)"
    if [ -n "${hit}" ]; then
      tui_fname="$(basename "${hit}")"
      say "TUI package recognized from download directory: ${tui_fname}"
    fi
  fi

  if [ -x "${HOME}/.local/bin/devkitai-tui" ]; then
    say "devkitai-tui already installed → ${HOME}/.local/bin/devkitai-tui, skipping"
    tui_installed="true"
  elif [ -n "${tui_fname}" ] && [ -s "${DOWN_DIR}/${tui_fname}" ]; then
    say "Installing DevKit AI TUI (${tui_fname})"
    local tui_dir install_sh
    tui_dir="$(mktemp -d)"
    tar -xzf "${DOWN_DIR}/${tui_fname}" -C "${tui_dir}"
    install_sh="$(find "${tui_dir}" -maxdepth 3 -type f -name install.sh 2>/dev/null | head -n 1)"
    if [ -z "${install_sh}" ]; then
      rm -rf "${tui_dir}"
      say "Warning: install.sh not found in the TUI package (${tui_fname}), skipping TUI installation"
    else
      ( cd "$(dirname "${install_sh}")" && ./install.sh )
      rm -rf "${tui_dir}"
      tui_installed="true"
    fi
  else
    say "TUI package not downloaded, skipping TUI installation"
  fi

  if [ "${tui_installed}" = "true" ]; then
    case ":${PATH}:" in
      *":${HOME}/.local/bin:"*) ;;
      *)
        export PATH="${HOME}/.local/bin:${PATH}"
        if [ -x "${HOME}/.local/bin/devkitai-tui" ] && ln -sf "${HOME}/.local/bin/devkitai-tui" /usr/local/bin/devkitai-tui 2>/dev/null; then
          say "Global command created: /usr/local/bin/devkitai-tui (available in any terminal)"
        else
          local rc_path
          case "${SHELL:-}" in
            *zsh*) rc_path="${HOME}/.zshrc" ;;
            *)     rc_path="${HOME}/.bashrc" ;;
          esac
          if ! grep -qs '\.local/bin' "${rc_path}" 2>/dev/null; then
            printf '# DevKit AI TUI\nexport PATH="${HOME}/.local/bin:${PATH}"\n' >> "${rc_path}"
            say "Added ${HOME}/.local/bin to ${rc_path} (run \"source ${rc_path}\" or re-login to apply); the current session PATH has been temporarily updated"
          else
            say "The current session PATH has been temporarily updated (${rc_path} already contains this setting; run \"source ${rc_path}\" to apply immediately)"
          fi
        fi
        ;;
    esac
  fi

  section "Installation complete"
  say "devkitai / skills / TUI are ready; run ./devkitai-setup.sh config to configure"
}

# ==================== 配置 config.yaml ====================
ask_val() {
  local desc="$1" var="$2" cur="$3" input="" ch stty_g
  printf '    %-20s [%s]: ' "${desc}" "${cur}"
  stty_g="$(stty -F /dev/tty -g 2>/dev/null || true)"
  if [ -n "${stty_g}" ]; then
    stty -F /dev/tty -icanon -echo min 1 time 0 2>/dev/null || true
  fi
  while IFS= read -r -s -N1 ch </dev/tty 2>/dev/null; do
    case "${ch}" in
      $'\r'|$'\n'|$'\4'|"") break ;;
      $'\3') printf '\n^C\n' >&2;
             [ -n "${stty_g}" ] && stty -F /dev/tty "${stty_g}" 2>/dev/null || true
             exit 130 ;;
      $'\177'|$'\b')
             if [ -n "${input}" ]; then
               input="${input%?}"
               printf '\b \b'
             fi
             ;;
      $'\x1b')
             # 丢弃整个 ESC 转义序列（方向键/Home/End/F键/括号粘贴包装符），避免其字节混入输入值
             local ch2
             IFS= read -r -s -N1 ch2 </dev/tty 2>/dev/null || true
             case "${ch2}" in
               $'[')
                 # CSI 序列：继续读到终止字节（0x40-0x7E）
                 while IFS= read -r -s -N1 ch2 </dev/tty 2>/dev/null; do
                   case "${ch2}" in
                     $'\r'|$'\n'|$'\3'|$'\4') break ;;
                     [@-~]) break ;;
                   esac
                 done
                 ;;
               $']')
                 # OSC 序列：读到 BEL 或 ESC \ 结束
                 while IFS= read -r -s -N1 ch2 </dev/tty 2>/dev/null; do
                   case "${ch2}" in
                     $'\r'|$'\n'|$'\3'|$'\4') break ;;
                     $'\a') break ;;
                     $'\x1b')
                       IFS= read -r -s -N1 ch2 </dev/tty 2>/dev/null || true
                       [ "${ch2}" = '\' ] && break
                       ;;
                   esac
                 done
                 ;;
               *) ;;
             esac
             ;;
      *) input="${input}${ch}"; printf '%s' "${ch}" ;;
    esac
  done
  printf '\n'
  [ -n "${stty_g}" ] && stty -F /dev/tty "${stty_g}" 2>/dev/null || true
  # 字段为空时保留默认值；必须返回 0，否则 set -e 会在用户直接回车时中断整个脚本
  if [ -n "${input}" ]; then
    eval "${var}='${input}'"
  fi
  return 0
}

ask_chat_config() {
  local py cur_model="" cur_provider="" cur_base="" cur_key=""
  py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo none)"

  if [ "${py}" != "none" ]; then
    while IFS=$'\t' read -r k v; do
      case "${k}" in
        model)          cur_model="${v}" ;;
        model_provider) cur_provider="${v}" ;;
        base_url)       cur_base="${v}" ;;
        api_key)        cur_key="${v}" ;;
      esac
    done < <(CHAT_CFG="${CONFIG_YAML}" "${py}" - <<'PYX'
import re, os
cfg_path = os.environ.get("CHAT_CFG", "")
vals, in_chat, record_count = {}, False, 0
if os.path.exists(cfg_path):
    with open(cfg_path, encoding="utf-8") as f:
        for line in f:
            l_str = line.strip()
            if l_str == "chat_models:":
                in_chat = True
                continue
            if not in_chat:
                continue
            if not l_str or l_str.startswith("#"):
                continue
            if not line.startswith((" ", "\t", "-")):
                break
            if l_str.startswith("-"):
                record_count += 1
                if record_count > 1:
                    break
            m = re.search(r'(name|model|model_provider|base_url|api_key):\s*"?(.*?)"?\s*(?:#.*)?$', l_str)
            if m:
                k, v = m.group(1), m.group(2).strip()
                if k not in vals:
                    vals[k] = v

for k in ("name", "model", "model_provider", "base_url", "api_key"):
    print("%s\t%s" % (k, vals.get(k, "")))
PYX
)
  fi

  # 1. model 默认值（name 字段直接使用 model 的值，无需单独填写）
  CHAT_MODEL_ID="${CHAT_MODEL_ID:-${cur_model}}"
  CHAT_MODEL_ID="${CHAT_MODEL_ID:-deepseek-flash}"

  # 2. model_provider 默认值
  CHAT_MODEL_PROVIDER="${CHAT_MODEL_PROVIDER:-${cur_provider}}"
  CHAT_MODEL_PROVIDER="${CHAT_MODEL_PROVIDER:-deepseek}"

  # 3. base_url 默认值
  CHAT_BASE_URL="${CHAT_BASE_URL:-${cur_base}}"
  CHAT_BASE_URL="${CHAT_BASE_URL:-https://api.deepseek.com}"

  # 4. api_key：优先环境变量，其次读取现有配置；均无则留空由用户输入（空则保留 config 原 key）
  CHAT_API_KEY_PLAIN="${CHAT_API_KEY_PLAIN:-${cur_key}}"

  ask_val "model"          CHAT_MODEL_ID "${CHAT_MODEL_ID}"
  ask_val "model_provider" CHAT_MODEL_PROVIDER "${CHAT_MODEL_PROVIDER}"
  ask_val "base_url"       CHAT_BASE_URL "${CHAT_BASE_URL}"
  ask_val "api_key"        CHAT_API_KEY_PLAIN "${CHAT_API_KEY_PLAIN}"
  # name 直接沿用 model 的值
  CHAT_MODEL_NAME="${CHAT_MODEL_ID}"
  if [ -z "${CHAT_API_KEY_PLAIN}" ]; then
    say "Note: no new api_key provided; the chat_models record keeps its original api_key"
  fi
}

ask_context_config() {
  local py cur_tokens=""
  py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo none)"
  if [ "${py}" != "none" ]; then
    cur_tokens="$("${py}" - <<'PYX'
import re, os
lines = open(os.environ.get("CONFIG_YAML", ""), encoding="utf-8").read().splitlines() if os.environ.get("CONFIG_YAML") else []
in_ctx = False
for l in lines:
    if l.strip() == "set_context:":
        in_ctx = True
        continue
    if in_ctx:
        if l.strip().startswith("#") or not l.strip():
            continue
        if not l.startswith((" ", "\t")):
            break
        m = re.match(r'^\s*max_context_tokens:\s*(\d+)', l)
        if m:
            print(m.group(1))
            break
PYX
)"
  fi

  MAX_CONTEXT_TOKENS="${MAX_CONTEXT_TOKENS:-${cur_tokens:-1000000}}"

  ask_val "max_context_tokens" MAX_CONTEXT_TOKENS "${MAX_CONTEXT_TOKENS}"
}

ask_server_config() {
  local py cur_port=""
  py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo none)"
  if [ "${py}" != "none" ]; then
    while IFS=$'\t' read -r k v; do
      [ "${k}" = "port" ] && cur_port="${v}"
    done < <(CHAT_CFG="${CONFIG_YAML}" "${py}" - <<'PYX'
import re, os
vals, in_server = {}, False
for l in open(os.environ["CHAT_CFG"], encoding="utf-8").read().splitlines():
    s = l.strip()
    if l == "server:":
        in_server = True
        continue
    if not in_server:
        continue
    if s.startswith("#") or not s:
        continue
    if not l.startswith((" ", "\t")):
        break
    m = re.match(r'^\s+(host|port):\s*"?(.*?)"?\s*(#.*)?$', l)
    if m and m.group(1) not in vals:
        vals[m.group(1)] = (m.group(2) or "").strip()
for k in ("host", "port"):
    print("%s\t%s" % (k, vals.get(k, "")))
PYX
)
  fi

  HOST_BIND="${HOST_BIND:-${IFACE_IP}}"
  local free_port
  free_port="$(find_free_port "${cur_port:-8125}")"
  DEVKITAI_SERVICE_PORT="${DEVKITAI_SERVICE_PORT:-${free_port}}"
  export HOST_BIND DEVKITAI_SERVICE_PORT
}

cmd_config() {
  CONFIG_YAML="$(find_config_yaml || true)"
  [ -n "${CONFIG_YAML}" ] && [ -f "${CONFIG_YAML}" ] || die "Original config.yaml not found; check whether devkitai has been extracted in ${INSTALL_DIR}"

  mkdir -p "${INSTALL_DIR}/skills"
  local py
  py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo none)"
  [ "${py}" != "none" ] || die "python3/python not found; cannot modify config.yaml based on the original config"

  # 1) 备份原 config（仅一次；循环中每次都基于原始文件生成 .new）
  local bak_time
  bak_time="$(date '+%Y%m%d%H%M%S')"
  cp -f "${CONFIG_YAML}" "${CONFIG_YAML}.bak.${bak_time}"

  # 是否已完成首次一次性字段修正（server / remote_skills / backend / downloader）
  local first_done=0
  [ -f "${CONFIG_YAML}.initialized" ] && first_done=1
  # 首次配置才重新检测 server 端口 / 本机 IP；后续 config 只修改模型与上下文
  if [ "${first_done}" = "0" ]; then
    ask_server_config
  fi

  while true; do
  ask_chat_config
  ask_context_config

  # 2) 基于原文件做字段级修改（每次：chat 模型 + 上下文；首次额外修正一次性字段）
  export CHAT_MODEL_NAME="${CHAT_MODEL_NAME}" CHAT_MODEL_PROVIDER="${CHAT_MODEL_PROVIDER}" \
         CHAT_MODEL_ID="${CHAT_MODEL_ID}" CHAT_BASE_URL="${CHAT_BASE_URL}" \
         CHAT_API_KEY_PLAIN="${CHAT_API_KEY_PLAIN}" \
         MAX_CONTEXT_TOKENS="${MAX_CONTEXT_TOKENS}" \
         HOST_VAL="${HOST_BIND}" PORT_VAL="${DEVKITAI_SERVICE_PORT}" ROOT_VAL="${INSTALL_DIR}/skills"

  "${py}" - "${CONFIG_YAML}" "${CONFIG_YAML}.new" <<'PYEOF'
import sys, os, re
src, dst = sys.argv[1], sys.argv[2]
max_tokens = os.environ.get("MAX_CONTEXT_TOKENS", "1000000")
need = {k: v for k, v in {
    "name": os.environ.get("CHAT_MODEL_NAME", "deepseek-flash"),
    "model": os.environ.get("CHAT_MODEL_ID", "deepseek-flash"),
    "model_provider": os.environ.get("CHAT_MODEL_PROVIDER", "deepseek"),
    "base_url": os.environ.get("CHAT_BASE_URL", "https://api.deepseek.com"),
    "api_key": os.environ.get("CHAT_API_KEY_PLAIN", ""),
}.items() if v}

lines = open(src, encoding="utf-8").read().splitlines()

# b) chat_models 首条记录字段更新
if need:
    in_chat, record = False, 0
    for i, l in enumerate(lines):
        s = l.strip()
        if l == "chat_models:":
            in_chat = True
            continue
        if not in_chat:
            continue
        if s.startswith("#") or not s:
            continue
        if not l.startswith((" ", "\t", "-")):
            break
        if l.startswith("-"):
            record += 1
        if record > 1:
            break
        m = re.search(r'(name|model|model_provider|base_url|api_key):\s*(.*?)\s*$', l)
        if m and m.group(1) in need:
            prefix = l[:l.find(m.group(1))]
            lines[i] = '%s%s: "%s"' % (prefix, m.group(1), need[m.group(1)])

# e) set_context.max_context_tokens 修改或追加
in_ctx, ctx_start, ctx_end = False, -1, len(lines)
for i, l in enumerate(lines):
    if l.strip() == "set_context:":
        in_ctx = True
        ctx_start = i
        continue
    if in_ctx and l.strip() and not l.strip().startswith("#") and not l.startswith((" ", "\t")):
        ctx_end = i
        break

if ctx_start != -1:
    ctx_lines = lines[ctx_start + 1:ctx_end]
    has_tokens = False
    for idx, cl in enumerate(ctx_lines):
        if re.match(r'^\s*max_context_tokens:\s*', cl.strip()):
            ctx_lines[idx] = '  max_context_tokens: %s' % max_tokens
            has_tokens = True
            break
    if not has_tokens:
        ctx_lines.append('  max_context_tokens: %s' % max_tokens)
    lines = lines[:ctx_start + 1] + ctx_lines + lines[ctx_end:]
else:
    lines.append("set_context:")
    lines.append('  max_context_tokens: %s' % max_tokens)

open(dst, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PYEOF
  [ "$?" -eq 0 ] || die "Failed to modify based on the original config (model/context)"

  # 3) 首次配置：一次性修正 server / remote_skills / backend / downloader 字段
  if [ "${first_done}" = "0" ]; then
    "${py}" - "${CONFIG_YAML}.new" "${CONFIG_YAML}.new" <<'PYEOF'
import sys, os, re
src, dst = sys.argv[1], sys.argv[2]
host = os.environ.get("HOST_VAL", "")
port = os.environ.get("PORT_VAL", "")
root_dir = os.environ.get("ROOT_VAL", "")

lines = open(src, encoding="utf-8").read().splitlines()

# a) server 节点 (host / port / protocol) 作用域定位与修改/补全
in_server, server_start, server_end = False, -1, len(lines)
for i, l in enumerate(lines):
    if l.strip() == "server:":
        in_server = True
        server_start = i
        continue
    if in_server and l.strip() and not l.strip().startswith("#") and not l.startswith((" ", "\t")):
        server_end = i
        break

if server_start != -1:
    server_lines = lines[server_start + 1:server_end]

    has_host = False
    for idx, sl in enumerate(server_lines):
        if re.match(r'^\s*host:\s*', sl.strip()):
            if host: server_lines[idx] = '  host: "%s"' % host
            has_host = True
            break
    if not has_host and host:
        server_lines.insert(0, '  host: "%s"' % host)

    has_port = False
    for idx, sl in enumerate(server_lines):
        if re.match(r'^\s*port:\s*', sl.strip()):
            if port: server_lines[idx] = '  port: %s' % port
            has_port = True
            break
    if not has_port and port:
        server_lines.insert(0, '  port: %s' % port)

    has_proto = False
    for idx, sl in enumerate(server_lines):
        if re.match(r'^\s*protocol:\s*', sl.strip()):
            server_lines[idx] = '  protocol: "http"'
            has_proto = True
            break
    if not has_proto:
        server_lines.insert(0, '  protocol: "http"')

    lines = lines[:server_start + 1] + server_lines + lines[server_end:]

# c) remote_skills.skills 首条目的 url 修改为新指定路径
in_skills = False
for i, l in enumerate(lines):
    if "remote_skills:" in l:
        in_skills = True
        continue
    if in_skills and re.match(r'^\s+url:\s*', l):
        m = re.match(r'^(\s+)url:\s*', l)
        url = "https://gitcode.com/openeuler/kunpeng-devkit.git"
        lines[i] = '%surl: "%s"' % (m.group(1), url)
        break

# c2) remote_skills 首条 skill 的 channel 改为 git
in_skills = False
for i, l in enumerate(lines):
    if "remote_skills:" in l:
        in_skills = True
        continue
    if in_skills and re.match(r'^\s+channel:\s*', l):
        m = re.match(r'^(\s+)channel:\s*', l)
        lines[i] = '%schannel: git' % m.group(1)
        break

# d) backend.config.root_dir 指向 skills 存放根目录
for i, l in enumerate(lines):
    m = re.match(r'^(\s+)root_dir:\s*', l)
    if m:
        lines[i] = '%sroot_dir: "%s"' % (m.group(1), root_dir)
        break

# f) downloader 区块内 git.default_branch 改为 master（无则补全）
in_dl, dl_start, dl_end = False, -1, len(lines)
for i, l in enumerate(lines):
    if l.strip() == "downloader:":
        in_dl = True
        dl_start = i
        continue
    if in_dl and l.strip() and not l.strip().startswith("#") and not l.startswith((" ", "\t")):
        dl_end = i
        break
if dl_start != -1:
    dl_lines = lines[dl_start + 1:dl_end]
    git_idx = None
    for idx, dl in enumerate(dl_lines):
        if re.match(r'^\s*git:\s*$', dl.strip()):
            git_idx = idx
            break
    if git_idx is not None:
        git_indent = len(dl_lines[git_idx]) - len(dl_lines[git_idx].lstrip())
        has_branch = False
        j = git_idx + 1
        while j < len(dl_lines):
            s = dl_lines[j].strip()
            if not s or s.startswith("#"):
                j += 1
                continue
            indent = len(dl_lines[j]) - len(dl_lines[j].lstrip())
            if indent <= git_indent:
                break
            if re.match(r'^\s*default_branch:\s*', s):
                m = re.match(r'^(\s*)default_branch:\s*', dl_lines[j])
                dl_lines[j] = '%sdefault_branch: "master"' % m.group(1)
                has_branch = True
                break
            j += 1
        if not has_branch:
            dl_lines.insert(git_idx + 1, '%sdefault_branch: "master"' % (' ' * (git_indent + 2)))
    lines = lines[:dl_start + 1] + dl_lines + lines[dl_end:]

open(dst, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PYEOF
    [ "$?" -eq 0 ] || die "Failed to modify based on the original config (one-time first-run fields)"
  fi

  # 4) 自动写入（不再打扰用户确认）
  mv -f "${CONFIG_YAML}.new" "${CONFIG_YAML}"
  if [ "${first_done}" = "0" ]; then
    touch "${CONFIG_YAML}.initialized"
  fi
  break
  done

  # 端口：优先使用 ask_server_config 检测到的空闲端口，否则读取 config.yaml 中已配置端口
  local cfg_port
  cfg_port="$(read_config_port 2>/dev/null || true)"
  DEVKITAI_SERVICE_PORT="${DEVKITAI_SERVICE_PORT:-${cfg_port:-8125}}"
  DEVKITAI_SERVICE_BASE_URL="http://${HOST_BIND}:${DEVKITAI_SERVICE_PORT}"
  local rc_path
  case "${SHELL:-}" in
    *zsh*) rc_path="${HOME}/.zshrc" ;;
    *)     rc_path="${HOME}/.bashrc" ;;
  esac
  # 先删除旧行，再写入新行，避免 bashrc 中重复
  touch "${rc_path}" 2>/dev/null || true
  sed -i '/^# DevKit AI TUI backend$/d; /^export DEVKITAI_SERVICE_BASE_URL=/d' "${rc_path}" 2>/dev/null || true
  printf '# DevKit AI TUI backend\nexport DEVKITAI_SERVICE_BASE_URL="%s"\n' "${DEVKITAI_SERVICE_BASE_URL}" >> "${rc_path}"
  say "Configuration updated"
}

# ==================== 更新 skills ====================
# root 分区空间不足时，将 git 下载安装到公共 /home 目录（rpm 系 yum/dnf）
install_git_home() {
  local pm=""
  if ! have_pkg_permission; then
    warn "Current user ($(id -un)) has no root privileges and sudo is not installed; cannot download the git package, skipping git installation"
    return 1
  fi
  if command -v yum >/dev/null 2>&1; then
    pm="yum"
  elif command -v dnf >/dev/null 2>&1; then
    pm="dnf"
  else
    warn "No package manager found (yum/dnf); cannot install git into the home directory, skipping"
    return 1
  fi

  local git_home="${HOME}/.local/git"
  local dl_dir="${HOME}/.devkitai/downloads/git-rpm"
  local err_log
  mkdir -p "${dl_dir}" "${git_home}"
  check_dir_writable "${git_home}" "git install"
  check_dir_writable "${dl_dir}" "git download"
  say "Downloading git package to ${dl_dir} ..."
  err_log="${dl_dir}/yum-download.err"
  if command -v sudo >/dev/null 2>&1; then
    sudo "${pm}" install -y --downloadonly --destdir="${dl_dir}" git >"${err_log}" 2>&1 || { [ -s "${err_log}" ] && tail -n 30 "${err_log}" >&2; warn "Failed to download the git package (error running ${pm} with sudo; possibly no sudo permission), skipping git installation"; return 1; }
  else
    "${pm}" install -y --downloadonly --destdir="${dl_dir}" git >"${err_log}" 2>&1 || { [ -s "${err_log}" ] && tail -n 30 "${err_log}" >&2; warn "Failed to download the git package (current user has no sudo and no ${pm} permission), skipping git installation"; return 1; }
  fi

  say "Extracting git to ${git_home} ..."
  ( cd "${git_home}" && for f in "${dl_dir}"/*.rpm; do rpm2cpio "${f}" | cpio -idm >/dev/null 2>&1; done )
  [ -x "${git_home}/usr/bin/git" ] || { warn "No git executable found after extraction (${git_home}/usr/bin/git), skipping git installation"; return 1; }

  export PATH="${git_home}/usr/bin:${git_home}/usr/libexec/git-core:${PATH}"
  export GIT_TEMPLATE_DIR="${git_home}/usr/share/git-core/templates"
  export PERL5LIB="${git_home}/usr/share/perl5/vendor_perl:${git_home}/usr/lib64/perl5/vendor_perl"

  local rc_path
  case "${SHELL:-}" in
    *zsh*) rc_path="${HOME}/.zshrc" ;;
    *)     rc_path="${HOME}/.bashrc" ;;
  esac
  # 先删除旧块再写入，避免 bashrc 中重复
  touch "${rc_path}" 2>/dev/null || true
  sed -i '/^# DevKit AI git (home 安装)$/,/^export PERL5LIB=/d' "${rc_path}" || true
  {
    printf '# DevKit AI git (home 安装)\n'
    printf 'export PATH="%s/usr/bin:%s/usr/libexec/git-core:$PATH"\n' "${git_home}" "${git_home}"
    printf 'export GIT_TEMPLATE_DIR="%s/usr/share/git-core/templates"\n' "${git_home}"
    printf 'export PERL5LIB="%s/usr/share/perl5/vendor_perl:%s/usr/lib64/perl5/vendor_perl"\n' "${git_home}" "${git_home}"
  } >> "${rc_path}"
  say "git environment variables written (${rc_path}); effective on next login"
  say "git installed to: ${git_home}/usr/bin/git"
}

# 检查并确保 git 已安装且完成全局配置（skills 更新前置步骤）
ensure_git() {
  local ans
  if command -v git >/dev/null 2>&1; then
    say "git already installed: $(git --version)"
  else
    printf 'git not detected. Install it? Enter y to install, n to skip [y/n]: '
    if ! read -r ans </dev/tty 2>/dev/null; then
      ans="y"
    fi
    printf '\n'
    case "${ans}" in
      y|Y|"")
        if ! have_pkg_permission; then
          warn "Current user ($(id -un)) has no root privileges and sudo is not installed; cannot install git, skipping the git installation step"
          warn "Have an administrator run yum/dnf/apt-get install -y git, or grant this user sudo privileges and rerun update"
          return 1
        fi
        local need_mb=100 free_mb
        free_mb="$(df -Pk / 2>/dev/null | awk 'NR==2 {printf "%.0f", $4/1024}')"
        if [ -n "${free_mb}" ] && [ "${free_mb}" -ge "${need_mb}" ]; then
          say "Root partition has enough space (${free_mb}MB); installing git to the system directory..."
          local pm=""
          if command -v yum >/dev/null 2>&1; then
            pm="yum"
          elif command -v dnf >/dev/null 2>&1; then
            pm="dnf"
          elif command -v apt-get >/dev/null 2>&1; then
            pm="apt-get"
          else
            warn "No package manager found (yum/dnf/apt-get), skipping git installation"
            return 1
          fi
          if [ "$(id -u)" = "0" ]; then
            if [ "${pm}" = "apt-get" ]; then
              apt-get update -y >/dev/null 2>&1 || true
            fi
            "${pm}" install -y git || { warn "git installation failed (${pm} permission issue or repository error), skipping git installation"; return 1; }
          elif command -v sudo >/dev/null 2>&1; then
            if [ "${pm}" = "apt-get" ]; then
              sudo apt-get update -y >/dev/null 2>&1 || true
            fi
            sudo "${pm}" install -y git || { warn "git installation failed (sudo ${pm} permission issue or repository error), skipping git installation"; return 1; }
          else
            warn "Current user is not root and has no sudo, skipping git installation"
            return 1
          fi
          say "git installed to system directory: $(command -v git)"
        else
          say "Root partition space is insufficient (${free_mb:-0}MB < ${need_mb}MB); git will be installed to ${HOME}/.local/git"
          install_git_home || { warn "git non-root installation failed, skipping the installation step"; return 1; }
        fi
        command -v git >/dev/null 2>&1 || { warn "git is still unavailable after installation, skipping the remaining git configuration"; return 1; }
        ;;
      *)
        warn "git installation skipped; the subsequent skills update may fail"
        return 1
        ;;
    esac
  fi

  local git_name git_email git_input=""
  export GIT_CONFIG_GLOBAL="${HOME}/.gitconfig"
  touch "${GIT_CONFIG_GLOBAL}" 2>/dev/null || die "Cannot write to ${GIT_CONFIG_GLOBAL}; check write permission for the ${HOME} directory"
  local rc_path
  case "${SHELL:-}" in
    *zsh*) rc_path="${HOME}/.zshrc" ;;
    *)     rc_path="${HOME}/.bashrc" ;;
  esac
  # 先删除旧行再写入，避免 bashrc 中重复
  touch "${rc_path}" 2>/dev/null || true
  sed -i '/^# DevKit AI git 全局配置$/d; /^export GIT_CONFIG_GLOBAL=/d' "${rc_path}" || true
  printf '# DevKit AI git 全局配置\nexport GIT_CONFIG_GLOBAL=%s\n' "${GIT_CONFIG_GLOBAL}" >> "${rc_path}"
  say "GIT_CONFIG_GLOBAL=${GIT_CONFIG_GLOBAL} written to ${rc_path} (effective on next login)"
  git_name="$(git config --global user.name 2>/dev/null || true)"
  git_email="$(git config --global user.email 2>/dev/null || true)"
  if [ -n "${git_name}" ] && [ -n "${git_email}" ]; then
    say "git global config already exists: user.name=${git_name}, user.email=${git_email}"
  else
    say "Complete git global config not detected (press Enter to skip):"
    printf '    user.name  [%s]: ' "${git_name:-not set}"
    if read -r git_input </dev/tty 2>/dev/null && [ -n "${git_input}" ]; then git_name="${git_input}"; fi
    printf '    user.email [%s]: ' "${git_email:-not set}"
    if read -r git_input </dev/tty 2>/dev/null && [ -n "${git_input}" ]; then git_email="${git_input}"; fi
    if [ -n "${git_name}" ] && [ -n "${git_email}" ]; then
      git config --global user.name "${git_name}"
      git config --global user.email "${git_email}"
      say "git global config complete: user.name=${git_name}, user.email=${git_email} (file: ${GIT_CONFIG_GLOBAL})"
    else
      warn "user.name / user.email not fully provided, skipping git global config"

    fi
  fi
}

cmd_update() {
  local devkit_bin
  ensure_git || true
  devkit_bin="$(find_devkitai_bin)" || die "devkitai executable not found; check the ${INSTALL_DIR} directory"
  local cli_log
  cli_log="$(dirname "${devkit_bin}")/logs/common/cli.log"
  say "Updating skills"
  ( cd "$(dirname "${devkit_bin}")" && "${devkit_bin}" skills update ) \
    || die "skills update failed, see ${cli_log}"
  say "Skills update complete"
}

# ==================== server 管理 ====================
port_open() {
  local out
  out="$({ command -v ss >/dev/null 2>&1 && ss -ltn; command -v netstat >/dev/null 2>&1 && netstat -ltn; } 2>/dev/null)"
  printf '%s\n' "${out}" | grep -E ":${DEVKITAI_SERVICE_PORT}([[:space:]]|$)" >/dev/null 2>&1
}

stop_server() {
  local devkit_bin bin_dir pid_file pid
  devkit_bin="$(find_devkitai_bin 2>/dev/null || true)"
  if [ -z "${devkit_bin}" ]; then
    say "devkitai not found, skipping stop"
    return 0
  fi
  bin_dir="$(dirname "${devkit_bin}")"
  pid_file="${bin_dir}/server.pid"
  if [ -f "${pid_file}" ]; then
    pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      say "Stopping old server process ${pid}"
      kill "${pid}" 2>/dev/null || true
      sleep 2
      kill -0 "${pid}" 2>/dev/null && { say "Process did not exit, force killing"; kill -9 "${pid}" 2>/dev/null || true; sleep 1; }
    fi
    rm -f "${pid_file}"
  fi
  if command -v pkill >/dev/null 2>&1 && pgrep -f "${devkit_bin} server" >/dev/null 2>&1; then
    say "Fallback kill by process name: ${devkit_bin} server"
    pkill -f "${devkit_bin} server" 2>/dev/null || true
    sleep 2
  fi
}

start_server() {
  for _caf in "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem" "/etc/ssl/certs/ca-certificates.crt"; do
    if [ -f "${_caf}" ]; then
      export SSL_CERT_FILE="${_caf}"
      export CURL_CA_BUNDLE="${_caf}"
      break
    fi
  done
  local devkit_bin
  devkit_bin="$(find_devkitai_bin)" || die "devkitai not found; run ./install.sh first"
  [ -x "${devkit_bin}" ] || die "devkitai is not executable"

  local cfg_port
  cfg_port="$(read_config_port)"
  if [ -n "${cfg_port}" ]; then
    DEVKITAI_SERVICE_PORT="${cfg_port}"
  elif [ -z "${DEVKITAI_SERVICE_PORT}" ]; then
    DEVKITAI_SERVICE_PORT="$(find_free_port 8125)"
  fi

  DEVKITAI_SERVICE_BASE_URL="http://${HOST_BIND}:${DEVKITAI_SERVICE_PORT}"

  local bin_dir log_file pid_file
  bin_dir="$(dirname "${devkit_bin}")"
  log_file="${bin_dir}/logs/common/server.log"
  pid_file="${bin_dir}/server.pid"
  mkdir -p "$(dirname "${log_file}")"

  stop_server

  say "Starting devkitai server in the background (log: ${log_file})"
  (
    cd "${bin_dir}"
    nohup "${devkit_bin}" server >> "${log_file}" 2>&1 &
    echo $! > "${pid_file}"
  )

  local i
  for i in $(seq 1 60); do
    if ! kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
      echo
      echo "ERROR: server exited; last 100 lines of log (${log_file}):" >&2
      tail -n 100 "${log_file}"
      exit 1
    fi
    if grep -q "code: 13" "${log_file}" 2>/dev/null; then
      echo
      echo "ERROR: detected code: 13 (chromadb SQLite temp file write failed/disk constrained; the server cannot start); last 50 lines of log (${log_file}):" >&2
      tail -n 50 "${log_file}"
      exit 1
    fi
    if port_open; then
      printf '    [%s/60] Port %s is now listening\n' "${i}" "${DEVKITAI_SERVICE_PORT}"
      break
    fi
    printf '    [%s/60] Waiting for server to be ready...\r' "${i}"
    sleep 2
  done
  if ! port_open; then
    echo
    echo "ERROR: timed out (180s); port ${DEVKITAI_SERVICE_PORT} is not listening; last 100 lines of log (${log_file}):" >&2
    tail -n 100 "${log_file}"
    exit 1
  fi
  printf '\n'
  say "READY: devkitai server is up (${HOST_BIND}:${DEVKITAI_SERVICE_PORT})"
  export DEVKITAI_SERVICE_BASE_URL="${DEVKITAI_SERVICE_BASE_URL}"
}

# 启动 server 后只提示手动启动 TUI（脚本内不再直接启动）
start_tui_prompt() {
  if [ -x "${HOME}/.local/bin/devkitai-tui" ]; then
    say "TUI is installed. Start it manually:"
    say "    source ${HOME}/.bashrc && devkitai-tui"
    say "    or open a new terminal and run: devkitai-tui"
  else
    say "Warning: ~/.local/bin/devkitai-tui does not exist; run install to install the TUI first"
  fi
}

cmd_start() {
  start_server
  start_tui_prompt
}

cmd_stop() {
  stop_server
  say "devkitai server stopped"
}

# restart = 修改配置 + 启动（config 与 restart 合并为同一复合流程）
cmd_restart() {
  cmd_config
  cmd_start
}

# ==================== 卸载 ====================
# 仅删除 rc 中 DevKit AI 相关区块/行，不动用户其他配置（幂等，可重复执行）
cleanup_rc() {
  local rc
  for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    [ -f "${rc}" ] || continue
    sed -i '/^# DevKit AI TUI$/d; /^export PATH="\${HOME}\/\.local\/bin:\${PATH}"$/d; /^# DevKit AI TUI backend$/d; /^export DEVKITAI_SERVICE_BASE_URL=/d; /^# DevKit AI git (home 安装)$/,/^export PERL5LIB=/d; /^# DevKit AI git 全局配置$/d; /^export GIT_CONFIG_GLOBAL=/d' "${rc}" 2>/dev/null || true
  done
}

cmd_uninstall() {
  section "Uninstalling DevKit AI"
  stop_server

  local devkit_bin
  devkit_bin="$(find_devkitai_bin 2>/dev/null || true)"
  if [ -n "${devkit_bin}" ]; then
    say "Found devkitai at: ${devkit_bin}"
  fi

  # 1) 询问是否删除数据目录（默认保留；UNINSTALL_KEEP_DATA=1 跳过询问并保留）
  local keep_data="true" ans
  if [ "${UNINSTALL_KEEP_DATA:-}" != "1" ] && [ -d "${INSTALL_DIR}" ]; then
    printf 'Remove the data directory %s too? Enter y to delete, Enter to keep [y/N]: ' "${INSTALL_DIR}"
    if read -r ans </dev/tty 2>/dev/null && { [ "${ans}" = "y" ] || [ "${ans}" = "Y" ]; }; then
      keep_data="false"
    fi
    printf '\n'
  fi

  # 2) 清理 TUI 命令与全局软链
  rm -f "${HOME}/.local/bin/devkitai-tui" 2>/dev/null || true
  rm -rf "${HOME}/.local/lib/devkitai-tui" 2>/dev/null || true
  if [ -e /usr/local/bin/devkitai-tui ]; then
    rm -f /usr/local/bin/devkitai-tui 2>/dev/null \
      && say "Removed global command: /usr/local/bin/devkitai-tui" \
      || warn "No permission to remove /usr/local/bin/devkitai-tui; ask an admin to run: rm -f /usr/local/bin/devkitai-tui"
  fi

  # 3) 清理 rc 中的 DevKit AI 区块
  cleanup_rc

  # 4) 清理脚本私有目录与数据目录
  rm -rf "${HOME}/.devkitai" 2>/dev/null || true
  if [ "${keep_data}" = "false" ]; then
    rm -rf "${INSTALL_DIR}" "${DEVKIT_DIR:-${HOME}/devkit-tools}" 2>/dev/null || true
    say "Removed data directory: ${INSTALL_DIR}"
  else
    say "Kept data directory as-is: ${INSTALL_DIR} (remove manually if no longer needed)"
  fi

  say "DevKit AI uninstall complete"
}

# ==================== 入口 ====================
case "${1:-all}" in
  download) cmd_download ;;
  install)  cmd_install ;;
  config)   cmd_restart ;;
  update)   cmd_update ;;
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  restart)  cmd_restart ;;
  uninstall) cmd_uninstall ;;
  all)      cmd_download && cmd_install && cmd_config && cmd_update && cmd_start ;;
  *) echo "Usage: $0 [all|download|install|config|update|start|stop|restart|uninstall]" >&2; exit 1 ;;
esac
