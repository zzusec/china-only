#!/bin/bash
# =============================================================================
# china-only —— macOS 中国 IP 白名单防火墙（基于系统自带 PF）
#
# 目标：
#   1. 未开代理时：只允许访问中国 IP（以及内网/回环），禁止访问任何国外 IP。
#   2. 开代理时：访问国外站点必须经过代理（代理服务器地址被单独放行），
#      禁止用本机中国 IP 直接连国外。
#   3. 规则写入系统网络层（PF 包过滤），支持 安装 / 卸载 / 重装 / 更新。
#
# 原理：
#   - 出站方向白名单：放行 中国IP、内网、回环、代理服务器地址、（可选 DNS）；
#     其余出站（即国外 IP）一律 drop。
#   - 中国 IP 段来自公开 IP 库（默认 17mon，失败回退 ipdeny），本地缓存。
#   - 通过修改 /etc/pf.conf 注入一个 anchor 实现开机持久化。
#
# 重要：
#   - 需要 root 权限（脚本会自动通过 sudo 提权）。
#   - 代理必须把服务器地址/网段显式加入放行名单（PROXY_HOSTS / PROXY_CIDRS），
#     否则代理进程自己也无法连国外服务器。
#   - 意外锁死时的逃生通道：`sudo pfctl -d`（关闭 PF），或 `sudo china-only uninstall`。
# =============================================================================
set -euo pipefail

VERSION="1.0.0"

INSTALL_DIR="/usr/local/share/china-only"
ANCHOR_FILE="/etc/pf.anchors/china-only"
PF_CONF="/etc/pf.conf"
PF_CONF_BAK="/etc/pf.conf.china-only.bak"
CONF_FILE="$INSTALL_DIR/china-only.conf"
CHINA_ZONE="$INSTALL_DIR/china.zone"
PROXY_ZONE="$INSTALL_DIR/proxy.zone"
STATE_FILE="$INSTALL_DIR/state"
BIN_LINK="/usr/local/bin/china-only"

DEFAULT_CHINA_ZONE_URL="https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"
ALT_CHINA_ZONE_URL="https://www.ipdeny.com/ipblocks/data/countries/cn.zone"

CHINA_ONLY_BEGIN="# >>> china-only begin (do not edit) >>>"
CHINA_ONLY_END="# <<< china-only end <<<"

# --- 默认配置（会被 CONF_FILE 覆盖） ---
PROXY_HOSTS="${PROXY_HOSTS:-}"
PROXY_CIDRS="${PROXY_CIDRS:-}"
PROXY_UIDS="${PROXY_UIDS:-}"
ALLOW_FOREIGN_DNS="${ALLOW_FOREIGN_DNS:-1}"
BLOCK_IPV6="${BLOCK_IPV6:-1}"
CHINA_ZONE_URL="${CHINA_ZONE_URL:-$DEFAULT_CHINA_ZONE_URL}"
CHINA6_ZONE="${CHINA6_ZONE:-}"

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/$(basename "${BASH_SOURCE[0]}")"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
china-only —— 中国 IP 白名单防火墙

用法:
  china-only install             安装：下载IP库、写入PF规则、注入 pf.conf 并生效
  china-only uninstall [--purge] 卸载：还原 pf.conf、移除规则（--purge 连IP库一起删）
  china-only update              更新中国 IP 库并重新加载
  china-only reload              重新生成规则并加载（改完配置后执行）
  china-only enable              重新启用规则（运行时）
  china-only disable             临时关闭规则（不删除安装）
  china-only status              查看状态与配置
  china-only set KEY VALUE       设置配置项并重载，例如:
                                   china-only set PROXY_HOSTS "a.example.com,b.example.com"
                                   china-only set PROXY_CIDRS "1.2.3.0/24,5.6.7.0/24"
                                   china-only set ALLOW_FOREIGN_DNS 0
  china-only set-china-dns       把本机 DNS 设为 223.5.5.5 / 119.29.29.29（严格模式用）
  china-only help                显示本帮助

