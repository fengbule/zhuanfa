#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-fb}"
APP_DESC="${APP_DESC:-端口转发管理工具}"
APP_VERSION="${APP_VERSION:-v1.3.0}"
APP_REPO="${APP_REPO:-https://github.com/fengbule/zhuanfa}"
SELF_SOURCE_URL="${FB_SELF_SOURCE_URL:-https://raw.githubusercontent.com/fengbule/zhuanfa/main/fb.sh}"

CONF_DIR="${FB_CONF_DIR:-/etc/fb}"
RULES_DB="${FB_RULES_DB:-$CONF_DIR/rules.db}"
BACKUP_DIR="${FB_BACKUP_DIR:-$CONF_DIR/backups}"
LOG_DIR="${FB_LOG_DIR:-/var/log/fb}"
STATE_DIR="${FB_STATE_DIR:-/var/lib/fb}"
TMP_DIR="${FB_TMP_DIR:-/tmp/fb}"
SELF_TARGET="${FB_SELF_TARGET:-/usr/local/bin/fb}"
SYSTEMD_DIR="${FB_SYSTEMD_DIR:-/etc/systemd/system}"
SYSCTL_FILE="${FB_SYSCTL_FILE:-/etc/sysctl.d/99-fb.conf}"

DEFAULT_LISTEN_ADDR="${FB_DEFAULT_LISTEN_ADDR:-0.0.0.0}"
GOST_TARGET_BIN="${FB_GOST_TARGET_BIN:-/usr/local/bin/fb-gost}"
REALM_TARGET_BIN="${FB_REALM_TARGET_BIN:-/usr/local/bin/fb-realm}"

C0='\033[0m'
C1='\033[0;32m'
C2='\033[1;33m'
C3='\033[0;31m'
C4='\033[0;36m'
C5='\033[1;35m'
C6='\033[1;34m'
CW='\033[1;37m'
DIM='\033[2m'

FB_LOG_FILE="${LOG_DIR}/fb.log"

trap 'on_error $LINENO "$BASH_COMMAND"' ERR

on_error() {
  local line="${1:-?}" cmd="${2:-?}"
  err "脚本执行失败: line=${line} cmd=${cmd}"
}

write_log_file() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$FB_LOG_FILE" 2>/dev/null || true
}

log() {
  write_log_file "[INFO] $*"
  echo -e "${C1}[INFO]${C0} $*"
}

warn() {
  write_log_file "[WARN] $*"
  echo -e "${C2}[WARN]${C0} $*" >&2
}

err() {
  write_log_file "[ERR ] $*"
  echo -e "${C3}[ERR ]${C0} $*" >&2
}

die() {
  err "$*"
  exit 1
}

trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_test_mode() {
  [[ "${FB_TEST_MODE:-0}" == "1" ]]
}

open_tty_fd() {
  local __result_var="$1" tty_fd=""
  [[ -c /dev/tty ]] || return 1
  if { exec {tty_fd}<>/dev/tty; } 2>/dev/null; then
    printf -v "$__result_var" '%s' "$tty_fd"
    return 0
  fi
  return 1
}

read_prompt() {
  local __result_var="$1" prompt="$2" input="" tty_fd=""
  if is_test_mode; then
    printf '%s' "$prompt"
    IFS= read -r input || input=""
  elif [[ -t 0 ]]; then
    printf '%s' "$prompt"
    IFS= read -r input || input=""
  elif open_tty_fd tty_fd; then
    printf '%s' "$prompt" >&"$tty_fd"
    IFS= read -r -u "$tty_fd" input || input=""
    exec {tty_fd}>&-
  else
    printf '%s' "$prompt" >&2
    IFS= read -r input || input=""
  fi
  printf -v "$__result_var" '%s' "$input"
}

need_root() {
  is_test_mode && return 0
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"
}

need_systemd() {
  is_test_mode && return 0
  command -v systemctl >/dev/null 2>&1 || die "当前系统缺少 systemd/systemctl，无法继续。"
}

init_dirs() {
  mkdir -p "$CONF_DIR" "$BACKUP_DIR" "$LOG_DIR" "$STATE_DIR" "$TMP_DIR"
  touch "$RULES_DB"
  touch "$FB_LOG_FILE"
}

ensure_base_layout() {
  mkdir -p "$CONF_DIR/haproxy" "$CONF_DIR/rinetd" "$CONF_DIR/nginx/streams" "$CONF_DIR/realm" "$CONF_DIR/gost"
}

os_id=""
os_like=""
pkg_mgr=""

get_os() {
  [[ -f /etc/os-release ]] || die "无法识别系统：缺少 /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  os_id="${ID:-}"
  os_like="${ID_LIKE:-}"

  if command -v apt-get >/dev/null 2>&1; then
    pkg_mgr="apt"
  elif command -v dnf >/dev/null 2>&1; then
    pkg_mgr="dnf"
  elif command -v yum >/dev/null 2>&1; then
    pkg_mgr="yum"
  elif command -v apk >/dev/null 2>&1; then
    pkg_mgr="apk"
  else
    die "不支持的包管理器，请手动安装依赖。"
  fi
}

pkg_install() {
  local pkgs=("$@")
  [[ ${#pkgs[@]} -gt 0 ]] || return 0
  case "$pkg_mgr" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y </dev/null
      apt-get install -y "${pkgs[@]}" </dev/null
      ;;
    dnf)
      dnf install -y "${pkgs[@]}" </dev/null
      ;;
    yum)
      yum install -y epel-release </dev/null || true
      yum install -y "${pkgs[@]}" </dev/null
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}" </dev/null
      ;;
    *)
      die "未知包管理器：$pkg_mgr"
      ;;
  esac
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

normalize_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    *) echo "amd64" ;;
  esac
}

bin_path() {
  command -v "$1" 2>/dev/null || true
}

release_arch_pattern() {
  case "$(normalize_arch)" in
    amd64) echo '(amd64|x86_64)' ;;
    arm64) echo '(arm64|aarch64)' ;;
    armv7) echo '(armv7|armv7l)' ;;
    *) echo "$(normalize_arch)" ;;
  esac
}

install_base() {
  get_os
  init_dirs
  ensure_base_layout
  case "$pkg_mgr" in
    apt)
      pkg_install curl wget jq tar gzip unzip ca-certificates iproute2 iptables net-tools lsof procps systemd coreutils gawk grep sed bc
      ;;
    dnf|yum)
      pkg_install curl wget jq tar gzip unzip ca-certificates iproute iptables net-tools lsof procps-ng systemd gawk grep sed bc
      ;;
    apk)
      pkg_install curl wget jq tar gzip unzip ca-certificates iproute2 iptables net-tools lsof procps gawk grep sed bc
      ;;
  esac
  log "基础依赖安装完成。"
}

ensure_sysctl_line() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^\s*${key}\s*=" "$file" 2>/dev/null; then
    sed -ri "s#^\s*${key}\s*=.*#${key} = ${value}#" "$file"
  else
    echo "${key} = ${value}" >> "$file"
  fi
}

sysctl_key_path() {
  local key="$1"
  printf '/proc/sys/%s\n' "${key//./\/}"
}

apply_sysctl_setting() {
  local key="$1" value="$2"
  local key_path
  key_path="$(sysctl_key_path "$key")"
  if [[ ! -e "$key_path" ]]; then
    warn "内核未提供参数 $key，已跳过。"
    return 1
  fi
  if sysctl -q -w "$key=$value" >/dev/null 2>&1; then
    return 0
  fi
  warn "参数 $key=$value 当前环境不支持，已跳过。"
  return 1
}

optimize_network() {
  need_root
  is_test_mode && return 0

  local file="$SYSCTL_FILE" skipped=0 key value
  mkdir -p "$(dirname "$file")"
  touch "$file"
  : > "$file"

  modprobe tcp_bbr 2>/dev/null || true

  while IFS='=' read -r key value; do
    [[ -n "${key:-}" ]] || continue
    if apply_sysctl_setting "$key" "$value"; then
      printf '%s = %s\n' "$key" "$value" >> "$file"
    else
      skipped=$((skipped + 1))
    fi
  done <<'EOF'
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=262144
net.core.wmem_default=262144
net.core.netdev_max_backlog=16384
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
EOF

  if (( skipped > 0 )); then
    warn "网络优化中有 ${skipped} 项因当前内核/容器环境限制被跳过。"
  fi
  log "网络优化已应用：BBR / TFO / 缓冲区 / IP Forward。"
}

install_self() {
  need_root
  local src
  src="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true)"
  mkdir -p "$(dirname "$SELF_TARGET")"

  if [[ -n "$src" && -f "$src" && "$src" != "/proc/"* && "$src" != "/dev/"* ]]; then
    install -m 0755 "$src" "$SELF_TARGET"
  else
    if cmd_exists curl; then
      curl -fsSL "$SELF_SOURCE_URL" -o "$SELF_TARGET"
      chmod 0755 "$SELF_TARGET"
    elif cmd_exists wget; then
      wget -qO "$SELF_TARGET" "$SELF_SOURCE_URL"
      chmod 0755 "$SELF_TARGET"
    else
      die "无法下载脚本本体，请先安装 curl 或 wget，或使用本地 fb.sh 执行 install-self。"
    fi
  fi
  log "脚本已安装到 $SELF_TARGET"
  log "之后可直接使用命令：fb"
}

create_or_update_service() {
  local svc="$1" content="$2"
  mkdir -p "$SYSTEMD_DIR"
  printf '%s\n' "$content" > "$SYSTEMD_DIR/$svc"
}

install_rebuild_service() {
  need_root
  local exec_path="$SELF_TARGET"
  [[ -x "$exec_path" ]] || exec_path="$(readlink -f "$0")"

  create_or_update_service "fb-rebuild.service" "[Unit]
Description=FB rebuild all forwarding rules on boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$exec_path rebuild-onboot
RemainAfterExit=yes
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target"

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable fb-rebuild.service >/dev/null 2>&1 || true
}

latest_asset_url() {
  local repo="$1" pattern="$2"
  local urls=""
  urls="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | jq -r '.assets[].browser_download_url' 2>/dev/null || true)"
  [[ -n "$urls" ]] || return 0
  printf '%s\n' "$urls" | grep -m1 -E "$pattern" || true
}

is_realm_relay_binary() {
  local bin="${1:-}"
  [[ -n "$bin" && -x "$bin" ]] || return 1
  "$bin" --help 2>&1 | grep -qiE 'relay tool|static tcp relay|high efficiency relay'
}

find_gost_binary() {
  if [[ -x "$GOST_TARGET_BIN" ]]; then
    printf '%s\n' "$GOST_TARGET_BIN"
    return 0
  fi
  command -v gost 2>/dev/null || true
}

find_realm_binary() {
  if is_realm_relay_binary "$REALM_TARGET_BIN"; then
    printf '%s\n' "$REALM_TARGET_BIN"
    return 0
  fi
  local existing
  existing="$(command -v realm 2>/dev/null || true)"
  if is_realm_relay_binary "$existing"; then
    printf '%s\n' "$existing"
    return 0
  fi
  return 1
}

install_gost_binary() {
  local url tmpd bin arch_pat existing
  existing="$(find_gost_binary)"
  if [[ -n "$existing" ]]; then
    log "gost 已存在：$existing"
    return 0
  fi

  tmpd="$(mktemp -d)"
  arch_pat="$(release_arch_pattern)"
  url="$(latest_asset_url 'go-gost/gost' "(linux|Linux).*${arch_pat}.*(tar.gz|tgz|zip)$")"
  [[ -n "$url" ]] || die "无法自动获取 gost 最新版本下载地址，请手动安装。"

  curl -fL "$url" -o "$tmpd/gost.pkg"
  case "$url" in
    *.zip) unzip -qo "$tmpd/gost.pkg" -d "$tmpd/unpack" ;;
    *) tar -xf "$tmpd/gost.pkg" -C "$tmpd" ;;
  esac

  bin="$(find "$tmpd" -type f -name gost | head -n1)"
  [[ -n "$bin" ]] || die "gost 安装失败：未找到二进制文件。"

  install -m 0755 "$bin" "$GOST_TARGET_BIN"
  rm -rf "$tmpd"
}

install_realm_binary() {
  local url tmpd bin arch_pat existing
  existing="$(find_realm_binary || true)"
  if [[ -n "$existing" ]]; then
    log "realm 已存在：$existing"
    return 0
  fi

  tmpd="$(mktemp -d)"
  arch_pat="$(release_arch_pattern)"
  url="$(latest_asset_url 'zhboner/realm' "realm-${arch_pat}.*unknown-linux-gnu.*(tar.gz|tgz|zip)$")"
  [[ -n "$url" ]] || url="$(latest_asset_url 'zhboner/realm' "realm-slim-${arch_pat}.*unknown-linux-gnu.*(tar.gz|tgz|zip)$")"
  [[ -n "$url" ]] || url="$(latest_asset_url 'zhboner/realm' "realm-${arch_pat}.*unknown-linux-musl.*(tar.gz|tgz|zip)$")"
  [[ -n "$url" ]] || url="$(latest_asset_url 'zhboner/realm' "realm-slim-${arch_pat}.*unknown-linux-musl.*(tar.gz|tgz|zip)$")"
  [[ -n "$url" ]] || die "无法自动获取 realm 最新版本下载地址，请手动安装。"

  curl -fL "$url" -o "$tmpd/realm.pkg"
  case "$url" in
    *.zip) unzip -qo "$tmpd/realm.pkg" -d "$tmpd/unpack" ;;
    *) tar -xf "$tmpd/realm.pkg" -C "$tmpd" ;;
  esac

  bin="$(find "$tmpd" -type f -name realm | head -n1)"
  [[ -n "$bin" ]] || die "realm 安装失败：未找到二进制文件。"

  install -m 0755 "$bin" "$REALM_TARGET_BIN"
  rm -rf "$tmpd"
}

install_method_deps() {
  get_os
  case "$1" in
    iptables)
      case "$pkg_mgr" in
        apt|dnf|yum|apk) pkg_install iptables ;;
      esac
      ;;
    haproxy)
      pkg_install haproxy
      ;;
    socat)
      pkg_install socat
      ;;
    rinetd)
      pkg_install rinetd
      ;;
    nginx)
      case "$pkg_mgr" in
        apt)
          pkg_install nginx libnginx-mod-stream || pkg_install nginx
          ;;
        dnf|yum)
          pkg_install nginx nginx-mod-stream || pkg_install nginx
          ;;
        apk)
          pkg_install nginx nginx-mod-stream || pkg_install nginx
          ;;
      esac
      ;;
    gost)
      install_gost_binary
      ;;
    realm)
      install_realm_binary
      ;;
    *)
      die "未知方法：$1"
      ;;
  esac
  log "$1 依赖安装完成。"
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 ))
}

validate_proto() {
  [[ "$1" == "tcp" || "$1" == "udp" ]]
}

method_supports_proto() {
  local method="$1" proto="$2"
  case "$method:$proto" in
    iptables:tcp|iptables:udp|socat:tcp|socat:udp|gost:tcp|realm:tcp|haproxy:tcp|rinetd:tcp|nginx:tcp)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

verify_method_ready() {
  local method="$1"
  case "$method" in
    iptables)
      cmd_exists iptables || die "未找到 iptables 可执行文件。"
      ;;
    haproxy)
      cmd_exists haproxy || die "未找到 haproxy 可执行文件。"
      ;;
    socat)
      cmd_exists socat || die "未找到 socat 可执行文件。"
      ;;
    gost)
      [[ -n "$(find_gost_binary)" ]] || die "未找到 gost 可执行文件。"
      ;;
    realm)
      [[ -n "$(find_realm_binary || true)" ]] || die "未找到 realm 可执行文件。"
      ;;
    rinetd)
      cmd_exists rinetd || die "未找到 rinetd 可执行文件。"
      ;;
    nginx)
      cmd_exists nginx || die "未找到 nginx 可执行文件。"
      ;;
    *)
      die "未知方法：$method"
      ;;
  esac
}

next_rule_id() {
  printf '%(%Y%m%d%H%M%S)T-%04d\n' -1 $((RANDOM % 10000))
}

save_rule() {
  local id="$1" method="$2" proto="$3" listen_addr="$4" listen_port="$5" target_host="$6" target_port="$7" extra="${8:-}" db_file="${9:-$RULES_DB}"
  echo "${id}|${method}|${proto}|${listen_addr}|${listen_port}|${target_host}|${target_port}|${extra}" >> "$db_file"
}