配置项 (存于 /usr/local/share/china-only/china-only.conf):
  PROXY_HOSTS        代理服务器域名，逗号分隔（reload 时解析为 IP 放行）
  PROXY_CIDRS        代理服务器网段，逗号分隔，直接放行
  PROXY_UIDS         代理进程所属 UID（实验性，逗号分隔）
  ALLOW_FOREIGN_DNS  1=允许访问任意 DNS（默认，保证可用） 0=禁止国外 DNS（需中国 DNS）
  BLOCK_IPV6         1=封禁国外 IPv6（默认，防泄露） 0=不处理 IPv6
  CHINA_ZONE_URL     中国 IP 库下载地址
  CHINA6_ZONE        可选的中国 IPv6 段文件路径
EOF
}

# ---------------------------------------------------------------------------
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if [ -t 0 ] || [ -t 1 ]; then
      printf '需要 root 权限，正在通过 sudo 提权…\n'
    fi
    exec sudo -E bash "$SCRIPT_PATH" "$@"
  fi
}

load_config() {
  [ -f "$CONF_FILE" ] && . "$CONF_FILE" || true
}

write_default_conf() {
  cat > "$CONF_FILE" <<'EOF'
# china-only 配置文件（修改后运行: sudo china-only reload）
PROXY_HOSTS=
PROXY_CIDRS=
PROXY_UIDS=
ALLOW_FOREIGN_DNS=1
BLOCK_IPV6=1
CHINA_ZONE_URL=https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt
CHINA6_ZONE=
EOF
}

# ---------------------------------------------------------------------------
download_china_zone() {
  local urls=("$CHINA_ZONE_URL" "$ALT_CHINA_ZONE_URL")
  local url
  for url in "${urls[@]}"; do
    [ -z "$url" ] && continue
    echo "    尝试: $url"
    if curl -fsSL --connect-timeout 20 "$url" -o "$CHINA_ZONE.tmp" 2>/dev/null; then
      grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' "$CHINA_ZONE.tmp" > "$CHINA_ZONE" || true
      rm -f "$CHINA_ZONE.tmp"
      echo "    已获取 $(wc -l < "$CHINA_ZONE" | tr -d ' ') 条"
      return 0
    fi
  done
  if [ -f "$CHINA_ZONE" ]; then
    warn "全部下载失败，使用本地已有 IP 库"
    return 0
  fi
  die "中国 IP 库下载失败，且本地无缓存"
}

resolve_proxy() {
  : > "$PROXY_ZONE"
  local cidr host ip
  for cidr in $(echo "$PROXY_CIDRS" | tr ',' ' '); do
    [ -n "$cidr" ] && echo "$cidr" >> "$PROXY_ZONE"
  done
  for host in $(echo "$PROXY_HOSTS" | tr ',' ' '); do
    [ -z "$host" ] && continue
    ip=$(dig +short "$host" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 20 || true)
    if [ -z "$ip" ]; then
      warn "无法解析代理域名: $host（请确认 DNS 可用或改用 PROXY_CIDRS）"
    else
      echo "$ip" >> "$PROXY_ZONE"
    fi
  done
  sort -u "$PROXY_ZONE" -o "$PROXY_ZONE" 2>/dev/null || true
  echo "    代理放行 $(wc -l < "$PROXY_ZONE" | tr -d ' ') 条"
}

generate_anchor() {
  local f="$ANCHOR_FILE"
  {
    echo "# ===== china-only anchor (generated $(date '+%F %T')) ====="
    echo "table <china> persist file \"$CHINA_ZONE\""
    echo "table <proxy> persist file \"$PROXY_ZONE\""
    echo "table <lan> const { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 }"
    echo
    echo "pass out quick on lo0"
    echo
    echo "# 直连：中国 IP"
    echo "pass out quick inet to <china>"
    echo "# 直连：内网 / 链路本地 / 组播"
    echo "pass out quick inet to <lan>"
    echo
    echo "# 代理放行（代理服务器地址）"
    echo "pass out quick inet to <proxy>"
    if [ -n "$PROXY_UIDS" ]; then
      echo "# 代理放行（按用户 UID，实验性）"
      echo "pass out quick inet user { $PROXY_UIDS }"
    fi
    echo
    if [ "$ALLOW_FOREIGN_DNS" = "1" ]; then
      echo "# DNS 放行（允许访问任意 DNS 服务器，避免解析失败）"
      echo "pass out quick inet to any port 53"
      echo "pass out quick inet6 to any port 53"
    fi
    echo
    echo "# IPv6"
    echo "pass out quick inet6 to ::1/128"
    echo "pass out quick inet6 to fe80::/10"
    if [ -n "$CHINA6_ZONE" ] && [ -f "$CHINA6_ZONE" ]; then
      echo "table <china6> persist file \"$CHINA6_ZONE\""
      echo "pass out quick inet6 to <china6>"
    fi
    if [ "$BLOCK_IPV6" = "1" ]; then
      echo "block drop out quick inet6"
    fi
    echo
    echo "# 默认：禁止一切其余出站（即国外 IP）"
    echo "block drop out quick inet"
  } > "$f"
}