get_rule_line() {
  local id="$1" db_file="${2:-$RULES_DB}"
  grep -E "^${id}\|" "$db_file" || true
}

remove_rule_line() {
  local id="$1" db_file="${2:-$RULES_DB}"
  grep -vE "^${id}\|" "$db_file" > "${db_file}.tmp" || true
  mv "${db_file}.tmp" "$db_file"
}

list_rules_raw() {
  local db_file="${1:-$RULES_DB}"
  grep -vE '^\s*$|^```' "$db_file" 2>/dev/null || true
}

rule_count() {
  local db_file="${1:-$RULES_DB}"
  list_rules_raw "$db_file" | wc -l | awk '{print $1}'
}

resolve_host_status() {
  local host="$1"
  [[ -n "$host" ]] || {
    echo "fail"
    return 0
  }
  if getent ahosts "$host" >/dev/null 2>&1; then
    echo "ok"
  else
    echo "fail"
  fi
}

check_listen_conflict() {
  local method="$1" proto="$2" addr="$3" port="$4"
  [[ "$method" == "iptables" ]] && return 0

  local ss_filter
  if [[ "$proto" == "tcp" ]]; then
    ss_filter="-lnt"
  else
    ss_filter="-lnu"
  fi

  if ss $ss_filter 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[:\]])${port}$"; then
    warn "端口 $port 似乎已被占用，若是本脚本已存在规则可忽略；否则建议更换端口。"
  fi
}

cleanup_iptables_all() {
  iptables -t nat -D PREROUTING -j FB_PREROUTING 2>/dev/null || true
  iptables -t nat -D OUTPUT -j FB_OUTPUT 2>/dev/null || true
  iptables -t nat -D POSTROUTING -j FB_POSTROUTING 2>/dev/null || true
  iptables -D FORWARD -j FB_FORWARD 2>/dev/null || true

  iptables -t nat -F FB_PREROUTING 2>/dev/null || true
  iptables -t nat -F FB_OUTPUT 2>/dev/null || true
  iptables -t nat -F FB_POSTROUTING 2>/dev/null || true
  iptables -F FB_FORWARD 2>/dev/null || true

  iptables -t nat -X FB_PREROUTING 2>/dev/null || true
  iptables -t nat -X FB_OUTPUT 2>/dev/null || true
  iptables -t nat -X FB_POSTROUTING 2>/dev/null || true
  iptables -X FB_FORWARD 2>/dev/null || true
}

remove_network_optimization() {
  rm -f "$SYSCTL_FILE"
  sysctl --system >/dev/null 2>&1 || true
}

delete_invocation_source_if_needed() {
  local src
  src="$(readlink -f "$0" 2>/dev/null || true)"
  [[ -n "$src" && -f "$src" ]] || return 0
  [[ "$src" == "$SELF_TARGET" ]] && return 0
  rm -f "$src" 2>/dev/null || true
}

cleanup_method_binaries() {
  rm -f "$GOST_TARGET_BIN" "$REALM_TARGET_BIN"
  if is_realm_relay_binary "/usr/local/bin/realm"; then
    rm -f /usr/local/bin/realm
  fi
}

ensure_iptables_base() {
  iptables -t nat -N FB_PREROUTING 2>/dev/null || true
  iptables -t nat -N FB_OUTPUT 2>/dev/null || true
  iptables -t nat -N FB_POSTROUTING 2>/dev/null || true
  iptables -N FB_FORWARD 2>/dev/null || true

  iptables -t nat -C PREROUTING -j FB_PREROUTING 2>/dev/null || iptables -t nat -A PREROUTING -j FB_PREROUTING
  iptables -t nat -C OUTPUT -j FB_OUTPUT 2>/dev/null || iptables -t nat -A OUTPUT -j FB_OUTPUT
  iptables -t nat -C POSTROUTING -j FB_POSTROUTING 2>/dev/null || iptables -t nat -A POSTROUTING -j FB_POSTROUTING
  iptables -C FORWARD -j FB_FORWARD 2>/dev/null || iptables -A FORWARD -j FB_FORWARD
}

flush_iptables_fb() {
  ensure_iptables_base
  iptables -t nat -F FB_PREROUTING || true
  iptables -t nat -F FB_OUTPUT || true
  iptables -t nat -F FB_POSTROUTING || true
  iptables -F FB_FORWARD || true
}

service_has_rules() {
  local method="$1" db_file="${2:-$RULES_DB}"
  grep -qE "^[^|]+\|${method}\|" "$db_file"
}

apply_iptables_rules_from_db() {
  local db_file="${1:-$RULES_DB}"

  if ! cmd_exists iptables; then
    if service_has_rules iptables "$db_file"; then
      err "未找到 iptables 可执行文件，无法重建 iptables 规则。"
      return 1
    fi
    return 0
  fi

  ensure_iptables_base
  flush_iptables_fb

  while IFS='|' read -r id method proto listen_addr listen_port target_host target_port extra; do
    [[ -n "${id:-}" ]] || continue
    [[ "$method" == "iptables" ]] || continue

    local dnat_target
    dnat_target="${target_host}:${target_port}"

    if [[ "$listen_addr" == "0.0.0.0" || -z "$listen_addr" ]]; then
      iptables -t nat -A FB_PREROUTING -p "$proto" --dport "$listen_port" -m comment --comment "fb:$id" -j DNAT --to-destination "$dnat_target"
    else
      iptables -t nat -A FB_PREROUTING -p "$proto" -d "$listen_addr" --dport "$listen_port" -m comment --comment "fb:$id" -j DNAT --to-destination "$dnat_target"
      iptables -t nat -A FB_OUTPUT -p "$proto" -d "$listen_addr" --dport "$listen_port" -m comment --comment "fb:$id" -j DNAT --to-destination "$dnat_target"
    fi

    iptables -A FB_FORWARD -p "$proto" -d "$target_host" --dport "$target_port" -m comment --comment "fb:$id" -j ACCEPT
    iptables -t nat -A FB_POSTROUTING -p "$proto" -d "$target_host" --dport "$target_port" -m comment --comment "fb:$id" -j MASQUERADE
  done < "$db_file"
}

render_haproxy_config() {
  local db_file="${1:-$RULES_DB}"
  local cfg="$CONF_DIR/haproxy/haproxy.cfg"

  cat > "$cfg" <<'EOCFG'
global
    maxconn 20000
    log /dev/log local0

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 5s
    timeout client  2m
    timeout server  2m
EOCFG

  while IFS='|' read -r id method proto listen_addr listen_port target_host target_port extra; do
    [[ -n "${id:-}" ]] || continue
    [[ "$method" == "haproxy" ]] || continue
    cat >> "$cfg" <<EOBLK
frontend fe_${id//-/_}
    bind ${listen_addr}:${listen_port}
    default_backend be_${id//-/_}

backend be_${id//-/_}
    server s_${id//-/_} ${target_host}:${target_port} check

EOBLK
  done < "$db_file"
}

ensure_haproxy_service() {
  local haproxy_bin
  haproxy_bin="$(bin_path haproxy)"
  [[ -n "$haproxy_bin" ]] || { err "未找到 haproxy 可执行文件。"; return 1; }

  create_or_update_service "fb-haproxy.service" "[Unit]
Description=FB dedicated HAProxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$haproxy_bin -W -db -f $CONF_DIR/haproxy/haproxy.cfg
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target"
}

render_rinetd_config() {
  local db_file="${1:-$RULES_DB}"
  local cfg="$CONF_DIR/rinetd/rinetd.conf"
  mkdir -p "$CONF_DIR/rinetd"
  : > "$cfg"

  while IFS='|' read -r id method proto listen_addr listen_port target_host target_port extra; do
    [[ -n "${id:-}" ]] || continue
    [[ "$method" == "rinetd" ]] || continue
    echo "${listen_addr} ${listen_port} ${target_host} ${target_port}" >> "$cfg"
  done < "$db_file"
}

ensure_rinetd_service() {
  local rinetd_bin
  rinetd_bin="$(bin_path rinetd)"
  [[ -n "$rinetd_bin" ]] || { err "未找到 rinetd 可执行文件。"; return 1; }

  create_or_update_service "fb-rinetd.service" "[Unit]
Description=FB dedicated rinetd
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$rinetd_bin -f -c $CONF_DIR/rinetd/rinetd.conf
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target"
}

render_nginx_config() {
  local db_file="${1:-$RULES_DB}"
  local cfg="$CONF_DIR/nginx/nginx.conf"
  local stream_dir="$CONF_DIR/nginx/streams"

  mkdir -p "$stream_dir"
  rm -f "$stream_dir"/*.conf

  while IFS='|' read -r id method proto listen_addr listen_port target_host target_port extra; do
    [[ -n "${id:-}" ]] || continue
    [[ "$method" == "nginx" ]] || continue
    cat > "$stream_dir/${id}.conf" <<EORULE
server {
    listen ${listen_addr}:${listen_port};
    proxy_connect_timeout 5s;
    proxy_timeout 2m;
    proxy_pass ${target_host}:${target_port};
}
EORULE
  done < "$db_file"

  local module_line=""
  if [[ -f /usr/lib/nginx/modules/ngx_stream_module.so ]]; then
    module_line="load_module /usr/lib/nginx/modules/ngx_stream_module.so;"
  elif [[ -f /usr/lib64/nginx/modules/ngx_stream_module.so ]]; then
    module_line="load_module /usr/lib64/nginx/modules/ngx_stream_module.so;"
  fi

  cat > "$cfg" <<EOCFG
${module_line}
worker_processes auto;
pid /run/fb-nginx.pid;
error_log ${LOG_DIR}/nginx-error.log warn;

events {
    worker_connections 4096;
}

stream {
    access_log ${LOG_DIR}/nginx-stream-access.log;
    include ${stream_dir}/*.conf;
}
EOCFG
}

ensure_nginx_service() {
  local nginx_bin
  nginx_bin="$(bin_path nginx)"
  [[ -n "$nginx_bin" ]] || { err "未找到 nginx 可执行文件。"; return 1; }

  create_or_update_service "fb-nginx.service" "[Unit]
Description=FB dedicated Nginx stream
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$nginx_bin -g 'daemon off;' -c $CONF_DIR/nginx/nginx.conf
ExecStop=$nginx_bin -s quit -c $CONF_DIR/nginx/nginx.conf
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target"
}

make_socat_service() {
  local id="$1" proto="$2" listen_addr="$3" listen_port="$4" target_host="$5" target_port="$6"
  local socat_bin cmd
  socat_bin="$(bin_path socat)"
  [[ -n "$socat_bin" ]] || { err "未找到 socat 可执行文件。"; return 1; }

  if [[ "$proto" == "tcp" ]]; then
    cmd="$socat_bin TCP-LISTEN:${listen_port},bind=${listen_addr},fork,reuseaddr TCP:${target_host}:${target_port}"
  else
    cmd="$socat_bin UDP-LISTEN:${listen_port},bind=${listen_addr},fork,reuseaddr UDP:${target_host}:${target_port}"
  fi

  create_or_update_service "fb-socat-${id}.service" "[Unit]
Description=FB socat ${id}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${cmd}
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target"
}

make_gost_service() {
  local id="$1" listen_addr="$2" listen_port="$3" target_host="$4" target_port="$5"
  local gost_bin
  gost_bin="$(find_gost_binary)"
  [[ -n "$gost_bin" ]] || { err "未找到 gost 可执行文件。"; return 1; }

  create_or_update_service "fb-gost-${id}.service" "[Unit]
Description=FB gost ${id}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$gost_bin -L=tcp://${listen_addr}:${listen_port}/${target_host}:${target_port}
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target"
}

make_realm_config_and_service() {
  local id="$1" listen_addr="$2" listen_port="$3" target_host="$4" target_port="$5"
  local realm_bin
  realm_bin="$(find_realm_binary || true)"
  [[ -n "$realm_bin" ]] || { err "未找到 realm 可执行文件。"; return 1; }

  mkdir -p "$CONF_DIR/realm"

  cat > "$CONF_DIR/realm/${id}.toml" <<EOCFG
[log]
level = "info"

[[endpoints]]
listen = "${listen_addr}:${listen_port}"
remote = "${target_host}:${target_port}"
EOCFG

  create_or_update_service "fb-realm-${id}.service" "[Unit]
Description=FB realm ${id}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$realm_bin -c $CONF_DIR/realm/${id}.toml
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target"
}

stop_if_no_rules() {
  local method="$1" svc="$2" db_file="${3:-$RULES_DB}"
  if ! service_has_rules "$method" "$db_file"; then
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/$svc" 2>/dev/null || true
  fi
}

backup_configs() {
  need_root
  init_dirs

  local ts file tmp_file
  ts="$(date +%Y%m%d-%H%M%S)"
  file="$BACKUP_DIR/fb-backup-${ts}.tar.gz"
  tmp_file="$TMP_DIR/fb-backup-${ts}.tar.gz"

  rm -f "$tmp_file"
  tar --exclude="$BACKUP_DIR" --exclude="$BACKUP_DIR/*" -czf "$tmp_file" "$CONF_DIR" "$SYSTEMD_DIR"/fb-*.service 2>/dev/null \
    || tar --exclude="$BACKUP_DIR" --exclude="$BACKUP_DIR/*" -czf "$tmp_file" "$CONF_DIR"

  mv -f "$tmp_file" "$file"
  echo "$file"
}

list_backups() {
  init_dirs
  ls -1t "$BACKUP_DIR"/fb-backup-*.tar.gz 2>/dev/null || true
}

latest_backup() {
  list_backups | head -n1
}

is_port_listening() {
  local port="$1" proto="${2:-tcp}"
  if [[ "$proto" == "udp" ]]; then
    ss -lnu 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[:\]])${port}$"
  else
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[:\]])${port}$"
  fi
}

rebuild_services_from_db() {
  local db_file="${1:-$RULES_DB}"
  need_root

  systemctl daemon-reload >/dev/null 2>&1 || true
  apply_iptables_rules_from_db "$db_file" || return 1

  if service_has_rules haproxy "$db_file"; then
    local haproxy_bin
    render_haproxy_config "$db_file" || return 1
    ensure_haproxy_service || return 1
    systemctl daemon-reload >/dev/null 2>&1 || true
    haproxy_bin="$(bin_path haproxy)"
    [[ -n "$haproxy_bin" ]] || return 1
    "$haproxy_bin" -c -f "$CONF_DIR/haproxy/haproxy.cfg" >/dev/null 2>&1 || return 1
    systemctl enable --now fb-haproxy.service >/dev/null 2>&1 || systemctl restart fb-haproxy.service || return 1
  else
    stop_if_no_rules haproxy fb-haproxy.service "$db_file"
  fi

  if service_has_rules rinetd "$db_file"; then
    render_rinetd_config "$db_file" || return 1
    ensure_rinetd_service || return 1
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now fb-rinetd.service >/dev/null 2>&1 || systemctl restart fb-rinetd.service || return 1
  else
    stop_if_no_rules rinetd fb-rinetd.service "$db_file"
  fi

  if service_has_rules nginx "$db_file"; then
    local nginx_bin
    render_nginx_config "$db_file" || return 1
    ensure_nginx_service || return 1
    systemctl daemon-reload >/dev/null 2>&1 || true
    nginx_bin="$(bin_path nginx)"
    [[ -n "$nginx_bin" ]] || return 1
    "$nginx_bin" -t -c "$CONF_DIR/nginx/nginx.conf" >/dev/null 2>&1 || return 1
    systemctl enable --now fb-nginx.service >/dev/null 2>&1 || systemctl restart fb-nginx.service || return 1
  else
    stop_if_no_rules nginx fb-nginx.service "$db_file"
  fi

  local current_units
  current_units="$(find "$SYSTEMD_DIR" -maxdepth 1 -type f \( -name 'fb-socat-*.service' -o -name 'fb-gost-*.service' -o -name 'fb-realm-*.service' \) -printf '%f\n' 2>/dev/null || true)"
  if [[ -n "$current_units" ]]; then
    while IFS= read -r unit; do
      [[ -n "$unit" ]] || continue
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
      rm -f "$SYSTEMD_DIR/$unit"
    done <<< "$current_units"
  fi

  while IFS='|' read -r id method proto listen_addr listen_port target_host target_port extra; do
    [[ -n "${id:-}" ]] || continue
    case "$method" in
      socat)
        make_socat_service "$id" "$proto" "$listen_addr" "$listen_port" "$target_host" "$target_port" || return 1
        ;;
      gost)
        make_gost_service "$id" "$listen_addr" "$listen_port" "$target_host" "$target_port" || return 1
        ;;
      realm)
        make_realm_config_and_service "$id" "$listen_addr" "$listen_port" "$target_host" "$target_port" || return 1
        ;;
    esac
  done < "$db_file"

  systemctl daemon-reload >/dev/null 2>&1 || true

  while IFS='|' read -r id method proto listen_addr listen_port target_host target_port extra; do
    [[ -n "${id:-}" ]] || continue
    case "$method" in
      socat)
        systemctl enable --now "fb-socat-${id}.service" >/dev/null 2>&1 || systemctl restart "fb-socat-${id}.service" || return 1
        ;;
      gost)
        systemctl enable --now "fb-gost-${id}.service" >/dev/null 2>&1 || systemctl restart "fb-gost-${id}.service" || return 1
        ;;
      realm)
        systemctl enable --now "fb-realm-${id}.service" >/dev/null 2>&1 || systemctl restart "fb-realm-${id}.service" || return 1
        ;;
    esac
  done < "$db_file"

  return 0
}

ensure_rule_validity() {
  local method="$1" proto="$2" listen_addr="$3" listen_port="$4" target_host="$5" target_port="$6" db_file="${7:-$RULES_DB}"

  [[ -n "$method" && -n "$proto" && -n "$listen_addr" && -n "$listen_port" && -n "$target_host" && -n "$target_port" ]] || die "参数不足。"
  validate_proto "$proto" || die "协议只支持 tcp / udp"
  method_supports_proto "$method" "$proto" || die "方法 $method 不支持协议 $proto"
  validate_port "$listen_port" || die "监听端口无效：$listen_port"
  validate_port "$target_port" || die "目标端口无效：$target_port"

  grep -qE "^[^|]+\|${method}\|${proto}\|${listen_addr}\|${listen_port}\|${target_host}\|${target_port}(\||$)" "$db_file" 2>/dev/null && die "已存在相同规则。"
  return 0
}

prepare_method_runtime() {
  local method="$1"
  init_dirs
  ensure_base_layout

  if is_test_mode; then
    install_rebuild_service || true
    return 0
  fi

  install_base
  install_method_deps "$method"
  verify_method_ready "$method"
  optimize_network
  install_rebuild_service
}

persist_rule_only() {
  local method="$1" proto="$2" listen_addr="$3" listen_port="$4" target_host="$5" target_port="$6" extra="${7:-}" db_file="${8:-$RULES_DB}"
  local id
  id="$(next_rule_id)"
  save_rule "$id" "$method" "$proto" "$listen_addr" "$listen_port" "$target_host" "$target_port" "$extra" "$db_file"
  printf '%s' "$id"
}

new_temp_rules_db() {
  local temp_db
  init_dirs
  temp_db="$(mktemp "$TMP_DIR/rules.XXXXXX")"
  cp "$RULES_DB" "$temp_db"
  printf '%s' "$temp_db"
}

commit_rules_db_transaction() {
  local staged_db="$1" action="${2:-规则变更}"
  local rollback_db backup_file

  rollback_db="$(mktemp "$TMP_DIR/rules.rollback.XXXXXX")"
  cp "$RULES_DB" "$rollback_db"

  backup_file="$(backup_configs | tail -n1)"
  cp "$staged_db" "$RULES_DB"

  if rebuild_services_from_db "$RULES_DB" >/dev/null; then
    rm -f "$staged_db" "$rollback_db"
    printf '%s' "$backup_file"
    return 0
  fi

  err "${action}失败，正在回滚到变更前状态..."
  cp "$rollback_db" "$RULES_DB"
  if ! rebuild_services_from_db "$RULES_DB" >/dev/null; then
    err "自动回滚后的服务重建也失败，请优先执行：fb restore $backup_file"
  fi
  rm -f "$staged_db" "$rollback_db"
  die "${action}失败，已回滚。变更前备份：$backup_file"
}

cleanup_rule_artifacts() {
  local id="$1"
  rm -f "$CONF_DIR/realm/${id}.toml" "$CONF_DIR/nginx/streams/${id}.conf" 2>/dev/null || true
}

add_rule() {
  need_root
  local method="$1" proto="$2" listen_addr="$3" listen_port="$4" target_host="$5" target_port="$6" extra="${7:-}"
  local id backup_file staged_db

  prepare_method_runtime "$method"
  staged_db="$(new_temp_rules_db)"
  ensure_rule_validity "$method" "$proto" "$listen_addr" "$listen_port" "$target_host" "$target_port" "$staged_db"
  check_listen_conflict "$method" "$proto" "$listen_addr" "$listen_port"

  id="$(persist_rule_only "$method" "$proto" "$listen_addr" "$listen_port" "$target_host" "$target_port" "$extra" "$staged_db")"
  backup_file="$(commit_rules_db_transaction "$staged_db" "添加规则")"

  log "规则已添加：[$id] $method $proto ${listen_addr}:${listen_port} -> ${target_host}:${target_port}"
  log "已自动备份到：$backup_file"
}

batch_add_rules() {
  need_root
  local method="$1" proto="$2" listen_addr="$3" start_listen_port="$4" default_target_port="$5" targets_csv="$6" extra="${7:-}"

  [[ -n "$targets_csv" ]] || die "请提供多个目标 IP/域名，使用逗号分隔。"
  validate_port "$start_listen_port" || die "起始监听端口无效：$start_listen_port"
  validate_port "$default_target_port" || die "默认目标端口无效：$default_target_port"
  validate_proto "$proto" || die "协议只支持 tcp / udp"
  method_supports_proto "$method" "$proto" || die "方法 $method 不支持协议 $proto"

  prepare_method_runtime "$method"

  local staged_db
  staged_db="$(new_temp_rules_db)"

  local IFS=','
  local targets=()
  read -r -a targets <<< "$targets_csv"

  local idx=0 added=0 entry target_host target_port listen_port id backup_file
  local summaries=()

  for entry in "${targets[@]}"; do
    entry="$(trim "$entry")"
    [[ -n "$entry" ]] || continue

    target_host="$entry"
    target_port="$default_target_port"

    if [[ "$entry" =~ ^([^:]+):([0-9]+)$ ]]; then
      target_host="${BASH_REMATCH[1]}"
      target_port="${BASH_REMATCH[2]}"
    fi

    listen_port=$((start_listen_port + idx))
    (( listen_port <= 65535 )) || die "批量添加失败：监听端口超过 65535。"

    ensure_rule_validity "$method" "$proto" "$listen_addr" "$listen_port" "$target_host" "$target_port" "$staged_db"
    check_listen_conflict "$method" "$proto" "$listen_addr" "$listen_port"

    id="$(persist_rule_only "$method" "$proto" "$listen_addr" "$listen_port" "$target_host" "$target_port" "$extra" "$staged_db")"
    summaries+=("[$id] ${listen_addr}:${listen_port} -> ${target_host}:${target_port}")
    idx=$((idx + 1))
    added=$((added + 1))
  done

  (( added > 0 )) || die "没有可添加的有效目标。"

  backup_file="$(commit_rules_db_transaction "$staged_db" "批量添加规则")"

  log "批量添加完成：共 ${added} 条，方案=${method}，协议=${proto}"
  local item
  for item in "${summaries[@]}"; do
    echo "  $item"
  done
  log "已自动备份到：$backup_file"
}

delete_rule() {
  need_root
  local id="$1" backup_file staged_db
  [[ -n "$id" ]] || die "请提供规则 ID。"
  get_rule_line "$id" | grep -q . || die "规则不存在：$id"

  staged_db="$(new_temp_rules_db)"
  remove_rule_line "$id" "$staged_db"
  backup_file="$(commit_rules_db_transaction "$staged_db" "删除规则")"
  cleanup_rule_artifacts "$id"

  log "规则已删除：$id"
  log "删除前备份：$backup_file"
}

stop_all_services() {
  need_root
  local units
  units="$(find "$SYSTEMD_DIR" -maxdepth 1 -type f -name 'fb-*.service' -printf '%f\n' 2>/dev/null | sort || true)"

  if [[ -z "$units" ]]; then
    warn "未发现 fb 相关服务。"
    return 0
  fi

  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    systemctl stop "$unit" >/dev/null 2>&1 || true
  done <<< "$units"

  log "已停止所有 fb 相关服务。"
}

uninstall_self() {
  need_root
  local keep="${1:-yes}"
  local delete_source="${2:-no}"
  local units

  if [[ "$keep" == "yes" ]]; then
    systemctl disable --now fb-rebuild.service >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/fb-rebuild.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -f "$SELF_TARGET"
    if [[ "$delete_source" == "yes" ]]; then
      delete_invocation_source_if_needed
    fi
    log "已卸载 fb 命令，现有转发服务与配置已保留。"
    warn "若当前使用 iptables 规则，系统重启后将不会自动重建；重新安装 fb 后可恢复开机重建。"
    return 0
  fi

  stop_all_services || true
  units="$(find "$SYSTEMD_DIR" -maxdepth 1 -type f -name 'fb-*.service' -printf '%f\n' 2>/dev/null | sort || true)"
  if [[ -n "$units" ]]; then
    while IFS= read -r unit; do
      [[ -n "$unit" ]] || continue
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
      rm -f "$SYSTEMD_DIR/$unit"
    done <<< "$units"
  fi

  cleanup_iptables_all || true
  cleanup_method_binaries || true
  systemctl daemon-reload >/dev/null 2>&1 || true

  rm -f "$SELF_TARGET"
  remove_network_optimization || true
  rm -rf "$CONF_DIR" "$LOG_DIR" "$STATE_DIR" "$TMP_DIR"

  if [[ "$delete_source" == "yes" ]]; then
    delete_invocation_source_if_needed
  fi

  log "已彻底卸载：脚本 / 服务 / 规则 / 配置 / 备份 均已删除。"
}

list_rules() {
  if ! [[ -s "$RULES_DB" ]]; then
    echo "当前没有规则。"
    return 0
  fi

  printf '%-22s %-9s %-5s %-22s %-8s %-24s %-8s\n' "RULE_ID" "METHOD" "PROTO" "LISTEN_ADDR" "LPORT" "TARGET_HOST" "TPORT"
  echo "---------------------------------------------------------------------------------------------------------------------"
  while IFS='|' read -r id method proto listen_addr listen_port target_host target_port extra; do
    [[ -n "${id:-}" ]] || continue
    printf '%-22s %-9s %-5s %-22s %-8s %-24s %-8s\n' "$id" "$method" "$proto" "$listen_addr" "$listen_port" "$target_host" "$target_port"
  done < "$RULES_DB"
}

rule_service_name() {
  local id="$1" method="$2"
  case "$method" in
    socat) echo "fb-socat-${id}.service" ;;
    gost) echo "fb-gost-${id}.service" ;;
    realm) echo "fb-realm-${id}.service" ;;
    haproxy) echo "fb-haproxy.service" ;;
    rinetd) echo "fb-rinetd.service" ;;
    nginx) echo "fb-nginx.service" ;;
    iptables) echo "fb-rebuild.service" ;;
    *) echo "-" ;;
  esac
}

iptables_rule_active() {
  local id="$1"
  cmd_exists iptables || return 1
  iptables -t nat -S FB_PREROUTING 2>/dev/null | grep -Fq -- "fb:${id}" && return 0
  iptables -t nat -S FB_OUTPUT 2>/dev/null | grep -Fq -- "fb:${id}" && return 0
  return 1
}

rule_is_active() {
  local id="$1" method="$2" svc
  case "$method" in
    iptables)
      iptables_rule_active "$id"
      ;;
    *)
      svc="$(rule_service_name "$id" "$method")"
      systemctl is-active --quiet "$svc" 2>/dev/null
      ;;
  esac
}

probe_target_ms() {
  local host="$1" port="$2"
  local start end diff

  if [[ "$port" =~ ^[0-9]+$ ]]; then
    start=$(date +%s%3N 2>/dev/null || date +%s000)
    if timeout 3 bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1; then
      end=$(date +%s%3N 2>/dev/null || date +%s000)
      diff=$((end - start))
      echo "${diff}ms"
    else
      echo "timeout"
    fi
  else
    echo "-"
  fi
}

system_flag() {
  local name="$1"
  case "$name" in
    ip_forward)
      [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" == "1" ]] && echo "已启用" || echo "未启用"
      ;;
    bbr)
      [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" == "bbr" ]] && echo "已启用" || echo "未启用"
      ;;
    tfo)
      [[ "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0)" =~ ^[13]$ ]] && echo "已启用" || echo "未启用"
      ;;
    *)
      echo "-"
      ;;
  esac
}

show_status_pretty() {
  init_dirs
  local count last_bak
  count="$(rule_count)"
  last_bak="$(latest_backup || true)"

  echo
  echo -e "${CW}==============================================================${C0}"
  echo -e "${CW}                    ${APP_DESC} ${C4}${APP_VERSION}${C0}"
  echo -e "${CW}==============================================================${C0}"
  echo -e "状态: ${C1}运行中${C0}    转发规则: ${CW}${count}${C0} 条"
  echo -e "命令: ${C4}fb${C0}"
  echo -e "${CW}==============================================================${C0}"
  echo
  echo -e "${C4}=== 活跃转发规则 ===${C0}"

  if [[ "$count" == "0" ]]; then
    echo "暂无规则"
  else
    while IFS='|' read -r id method proto listen_addr listen_port target_host target_port extra; do
      [[ -n "${id:-}" ]] || continue
      local mark listen_mark
      if rule_is_active "$id" "$method"; then
        mark="✅"
      else
        mark="⚠️"
      fi

      if is_port_listening "$listen_port" "$proto"; then
        listen_mark="监听中"
      else
        listen_mark="未监听"
      fi

      echo "$mark  ${method}  ${listen_addr}:${listen_port} -> ${target_host}:${target_port}  (${proto})  [${listen_mark}]"
    done < "$RULES_DB"
  fi

  echo
  echo -e "${C4}=== 延迟检测 ===${C0}"
  if [[ "$count" == "0" ]]; then
    echo "暂无规则"
  else
    while IFS='|' read -r id method proto listen_addr listen_port target_host target_port extra; do
      [[ -n "${id:-}" ]] || continue
      echo "${method} ${target_host}:${target_port} ... $(probe_target_ms "$target_host" "$target_port")"
    done < "$RULES_DB"
  fi

  echo
  echo -e "${C4}=== 系统配置 ===${C0}"
  echo "IP转发：$(system_flag ip_forward)"
  echo "BBR拥塞控制：$(system_flag bbr)"
  echo "TCP Fast Open：$(system_flag tfo)"
  if [[ -n "${last_bak:-}" ]]; then
    echo "最近备份：$last_bak"
  else
    echo "最近备份：暂无"
  fi

  echo
  echo -e "${C4}=== 当前监听端口（前 20 行） ===${C0}"
  ss -lntup 2>/dev/null | sed -n '1,20p' || true
}

status_rules() {
  if ! [[ -s "$RULES_DB" ]]; then
    echo "当前没有规则。"
    return 0
  fi

  printf '%-22s %-9s %-24s %-24s %-12s %-10s %-8s\n' "RULE_ID" "METHOD" "LISTEN" "TARGET" "SERVICE" "TARGET_RTT" "LISTEN"
  echo "--------------------------------------------------------------------------------------------------------------------------------"
  while IFS='|' read -r id method proto listen_addr listen_port target_host target_port extra; do
    [[ -n "${id:-}" ]] || continue
    local status rtt listen_state
    if rule_is_active "$id" "$method"; then
      status="active"
    else
      status="inactive"
    fi

    rtt="$(probe_target_ms "$target_host" "$target_port")"

    if is_port_listening "$listen_port" "$proto"; then
      listen_state="up"
    else
      listen_state="down"
    fi

    printf '%-22s %-9s %-24s %-24s %-12s %-10s %-8s\n' \
      "$id" "$method" "${listen_addr}:${listen_port}" "${target_host}:${target_port}" "$status" "$rtt" "$listen_state"
  done < "$RULES_DB"
}

show_detail() {
  local id="$1"
  local line svc

  line="$(get_rule_line "$id")"
  [[ -n "$line" ]] || die "规则不存在：$id"

  IFS='|' read -r id method proto listen_addr listen_port target_host target_port extra <<< "$line"
  svc="$(rule_service_name "$id" "$method")"

  echo "ID          : $id"
  echo "METHOD      : $method"
  echo "PROTO       : $proto"
  echo "LISTEN      : ${listen_addr}:${listen_port}"
  echo "TARGET      : ${target_host}:${target_port}"
  echo "SERVICE     : $svc"
  echo "LISTENING   : $(is_port_listening "$listen_port" "$proto" && echo yes || echo no)"
  echo "TARGET RTT  : $(probe_target_ms "$target_host" "$target_port")"
  echo

  systemctl status "$svc" --no-pager -l 2>/dev/null || true
}

restore_configs() {
  need_root
  local file="$1" current_backup
  [[ -f "$file" ]] || die "备份文件不存在：$file"

  current_backup="$(backup_configs | tail -n1)"
  tar -xzf "$file" -C /
  systemctl daemon-reload >/dev/null 2>&1 || true

  if ! rebuild_services_from_db >/dev/null; then
    err "备份恢复失败，正在尝试回滚到恢复前状态..."
    tar -xzf "$current_backup" -C /
    systemctl daemon-reload >/dev/null 2>&1 || true
    rebuild_services_from_db >/dev/null || true
    die "备份恢复失败，已尝试回滚。恢复前备份：$current_backup"
  fi

  log "备份已恢复：$file"
}

show_active_listeners() {
  echo "当前监听端口："
  ss -lntup 2>/dev/null | sed -n '1,80p'
}

show_logs() {
  local lines="${1:-100}"
  local units=()

  while IFS= read -r u; do
    [[ -n "$u" ]] && units+=("-u" "$u")
  done < <(find "$SYSTEMD_DIR" -maxdepth 1 -type f -name 'fb-*.service' -printf '%f\n' 2>/dev/null | sort || true)

  if [[ ${#units[@]} -gt 0 ]] && command -v journalctl >/dev/null 2>&1; then
    if journalctl --no-pager -n "$lines" "${units[@]}" 2>/dev/null; then
      return 0
    fi
  fi

  if [[ -f "$FB_LOG_FILE" ]]; then
    tail -n "$lines" "$FB_LOG_FILE"
  else
    warn "未发现 fb 相关服务日志。"
  fi
}

recommendation_table() {
  cat <<'EOT'
方案选择建议：
  游戏加速      -> iptables     （内核转发，延迟最低）
  RDP / VNC     -> iptables     （简单直接）
  SSH 中转      -> realm / iptables
  Web 服务      -> HAProxy / nginx
  需要加密      -> gost
  多端口转发    -> rinetd
EOT
}

help_msg() {
  cat <<'EOH'
端口转发管理工具 - fb

支持的方法：
  iptables / haproxy / socat / gost / realm / rinetd / nginx(stream)

协议支持：
  iptables : tcp / udp
  socat    : tcp / udp
  gost     : tcp
  realm    : tcp
  haproxy  : tcp
  rinetd   : tcp
  nginx    : tcp

常用命令：
  fb install-self
  fb install-base
  fb optimize
  fb add METHOD PROTO LISTEN_ADDR LISTEN_PORT TARGET_HOST TARGET_PORT
  fb batch-add METHOD PROTO LISTEN_ADDR START_LISTEN_PORT TARGET_PORT TARGET1,TARGET2,...
  fb del RULE_ID
  fb list
  fb status
  fb pretty-status
  fb logs [行数]
  fb backup
  fb backups
  fb restore /path/to/backup.tar.gz
  fb rebuild
  fb stop
  fb uninstall [keep|purge]
  fb purge
  fb menu

示例：
  fb add socat tcp 0.0.0.0 3389 10.0.0.2 3389
  fb add iptables udp 0.0.0.0 27015 1.2.3.4 27015
  fb add nginx tcp 0.0.0.0 2222 127.0.0.1 22
  fb batch-add realm tcp 0.0.0.0 33001 22 1.1.1.1,2.2.2.2,3.3.3.3:2222

一键菜单：
  bash <(curl -fsSL https://raw.githubusercontent.com/fengbule/zhuanfa/main/fb.sh)

说明：
  1. 默认基于 systemd。
  2. iptables 使用独立 FB_* 链，不会直接清空你现有的其他规则。
  3. haproxy / rinetd / nginx 使用“专用实例”配置，不覆盖你已有主服务配置。
  4. gost / realm 若自动安装失败，请手动将二进制放入 PATH；realm 会优先使用专用的 fb-realm，避免与系统 realmd 的 realm 冲突。
  5. batch-add 为“同一方案批量添加多 IP”模式，会按起始监听端口依次递增。
  6. 规则变更采用临时库 + 自动备份，重建失败会自动回滚。
  7. fb uninstall 仅卸载命令与开机重建入口，现有转发服务和配置会保留。
EOH
}

pause_enter() {
  read_prompt _ "按回车继续..."
}

show_banner() {
  local count
  count="$(rule_count)"
  clear || true
  echo -e "${CW}==============================================================${C0}"
  echo -e "${CW}                    ${APP_DESC} ${C4}${APP_VERSION}${C0}"
  echo -e "${CW}==============================================================${C0}"
  echo -e "状态: ${C1}运行中${C0}    转发规则: ${CW}${count}${C0} 条"
  echo -e "命令: ${C4}fb${C0}"
  echo -e "${CW}==============================================================${C0}"
  echo
}

interactive_pick_method() {
  local __result_var="${1:-}"
  local picked=""

  echo -e "${C4}========== 转发方案对比 ==========${C0}"
  echo "1) iptables     - 延迟：低    | 适用：游戏 / RDP / VNC"
  echo "2) HAProxy      - 延迟：较低  | 适用：Web 服务 / 负载均衡"
  echo "3) socat        - 延迟：较低  | 适用：通用 TCP / UDP 转发"
  echo "4) gost         - 延迟：中等  | 适用：加密代理 / 多协议"
  echo "5) realm        - 延迟：较低  | 适用：高并发 TCP 中转"
  echo "6) rinetd       - 延迟：较低  | 适用：多端口 TCP 转发"
  echo "7) nginx stream - 延迟：较低  | 适用：Web 场景 / SSL"
  echo
  echo "性能排序：iptables > realm > HAProxy/nginx > socat/rinetd > gost"
  echo "功能排序：gost > nginx/HAProxy > realm > socat/rinetd > iptables"

  local n
  read_prompt n "请选择方案 [1]: "
  n="${n:-1}"

  case "$n" in
    1) picked="iptables" ;;
    2) picked="haproxy" ;;
    3) picked="socat" ;;
    4) picked="gost" ;;
    5) picked="realm" ;;
    6) picked="rinetd" ;;
    7) picked="nginx" ;;
    *) die "无效选择。" ;;
  esac

  if [[ -n "$__result_var" ]]; then
    printf -v "$__result_var" '%s' "$picked"
  else
    printf '%s\n' "$picked"
  fi
}

installed_self_version() {
  [[ -f "$SELF_TARGET" ]] || return 1
  sed -n 's/^APP_VERSION="${APP_VERSION:-\(v[^"]*\)}"/\1/p' "$SELF_TARGET" | head -n1
}

should_refresh_self_install() {
  [[ ! -x "$SELF_TARGET" ]] && return 0
  local installed_version
  installed_version="$(installed_self_version || true)"
  [[ -z "$installed_version" ]] && return 0
  [[ "$installed_version" != "$APP_VERSION" ]]
}

ensure_self_installed_for_menu() {
  should_refresh_self_install || return 0
  install_self
  install_rebuild_service
  if [[ -x "$SELF_TARGET" ]]; then
    log "已自动安装或更新命令：fb (${APP_VERSION})"
  fi
}

prompt_proto_for_method() {
  local method="$1" __result_var="${2:-}" proto_value="tcp"
  if [[ "$method" == "iptables" || "$method" == "socat" ]]; then
    read_prompt proto_value "协议类型 [tcp]: "
    proto_value="${proto_value:-tcp}"
  fi

  if [[ -n "$__result_var" ]]; then
    printf -v "$__result_var" '%s' "$proto_value"
  else
    printf '%s\n' "$proto_value"
  fi
}

menu_add_rule() {
  local method proto listen_addr listen_port target_host target_port status yn
  show_banner

  echo -e "${C4}请输入转发配置信息：${C0}"
  read_prompt target_host "目标服务器 IP/域名: "
  [[ -n "$target_host" ]] || die "目标地址不能为空。"

  status="$(resolve_host_status "$target_host")"
  if [[ "$status" == "ok" ]]; then
    echo -e "解析检测：${C1}有效${C0}"
  else
    echo -e "解析检测：${C2}未解析成功${C0}（若是内网目标或稍后可达，可继续）"
  fi

  read_prompt target_port "目标端口: "
  read_prompt listen_addr "本地监听地址 [0.0.0.0]: "
  listen_addr="${listen_addr:-$DEFAULT_LISTEN_ADDR}"
  read_prompt listen_port "本地监听端口: "

  echo
  interactive_pick_method method
  prompt_proto_for_method "$method" proto

  echo
  echo -e "${C4}配置确认：${C0}"
  echo "目标服务器：${target_host}:${target_port}"
  echo "本地监听：${listen_addr}:${listen_port}"
  echo "协议类型：${proto}"
  echo "转发方式：${method}"

  read_prompt yn "确认添加？[Y/n]: "
  yn="${yn:-Y}"
  [[ "$yn" =~ ^[Yy]$ ]] || return 0

  add_rule "$method" "$proto" "$listen_addr" "$listen_port" "$target_host" "$target_port"
}

menu_batch_add_rules() {
  local method proto listen_addr start_port target_port targets_csv yn
  show_banner

  echo -e "${C4}批量添加：同一方案同时转发多个 IP / 域名${C0}"
  echo "说明：会按起始监听端口自动递增，例如 33001,33002,33003 ..."
  echo "目标格式支持：1.1.1.1,2.2.2.2,example.com:2222"
  echo

  read_prompt targets_csv "多个目标 IP/域名（逗号分隔）: "
  [[ -n "$targets_csv" ]] || die "目标列表不能为空。"
  read_prompt target_port "默认目标端口: "
  read_prompt listen_addr "本地监听地址 [0.0.0.0]: "
  listen_addr="${listen_addr:-$DEFAULT_LISTEN_ADDR}"
  read_prompt start_port "起始本地监听端口: "

  echo
  interactive_pick_method method
  prompt_proto_for_method "$method" proto

  echo
  echo -e "${C4}配置确认：${C0}"
  echo "目标列表：$targets_csv"
  echo "默认目标端口：$target_port"
  echo "本地监听地址：$listen_addr"
  echo "起始监听端口：$start_port"
  echo "协议类型：$proto"
  echo "转发方式：$method"

  read_prompt yn "确认批量添加？[Y/n]: "
  yn="${yn:-Y}"
  [[ "$yn" =~ ^[Yy]$ ]] || return 0

  batch_add_rules "$method" "$proto" "$listen_addr" "$start_port" "$target_port" "$targets_csv"
}

menu_delete_rule() {
  local id yn
  show_banner
  list_rules
  echo
  read_prompt id "输入要删除的规则 ID: "
  [[ -n "${id:-}" ]] || return 0
  read_prompt yn "确认删除？[y/N]: "
  [[ "$yn" =~ ^[Yy]$ ]] || return 0
  delete_rule "$id"
}

menu_show_logs() {
  show_banner
  show_logs 120 || true
}

menu_backups() {
  show_banner
  echo "备份文件列表："
  list_backups || true
}

menu_restore_backup() {
  local f
  show_banner
  echo "可用备份："
  list_backups || true
  echo
  read_prompt f "输入备份文件完整路径: "
  [[ -n "${f:-}" ]] || return 0
  restore_configs "$f"
}

menu_stop_services() {
  local yn
  show_banner
  read_prompt yn "确认停止所有 fb 相关服务？[y/N]: "
  [[ "$yn" =~ ^[Yy]$ ]] || return 0
  stop_all_services
}

menu_uninstall() {
  local n
  show_banner
  echo "1) 仅卸载 fb 命令，保留现有转发服务和配置"
  echo "2) 彻底卸载（删除脚本 / 服务 / 配置 / 备份 / 网络优化）"
  echo "3) 彻底卸载，并删除当前这个脚本文件"
  read_prompt n "请选择 [1]: "
  n="${n:-1}"

  case "$n" in
    1) uninstall_self yes ;;
    2) uninstall_self no ;;
    3) uninstall_self no yes ;;
    *) warn "无效选择。" ;;
  esac
}

menu_loop() {
  while true; do
    show_banner
    echo "1) 配置新的端口转发"
    echo "2) 批量添加同方案多 IP 转发"
    echo "3) 查看当前转发状态"
    echo "4) 查看运行日志"
    echo "5) 停止转发服务"
    echo "6) 查看备份文件"
    echo "7) 恢复备份"
    echo "8) 删除转发规则"
    echo "9) 重新应用全部规则"
    echo "10) 应用网络优化"
    echo "11) 安装脚本到系统命令 fb"
    echo "12) 卸载 / 删除脚本"
    echo "13) 查看方案推荐"
    echo "0) 退出"
    echo

    local choice
    read_prompt choice "请选择操作 [1]: "
    choice="${choice:-1}"

    case "$choice" in
      1) menu_add_rule; pause_enter ;;
      2) menu_batch_add_rules; pause_enter ;;
      3) show_banner; show_status_pretty; pause_enter ;;
      4) menu_show_logs; pause_enter ;;
      5) menu_stop_services; pause_enter ;;
      6) menu_backups; pause_enter ;;
      7) menu_restore_backup; pause_enter ;;
      8) menu_delete_rule; pause_enter ;;
      9) rebuild_services_from_db; log "已重新应用全部规则。"; pause_enter ;;
      10) optimize_network; pause_enter ;;
      11) install_self; install_rebuild_service; pause_enter ;;
      12) menu_uninstall; pause_enter ;;
      13) show_banner; recommendation_table; pause_enter ;;
      0) exit 0 ;;
      *) warn "无效选择。"; pause_enter ;;
    esac
  done
}

main() {
  init_dirs
  ensure_base_layout

  local cmd="${1:-menu}"
  case "$cmd" in
    install-self)
      need_root
      need_systemd
      init_dirs
      ensure_base_layout
      install_self
      install_rebuild_service
      ;;
    install-base)
      need_root
      install_base
      ;;
    optimize)
      need_root
      optimize_network
      ;;
    install)
      need_root
      need_systemd
      install_base
      install_method_deps "${2:-}"
      ;;
    add)
      need_root
      need_systemd
      add_rule "${2:-}" "${3:-}" "${4:-$DEFAULT_LISTEN_ADDR}" "${5:-}" "${6:-}" "${7:-}" "${8:-}"
      ;;
    batch-add)
      need_root
      need_systemd
      batch_add_rules "${2:-}" "${3:-}" "${4:-$DEFAULT_LISTEN_ADDR}" "${5:-}" "${6:-}" "${7:-}" "${8:-}"
      ;;
    del|delete|rm)
      need_root
      need_systemd
      delete_rule "${2:-}"
      ;;
    list)
      list_rules
      ;;
    status)
      status_rules
      ;;
    pretty-status|ps)
      show_status_pretty
      ;;
    detail)
      show_detail "${2:-}"
      ;;
    backup)
      backup_configs
      ;;
    backups)
      list_backups
      ;;
    restore)
      need_root
      need_systemd
      restore_configs "${2:-}"
      ;;
    rebuild|rebuild-onboot|start)
      need_root
      need_systemd
      rebuild_services_from_db
      ;;
    stop)
      need_root
      stop_all_services
      ;;
    listeners)
      show_active_listeners
      ;;
    logs)
      show_logs "${2:-100}"
      ;;
    uninstall)
      need_root
      if [[ "${2:-keep}" == "purge" ]]; then
        uninstall_self no
      else
        uninstall_self yes
      fi
      ;;
    purge|nuke|remove-all)
      need_root
      uninstall_self no yes
      ;;
    recommend)
      recommendation_table
      ;;
    menu)
      need_root
      need_systemd
      ensure_self_installed_for_menu
      menu_loop
      ;;
    help|-h|--help)
      help_msg
      ;;
    *)
      help_msg
      exit 1
      ;;
  esac
}

main "$@"