pf_is_enabled() {
  pfctl -s info 2>/dev/null | grep -qi "Status: Enabled"
}

ensure_pf_enabled() {
  if ! pf_is_enabled; then
    echo "    PF 未启用，正在启用…"
    pfctl -e
  fi
}

remove_from_pfconf() {
  awk -v b="$CHINA_ONLY_BEGIN" -v e="$CHINA_ONLY_END" '
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    !skip {print}
  ' "$PF_CONF" > "$PF_CONF.tmp" && mv "$PF_CONF.tmp" "$PF_CONF"
}

validate() {
  if ! pfctl -nf "$PF_CONF" 2>/tmp/china-only.pfcheck; then
    cat /tmp/china-only.pfcheck >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
cmd_install() {
  log "创建目录"
  mkdir -p "$INSTALL_DIR" /etc/pf.anchors

  log "初始化配置（如不存在）"
  if [ ! -f "$CONF_FILE" ]; then write_default_conf; fi
  load_config

  log "下载中国 IP 库"
  download_china_zone

  log "解析代理地址"
  resolve_proxy

  log "生成 PF 规则"
  generate_anchor

  log "注入 pf.conf"
  if ! grep -q '^anchor "china-only"$' "$PF_CONF" 2>/dev/null; then
    [ -f "$PF_CONF_BAK" ] || cp "$PF_CONF" "$PF_CONF_BAK"
    printf '\n%s\nanchor "china-only"\nload anchor "china-only" from "%s"\n%s\n' \
      "$CHINA_ONLY_BEGIN" "$ANCHOR_FILE" "$CHINA_ONLY_END" >> "$PF_CONF"
  else
    echo "    pf.conf 已包含 china-only，跳过注入"
  fi

  log "校验规则"
  if ! validate; then
    warn "规则校验失败，回滚 pf.conf"
    [ -f "$PF_CONF_BAK" ] && cp "$PF_CONF_BAK" "$PF_CONF"
    exit 1
  fi

  log "记录 PF 状态并启用"
  if pf_is_enabled; then echo enabled > "$STATE_FILE"; else echo disabled > "$STATE_FILE"; fi
  ensure_pf_enabled

  log "加载规则"
  pfctl -f "$PF_CONF"

  log "安装命令链接"
  chmod +x "$SCRIPT_PATH"
  ln -sf "$SCRIPT_PATH" "$BIN_LINK"

  log "完成"
  cmd_status
}

cmd_uninstall() {
  local purge=0
  [ "${1:-}" = "--purge" ] && purge=1

  log "从 pf.conf 移除注入"
  if grep -q '^anchor "china-only"$' "$PF_CONF" 2>/dev/null; then
    remove_from_pfconf
    echo "    已移除"
  else
    echo "    pf.conf 未注入，跳过"
  fi

  log "重新加载 pf.conf"
  if pf_is_enabled; then
    if validate; then pfctl -f "$PF_CONF"; fi
  fi

  log "恢复 PF 开关状态"
  if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "disabled" ]; then
    pfctl -d && echo "    已恢复为关闭 PF"
  fi

  log "删除规则与状态文件"
  rm -f "$ANCHOR_FILE" "$STATE_FILE" /tmp/china-only.pfcheck "$BIN_LINK"

  if [ "$purge" = "1" ]; then
    rm -rf "$INSTALL_DIR"
    echo "    已删除安装目录 $INSTALL_DIR"
  else
    echo "    保留安装目录 $INSTALL_DIR（IP 库与配置）；彻底删除请用: sudo china-only uninstall --purge"
  fi
  log "卸载完成"
}

cmd_update() {
  load_config
  log "更新中国 IP 库"
  download_china_zone
  log "重新加载"
  cmd_reload
}

cmd_reload() {
  load_config
  log "解析代理地址"
  resolve_proxy
  log "生成规则"
  generate_anchor
  log "校验并加载"
  if ! validate; then exit 1; fi
  ensure_pf_enabled
  pfctl -f "$PF_CONF"
  log "规则已加载"
}

cmd_enable() {
  [ -f "$ANCHOR_FILE" ] || die "尚未安装，请先: china-only install"
  load_config
  resolve_proxy
  generate_anchor
  ensure_pf_enabled
  pfctl -a china-only -f "$ANCHOR_FILE"
  log "已重新启用 china-only 规则"
}

cmd_disable() {
  [ -f "$ANCHOR_FILE" ] || die "尚未安装"
  ensure_pf_enabled
  pfctl -a china-only -F all 2>/dev/null || true
  log "已临时关闭 china-only 规则（安装保留，可用 enable 恢复）"
}

cmd_set() {
  local key="${1:-}" value="${2:-}"
  [ -n "$key" ] || { usage; exit 1; }
  key=$(echo "$key" | tr '[:lower:]' '[:upper:]')
  mkdir -p "$INSTALL_DIR"
  touch "$CONF_FILE"
  if grep -q "^$key=" "$CONF_FILE" 2>/dev/null; then
    sed -i '' "s|^$key=.*|$key=$value|" "$CONF_FILE"
  else
    echo "$key=$value" >> "$CONF_FILE"
  fi
  echo "已设置 $key=$value"
  cmd_reload
}

cmd_set_china_dns() {
  local svc
  for svc in $(networksetup -listallnetworkservices 2>/dev/null | tail -n +2); do
    networksetup -setdnsservers "$svc" 223.5.5.5 119.29.29.29 2>/dev/null || true
  done
  log "已将所有网络服务 DNS 设为 223.5.5.5 / 119.29.29.29"
  echo "如需恢复自动获取：系统设置 > 网络 > 对应服务 > 详情 > DNS > 改回自动"
}

cmd_status() {
  echo "china-only 版本 : $VERSION"
  echo "安装目录        : $INSTALL_DIR"
  echo "pf 状态         : $(pfctl -s info 2>/dev/null | grep -i '^Status' || echo '未知(可能需 sudo)')"
  [ -f "$ANCHOR_FILE" ] && echo "规则文件        : 存在" || echo "规则文件        : 不存在"
  grep -q '^anchor "china-only"$' "$PF_CONF" 2>/dev/null && echo "pf.conf 注入    : 已注入" || echo "pf.conf 注入    : 未注入"
  [ -f "$CHINA_ZONE" ] && echo "中国IP条数      : $(wc -l < "$CHINA_ZONE" | tr -d ' ')" || echo "中国IP库        : 未下载"
  [ -f "$PROXY_ZONE" ] && echo "代理放行条数    : $(wc -l < "$PROXY_ZONE" | tr -d ' ')" || echo "代理放行        : 无"
  echo "当前配置:"
  [ -f "$CONF_FILE" ] && sed 's/^/    /' "$CONF_FILE" || echo "    (未创建)"
}

# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-}"
  case "$cmd" in
    install|uninstall|update|reload|enable|disable|set|set-china-dns)
      require_root "$@"
      ;;
  esac

  case "$cmd" in
    install)      cmd_install ;;
    uninstall)    cmd_uninstall "${2:-}" ;;
    update)       cmd_update ;;
    reload)       cmd_reload ;;
    enable)       cmd_enable ;;
    disable)      cmd_disable ;;
    set)          cmd_set "${2:-}" "${3:-}" ;;
    set-china-dns) cmd_set_china_dns ;;
    status)       cmd_status ;;
    version)      echo "china-only $VERSION" ;;
    help|-h|--help|"") usage ;;
    *)            echo "未知命令: $cmd"; echo; usage; exit 1 ;;
  esac
}

main "$@"
