#!/bin/bash

# ==============================================================
#        Xray 一键管理脚本 v 0.1.0 Doudou Zhang 2026-04-13
# ==============================================================

set -u
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

BRAND_HEADER="Designed by Doudou Zhang"
AUTHOR_NAME="Doudou Zhang"
SCRIPT_VERSION="v 0.1.0"
UI_WIDTH=60
DATA_DIR="/usr/local/share/doudou-xray"
SELF_DIR="/usr/local/lib/doudou"
SELF_SCRIPT_PATH="${SELF_DIR}/xray_manager.sh"
QUICK_BIN="/usr/local/bin/zdd"
LEGACY_QUICK_BIN="/usr/local/bin/doudou"
INFO_FILE="${DATA_DIR}/xray_node_info.txt"
SUB_FILE="${DATA_DIR}/xray_subscription.txt"
CONFIG_FILE="/usr/local/etc/xray/config.json"
CONFIG_DIR="/usr/local/etc/xray"
SNI_POOL_FILE="${DATA_DIR}/.xray_sni_pool"
SYSCTL_BBR_FILE="/etc/sysctl.d/99-bbr.conf"
XHTTP_PATCH_DIR="${DATA_DIR}/xhttp_patches"
DEFAULT_PORT=443
TMP_FILES=()
BEST_DEST=""
BEST_DEST_POOL_SIG=""
SNI_POOL_SOURCE="default"
QUICK_INSTALL=0
QUICK_UNINSTALL=0
QUICK_FORCE=0
QUICK_SCENARIO=""
SERVICE_KIND_FILE="${DATA_DIR}/.install_kind"
ALPINE_SS_CONFIG_DIR="/etc/shadowsocks-rust"
ALPINE_SS_CONFIG_FILE="${ALPINE_SS_CONFIG_DIR}/ssserver.json"
ALPINE_SS_SERVICE_FILE="/etc/init.d/ssserver"
ALPINE_RESOLV_BACKUP="${DATA_DIR}/alpine_resolv.conf.bak"

DEFAULT_DEST_OPTIONS=(
    "a0.awsstatic.com"
    "d1.awsstatic.com"
    "s0.awsstatic.com"
    "t0.m.awsstatic.com"
    "prod.pa.cdn.uis.awsstatic.com"
    "ds-aksb-a.akamaihd.net"
    "static.cloud.coveo.com"
    "download-installer.cdn.mozilla.net"
    "gray.video-player.arcpublishing.com"
    "gray-wowt-prod.gtv-cdn.com"
    "cdn77.api.userway.org"
    "services.digitaleast.mobi"
)

function line() {
    local linebuf
    printf -v linebuf '%*s' "$UI_WIDTH" ''
    echo -e "${GREEN}${linebuf// /=}${NC}"
}

function center_text() {
    local text="$1"
    local width="${2:-$UI_WIDTH}"
    local len=${#text}
    local pad=0

    if (( len >= width )); then
        printf '%s
' "$text"
        return 0
    fi

    pad=$(((width - len) / 2))
    printf '%*s%s
' "$pad" '' "$text"
}

function center_echo() {
    local text="$1"
    local color="${2:-}"
    if [[ -n "$color" ]]; then
        printf '%b' "$color"
        center_text "$text"
        printf '%b' "$NC"
    else
        center_text "$text"
    fi
}

function clear_screen() {
    if [[ -t 1 ]]; then
        clear 2>/dev/null || printf 'c'
    fi
}

function read() {
    if builtin read "$@"; then
        return 0
    fi

    local last_arg=""
    local arg=""
    for arg in "$@"; do
        last_arg="$arg"
    done

    if [[ -n "$last_arg" && "$last_arg" != -* && "$last_arg" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        printf -v "$last_arg" '%s' ""
    fi
    return 1
}

function add_tmp_file() {
    local f="$1"
    [[ -n "$f" ]] && TMP_FILES+=("$f")
}

function cleanup_tmp_files() {
    local f
    for f in "${TMP_FILES[@]}"; do
        [[ -n "$f" && -e "$f" ]] && rm -f -- "$f"
    done
    TMP_FILES=()
}

function _cleanup_on_interrupt() {
    echo -e "\n${RED}>>> 脚本被中断，正在清理临时文件...${NC}"
    cleanup_tmp_files
    echo -e "${YELLOW}  已清理临时文件，未改动当前运行中的 xray 服务。${NC}"
    exit 1
}
trap '_cleanup_on_interrupt' INT TERM
trap 'cleanup_tmp_files' EXIT

function resolve_self_source_path() {
    if [[ -n "${BASH_SOURCE[0]:-}" && -r "${BASH_SOURCE[0]}" ]]; then
        printf '%s\n' "${BASH_SOURCE[0]}"
        return 0
    fi

    if [[ -r "/proc/$$/fd/255" ]]; then
        printf '/proc/%s/fd/255\n' "$$"
        return 0
    fi

    if [[ -r "$0" ]]; then
        printf '%s\n' "$0"
        return 0
    fi

    return 1
}

function materialize_self_source() {
    local source_path="$1"
    local target_path="$2"

    cp -f -- "$source_path" "$target_path" 2>/dev/null && return 0
    cat -- "$source_path" > "$target_path" 2>/dev/null && return 0
    return 1
}

function reexec_with_root() {
    if [[ $EUID -eq 0 ]]; then
        if [[ -n "${DOUDOU_ENTRY_TEMP:-}" && -f "${DOUDOU_ENTRY_TEMP}" ]]; then
            rm -f -- "${DOUDOU_ENTRY_TEMP}" >/dev/null 2>&1 || true
        fi
        return 0
    fi

    local self_path
    local temp_self

    if ! self_path=$(resolve_self_source_path); then
        echo -e "${RED}错误：无法解析当前脚本来源，请改用本地文件执行，或使用 bash <(curl -fsSL URL) 这种方式运行。${NC}"
        exit 1
    fi

    temp_self=$(mktemp /tmp/doudou-entry.XXXXXX.sh) || {
        echo -e "${RED}错误：无法创建临时入口脚本。${NC}"
        exit 1
    }

    if ! materialize_self_source "$self_path" "$temp_self"; then
        rm -f -- "$temp_self" >/dev/null 2>&1 || true
        echo -e "${RED}错误：无法准备提权所需的临时入口脚本。${NC}"
        exit 1
    fi
    chmod 700 "$temp_self" >/dev/null 2>&1 || true

    if command -v sudo >/dev/null 2>&1; then
        echo -e "${YELLOW}检测到当前非 root，正在尝试 sudo 提权重新执行...${NC}"
        exec env DOUDOU_ENTRY_TEMP="$temp_self" sudo -E bash "$temp_self" "$@"
    fi

    if command -v su >/dev/null 2>&1; then
        local cmd
        cmd="DOUDOU_ENTRY_TEMP=$(printf '%q' "$temp_self") bash $(printf '%q' "$temp_self")"
        local arg
        for arg in "$@"; do
            cmd+=" $(printf '%q' "$arg")"
        done
        echo -e "${YELLOW}检测到当前非 root，正在尝试 su 提权重新执行...${NC}"
        exec su -c "$cmd"
    fi

    rm -f -- "$temp_self" >/dev/null 2>&1 || true
    echo -e "${RED}错误：当前不是 root，且系统未检测到 sudo/su，无法自动提权。${NC}"
    exit 1
}

function ensure_runtime_layout() {
    mkdir -p "$DATA_DIR" "$SELF_DIR"
    chmod 700 "$DATA_DIR" >/dev/null 2>&1 || true
    chmod 755 "$SELF_DIR" >/dev/null 2>&1 || true
}

function install_quick_launcher() {
    local current_path
    current_path=$(resolve_self_source_path 2>/dev/null || true)

    ensure_runtime_layout

    if [[ -n "$current_path" ]]; then
        if [[ "$current_path" != "$SELF_SCRIPT_PATH" ]]; then
            materialize_self_source "$current_path" "$SELF_SCRIPT_PATH" || return 1
        fi
        chmod 755 "$SELF_SCRIPT_PATH" >/dev/null 2>&1 || true
    fi

    rm -f -- "$LEGACY_QUICK_BIN" >/dev/null 2>&1 || true

    cat > "$QUICK_BIN" <<EOF
#!/bin/bash
set -u

case "\${1:-}" in
    xray)
        shift
        exec "$SELF_SCRIPT_PATH" "\$@"
        ;;
    install)
        shift
        exec "$SELF_SCRIPT_PATH" --quick-install --quick-scenario 4 "\$@"
        ;;
    uninstall|uninstall)
        shift
        exec "$SELF_SCRIPT_PATH" --quick-uninstall "\$@"
        ;;
    *)
        echo "用法: zdd xray | zdd install | zdd uninstall"
        exit 1
        ;;
esac
EOF
    chmod 755 "$QUICK_BIN" >/dev/null 2>&1 || true
}

reexec_with_root "$@"
ensure_runtime_layout
install_quick_launcher >/dev/null 2>&1 || true

function parse_cli_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick-install)
                QUICK_INSTALL=1
                shift
                ;;
            --quick-uninstall)
                QUICK_UNINSTALL=1
                shift
                ;;
            --quick-scenario)
                shift
                if [[ $# -eq 0 ]]; then
                    echo -e "${RED}错误：--quick-scenario 需要一个安装模板编号${NC}" >&2
                    exit 1
                fi
                QUICK_SCENARIO="$1"
                shift
                ;;
            --force)
                QUICK_FORCE=1
                shift
                ;;
            *)
                echo -e "${RED}错误：未知参数 $1${NC}" >&2
                exit 1
                ;;
        esac
    done
}

parse_cli_args "$@"

function get_os_id() {
    if [[ -r /etc/os-release ]]; then
        awk -F= '/^ID=/{gsub(/"/, "", $2); print tolower($2); exit}' /etc/os-release
        return 0
    fi
    return 1
}

function is_alpine_system() {
    local os_id=""
    os_id=$(get_os_id 2>/dev/null || true)
    [[ "$os_id" == "alpine" ]] && return 0
    command -v apk >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1
}

function write_install_runtime_kind() {
    local kind="$1"
    (
        umask 077
        printf '%s\n' "$kind" > "$SERVICE_KIND_FILE"
    )
}

function get_install_runtime_kind() {
    if [[ -f "$SERVICE_KIND_FILE" ]]; then
        head -n 1 "$SERVICE_KIND_FILE" 2>/dev/null || true
        return 0
    fi

    if is_alpine_system && [[ -f "$ALPINE_SS_CONFIG_FILE" || -x "$ALPINE_SS_SERVICE_FILE" || -x /usr/bin/ssserver ]]; then
        printf '%s\n' 'alpine-ss2022'
        return 0
    fi

    if [[ -f "$CONFIG_FILE" || -x /usr/local/bin/xray ]]; then
        printf '%s\n' 'xray'
        return 0
    fi

    return 1
}

function is_alpine_runtime_present() {
    [[ "$(get_install_runtime_kind 2>/dev/null || true)" == "alpine-ss2022" ]]
}

function ensure_alpine_supported() {
    if ! is_alpine_system; then
        echo -e "${RED}错误：当前系统不是 Alpine / OpenRC，无法执行 Alpine 专用 SS2022 流程。${NC}"
        return 1
    fi
    return 0
}

function should_ignore_timesync_failure() {
    [[ "$QUICK_FORCE" == "1" ]]
}

function is_stdin_interactive() {
    [[ -t 0 ]]
}

function is_quick_install_noninteractive() {
    [[ "$QUICK_INSTALL" == "1" ]] && ! is_stdin_interactive
}

function ensure_systemd_supported() {
    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${RED}错误：当前系统未检测到 systemd / systemctl，本脚本目前仅支持基于 systemd 的系统。${NC}"
        return 1
    fi
    return 0
}

function json_escape() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$1" | jq -R -s -c '.' | sed 's/^"//; s/"$//'
    else
        printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177' | sed 's/\\/\\\\/g; s/"/\\"/g'
    fi
}

function load_sni_pool() {
    DEST_OPTIONS=()
    SNI_POOL_SOURCE="default"

    if [[ -f "$SNI_POOL_FILE" ]]; then
        while IFS= read -r linebuf; do
            linebuf=$(printf '%s' "$linebuf" | tr -d '
')
            [[ -n "$linebuf" ]] && DEST_OPTIONS+=("$linebuf")
        done < "$SNI_POOL_FILE"
        if [[ ${#DEST_OPTIONS[@]} -gt 0 ]]; then
            SNI_POOL_SOURCE="file"
        fi
    fi

    if [[ ${#DEST_OPTIONS[@]} -eq 0 ]]; then
        DEST_OPTIONS=("${DEFAULT_DEST_OPTIONS[@]}")
        SNI_POOL_SOURCE="default"
    fi
}

function show_sni_pool_source() {
    if [[ "$SNI_POOL_SOURCE" == "file" ]]; then
        echo -e "${CYAN}  当前实际读取: ${SNI_POOL_FILE}${NC}"
    else
        if [[ -f "$SNI_POOL_FILE" ]]; then
            echo -e "${YELLOW}  当前实际读取: 内置默认候选池（检测到 ${SNI_POOL_FILE}，但内容为空或无有效域名）${NC}"
        else
            echo -e "${CYAN}  当前实际读取: 内置默认候选池（当前未检测到 ${SNI_POOL_FILE}）${NC}"
        fi
    fi
}

function save_sni_pool() {
    (
        umask 077
        printf '%s\n' "${DEST_OPTIONS[@]}" > "$SNI_POOL_FILE"
    )
    BEST_DEST=""
    BEST_DEST_POOL_SIG=""
}

function is_port_in_use_by_non_xray() {
    local port="$1"
    ss -ltnupH 2>/dev/null | awk -v port="$port" '
        $5 ~ ("(^|:|\\])" port "$") {
            if ($0 !~ /users:\(\("xray"/) found=1
        }
        END { exit(found ? 0 : 1) }
    '
}

function generate_short_id() {
    local sid=""
    local i
    for i in {1..60}; do
        sid=$(openssl rand -hex 4 2>/dev/null || true)
        if [[ -n "$sid" && "$sid" =~ [0-9] && "$sid" =~ [a-f] ]]; then
            echo "$sid"
            return 0
        fi
    done

    sid=$(printf 'a%06x1' "$(( (($(date +%s 2>/dev/null || echo 0) + $$ + ${RANDOM:-0})) & 0xFFFFFF ))")
    echo "$sid"
    return 0
}

function ask_yes_no() {
    local prompt="$1"
    local answer=""
    while true; do
        if ! read -r -p "$prompt [y/n]: " answer; then
            echo ""
            if should_ignore_timesync_failure; then
                echo -e "${YELLOW}  检测到非交互输入 / EOF，force 模式下按 y 处理。${NC}"
                return 0
            fi
            echo -e "${YELLOW}  检测到非交互输入 / EOF，按 n 处理。${NC}"
            return 1
        fi
        case "$answer" in
            [yY])
                return 0
                ;;
            [nN])
                return 1
                ;;
            *)
                echo -e "${RED}  请输入 y 或 n。${NC}"
                ;;
        esac
    done
}

function choose_freedom_domain_strategy() {
    local ds_choice
    while true; do
        echo -e "  ${CYAN}1.${NC} IPv4 优先（UseIPv4）" >&2
        echo -e "  ${CYAN}2.${NC} 仅 IPv4（ForceIPv4）" >&2
        read -r -p "选择 [1-2]，默认 1（1=IPv4 优先 / 2=仅 IPv4）: " ds_choice
        case "${ds_choice:-1}" in
            1|01)
                echo "UseIPv4"
                return 0
                ;;
            2|02)
                echo "ForceIPv4"
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1 或 2。${NC}" >&2
                ;;
        esac
    done
}

function read_manual_sni() {
    local prompt="$1"
    local value
    while true; do
        read -r -p "$prompt" value
        value=$(echo "$value" | tr -d '[:space:]')
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        fi
        echo -e "${RED}  SNI 不能为空。${NC}" >&2
    done
}

function read_manual_ss_port() {
    local prompt="$1"
    local port
    while true; do
        read -r -p "$prompt" port
        if ! [[ "$port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}  端口必须是数字。${NC}" >&2
            continue
        fi
        if [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
            echo -e "${RED}  端口范围必须在 1-65535。${NC}" >&2
            continue
        fi
        echo "$port"
        return 0
    done
}

function choose_reality_port() {
    local choice
    while true; do
        echo -e "  ${CYAN}1.${NC} 443（默认）" >&2
        echo -e "  ${CYAN}2.${NC} 8443" >&2
        read -r -p "选择 Reality 端口 [1-2]，默认 1: " choice
        case "${choice:-1}" in
            1|01)
                echo "443"
                return 0
                ;;
            2|02)
                echo "8443"
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1 或 2。${NC}" >&2
                ;;
        esac
    done
}

function choose_ss_method() {
    local choice
    while true; do
        echo -e "  ${CYAN}1.${NC} 2022-blake3-aes-128-gcm（默认）" >&2
        echo -e "  ${CYAN}2.${NC} 2022-blake3-aes-256-gcm" >&2
        read -r -p "选择 SS2022 加密方式 [1-2]，默认 1: " choice
        case "${choice:-1}" in
            1|01)
                echo "2022-blake3-aes-128-gcm"
                return 0
                ;;
            2|02)
                echo "2022-blake3-aes-256-gcm"
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1 或 2。${NC}" >&2
                ;;
        esac
    done
}

function choose_reality_landing_count() {
    local choice
    while true; do
        echo -e "  ${CYAN}1.${NC} 纯直出（不增加落地）" >&2
        echo -e "  ${CYAN}2.${NC} 1 个落地出口（直出 + 1 落地）" >&2
        echo -e "  ${CYAN}3.${NC} 2 个落地出口（直出 + 2 落地）" >&2
        echo -e "  ${CYAN}4.${NC} 3 个落地出口（直出 + 3 落地）" >&2
        read -r -p "选择 Reality 落地数量 [1-4]，默认 1: " choice
        case "${choice:-1}" in
            1|01)
                printf '%s' "0"
                return 0
                ;;
            2|02)
                printf '%s' "1"
                return 0
                ;;
            3|03)
                printf '%s' "2"
                return 0
                ;;
            4|04)
                printf '%s' "3"
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1-4。${NC}" >&2
                ;;
        esac
    done
}

function choose_vlessenc_padding_profile() {
    local choice
    while true; do
        echo -e "  ${CYAN}1.${NC} 默认（核心自动 padding / delay）" >&2
        echo -e "  ${CYAN}2.${NC} 温和（轻微增加长度与节奏扰动）" >&2
        echo -e "  ${CYAN}3.${NC} 激进（更明显的实验性 padding / delay）" >&2
        echo -e "  ${CYAN}4.${NC} 手动自定义（客户端 / 服务端分别输入）" >&2
        read -r -p "选择实验性 padding / delay 档位 [1-4]，默认 1: " choice
        case "${choice:-1}" in
            1|01)
                printf '%s' "off"
                return 0
                ;;
            2|02)
                printf '%s' "gentle"
                return 0
                ;;
            3|03)
                printf '%s' "aggressive"
                return 0
                ;;
            4|04)
                printf '%s' "custom"
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1-4。${NC}" >&2
                ;;
        esac
    done
}

function get_vlessenc_padding_profile_desc() {
    case "$1" in
        off) printf '%s' '默认（核心自动 padding / delay）' ;;
        gentle) printf '%s' '温和（客户端 / 服务端使用不同轻量规则）' ;;
        aggressive) printf '%s' '激进（客户端 / 服务端使用不同重规则）' ;;
        custom) printf '%s' '手动自定义（客户端 / 服务端分别输入）' ;;
        *) printf '%s' '默认（核心自动 padding / delay）' ;;
    esac
}

function get_vlessenc_padding_profile_for_side() {
    local profile="$1"
    local side="$2"
    case "${profile}:${side}" in
        off:*) printf '%s' '' ;;
        gentle:client) printf '%s' '100-96-768.60-0-80.40-0-1600' ;;
        gentle:server) printf '%s' '100-128-1024.70-0-96.45-0-2048' ;;
        aggressive:client) printf '%s' '100-128-1024.75-0-96.55-0-2400.35-24-320' ;;
        aggressive:server) printf '%s' '100-160-1536.80-0-128.60-0-3200.40-32-480' ;;
        custom:*) printf '%s' '' ;;
        *) printf '%s' '' ;;
    esac
}

function validate_vlessenc_padding_profile() {
    local profile="$1"
    local -a segments=()
    local seg prob min max idx

    [[ -n "$profile" ]] || return 1
    [[ "$profile" != *[[:space:]]* ]] || return 1
    IFS='.' read -r -a segments <<< "$profile"
    [[ ${#segments[@]} -ge 1 ]] || return 1

    for idx in "${!segments[@]}"; do
        seg="${segments[$idx]}"
        [[ "$seg" =~ ^([0-9]{1,3})-([0-9]+)-([0-9]+)$ ]] || return 1
        prob="${BASH_REMATCH[1]}"
        min="${BASH_REMATCH[2]}"
        max="${BASH_REMATCH[3]}"
        (( prob >= 0 && prob <= 100 )) || return 1
        (( max >= min )) || return 1
        if (( idx == 0 )); then
            (( prob == 100 )) || return 1
            (( min >= 35 )) || return 1
        fi
    done
    return 0
}

function read_manual_vlessenc_padding_profile() {
    local side_label="$1"
    local value
    while true; do
        echo -e "${CYAN}  请输入 ${side_label}规则，格式示例：100-96-768.60-0-80.40-0-1600${NC}" >&2
        echo -e "${CYAN}  规范：使用 padding.delay.padding(.delay.padding)... 这种链式格式。${NC}" >&2
        echo -e "${CYAN}  每段格式：概率-最小值-最大值，示例给了三段${NC}" >&2
        echo -e "${CYAN}  规则 1：第一段必须是 padding，不是 delay。${NC}" >&2
        echo -e "${CYAN}  规则 2：第一段概率必须为 100。${NC}" >&2
        echo -e "${CYAN}  规则 3：第一段最小长度（示例中为96）必须 >= 35，否则 Xray 会直接报错。${NC}" >&2
        echo -e "${CYAN}  规则 4：每段都必须满足 最大值 >= 最小值。${NC}" >&2
        echo -e "${CYAN}  说明：首段中的两个数字表示 padding 长度范围；delay 段中的两个数字表示等待时间范围（毫秒）。${NC}" >&2
        read -r -p "请输入 ${side_label} padding / delay: " value
        value=$(printf '%s' "$value" | tr -d '[:space:]')
        if validate_vlessenc_padding_profile "$value"; then
            printf '%s' "$value"
            return 0
        fi
        echo -e "${RED}  格式不符合规范：请确认首段为 100-最小长度-最大长度，且第一段最小长度必须 >= 35。${NC}" >&2
    done
}

function rewrite_vlessenc_padding_profile() {
    local value="$1"
    local padding_profile="$2"
    local -a parts=()
    local block1 old2 old3 auth

    [[ -n "$padding_profile" ]] || {
        printf '%s' "$value"
        return 0
    }

    validate_vlessenc_padding_profile "$padding_profile" || return 1
    IFS='.' read -r -a parts <<< "$value"
    [[ ${#parts[@]} -ge 4 ]] || return 1

    block1="${parts[0]}"
    old2="${parts[1]}"
    old3="${parts[2]}"
    auth="${parts[$((${#parts[@]} - 1))]}"
    [[ -n "$block1" && -n "$old2" && -n "$old3" && -n "$auth" ]] || return 1

    printf '%s.%s.%s.%s.%s' "$block1" "$old2" "$old3" "$padding_profile" "$auth"
}

function choose_vlessenc_rtt_mode() {
    local choice
    while true; do
        echo -e "  ${CYAN}1.${NC} 0rtt（更偏性能 / 重连更快）" >&2
        echo -e "  ${CYAN}2.${NC} 1rtt（强制完整握手 / 更偏保守）" >&2
        read -r -p "选择 [1-2]，默认 1: " choice
        case "${choice:-1}" in
            1|01)
                echo "0rtt"
                return 0
                ;;
            2|02)
                echo "1rtt"
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1 或 2。${NC}" >&2
                ;;
        esac
    done
}

function choose_vlessenc_shape_mode() {
    local choice
    while true; do
        echo -e "  ${CYAN}1.${NC} xorpub（推荐：原始格式 + 公钥部分混淆）" >&2
        echo -e "  ${CYAN}2.${NC} native（原始格式）" >&2
        echo -e "  ${CYAN}3.${NC} random（更随机化的表现形式）" >&2
        read -r -p "选择 [1-3]，默认 1: " choice
        case "${choice:-1}" in
            1|01)
                echo "xorpub"
                return 0
                ;;
            2|02)
                echo "native"
                return 0
                ;;
            3|03)
                echo "random"
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1、2 或 3。${NC}" >&2
                ;;
        esac
    done
}

function choose_vlessenc_auth_method() {
    local choice
    while true; do
        echo -e "  ${CYAN}1.${NC} x25519（更短；认证不抗量子）" >&2
        echo -e "  ${CYAN}2.${NC} mlkem768（更长；认证也抗量子）" >&2
        read -r -p "选择 [1-2]，默认 1: " choice
        case "${choice:-1}" in
            1|01)
                echo "x25519"
                return 0
                ;;
            2|02)
                echo "mlkem768"
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1 或 2。${NC}" >&2
                ;;
        esac
    done
}

function url_encode() {
    local value="$1"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$value" | jq -sRr @uri
    else
        printf '%s' "$value"
    fi
}

function rewrite_vlessenc_block2_block3() {
    local value="$1"
    local block2="$2"
    local block3="$3"
    local block1 old2 old3 rest

    IFS='.' read -r block1 old2 old3 rest <<< "$value"
    if [[ -z "$block1" || -z "$rest" ]]; then
        return 1
    fi

    printf '%s.%s.%s.%s' "$block1" "$block2" "$block3" "$rest"
}

function get_vlessenc_pair_from_xray() {
    local auth_method="$1"
    local raw=""
    local want=""
    local decryption=""
    local encryption=""

    raw=$(/usr/local/bin/xray vlessenc 2>/dev/null || true)
    [[ -n "$raw" ]] || return 1

    if [[ "$auth_method" == "x25519" ]]; then
        want="Authentication: X25519"
    else
        want="Authentication: ML-KEM-768"
    fi

    decryption=$(printf '%s
' "$raw" | awk -v want="$want" '
        index($0, want) { found=1; next }
        found && /"decryption":/ {
            sub(/.*"decryption":[[:space:]]*"/, "")
            sub(/".*/, "")
            print $0
            exit
        }
    ')

    encryption=$(printf '%s
' "$raw" | awk -v want="$want" '
        index($0, want) { found=1; next }
        found && /"encryption":/ {
            sub(/.*"encryption":[[:space:]]*"/, "")
            sub(/".*/, "")
            print $0
            exit
        }
    ')

    [[ -n "$decryption" && -n "$encryption" ]] || return 1
    printf '%s	%s
' "$decryption" "$encryption"
}

function extract_x25519_private() {
    awk '/PrivateKey:|Private key:/{print $NF; exit}'
}

function extract_x25519_public() {
    awk '/Password \(PublicKey\):|Password:|Public key:/{print $NF; exit}'
}

function extract_mlkem_seed() {
    awk '/Seed:/{print $NF; exit}'
}

function extract_mlkem_client() {
    awk '/Client:/{print $NF; exit}'
}

function pick_random_free_port_excluding() {
    local exclude_a="${1:-0}"
    local exclude_b="${2:-0}"
    local exclude_c="${3:-0}"
    local port=""
    local i
    for i in {1..60}; do
        port=$(shuf -i 40000-65000 -n 1)
        if [[ "$port" == "$exclude_a" || "$port" == "$exclude_b" || "$port" == "$exclude_c" ]]; then
            continue
        fi
        if ! is_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done
    return 1
}

function install_deps() {
    echo -e "${YELLOW}  安装依赖组件...${NC}"

    if command -v apt-get &>/dev/null; then
        if command -v fuser >/dev/null 2>&1; then
            local lock_waited=0
            while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
                  fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
                  fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
                  fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
                if [[ $lock_waited -eq 0 ]]; then
                    echo -e "${YELLOW}  等待 dpkg/apt 锁释放（后台可能有自动更新在运行）...${NC}"
                fi
                lock_waited=$((lock_waited + 1))
                sleep 3
            done
        fi
        apt-get update -y || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget jq openssl coreutils procps psmisc ca-certificates iproute2 || return 1
    elif command -v dnf &>/dev/null; then
        dnf install -y curl wget jq openssl coreutils procps-ng psmisc ca-certificates iproute || return 1
    elif command -v yum &>/dev/null; then
        yum install -y curl wget jq openssl coreutils procps-ng psmisc ca-certificates iproute || return 1
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm curl wget jq openssl coreutils procps-ng psmisc ca-certificates iproute2 || return 1
    else
        echo -e "${RED}未找到受支持的包管理器，请手动安装依赖后重试。${NC}"
        return 1
    fi
}

function try_temporary_timesync() {
    local -a endpoints=(
        "https://www.cloudflare.com"
        "https://www.github.com"
        "https://www.microsoft.com"
    )
    local endpoint=""
    local remote_date=""

    echo -e "${YELLOW}  时间同步服务仍未完成，正在尝试一次性临时校时...${NC}"

    for endpoint in "${endpoints[@]}"; do
        remote_date=""

        if command -v curl &>/dev/null; then
            remote_date=$(curl -fsSI --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^Date:/ {sub(/\r$/, ""); sub(/^Date:[[:space:]]*/, ""); print; exit}')
        elif command -v wget &>/dev/null; then
            remote_date=$(wget -S --spider -T 10 -t 1 "$endpoint" 2>&1 | awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*Date:/ {sub(/\r$/, ""); sub(/^[[:space:]]*Date:[[:space:]]*/, ""); print; exit}')
        fi

        if [[ -n "$remote_date" ]]; then
            if LC_ALL=C date -d '@0' >/dev/null 2>&1; then
                LC_ALL=C date -d "$remote_date" >/dev/null 2>&1 || continue
            fi
            if LC_ALL=C date -u -s "$remote_date" >/dev/null 2>&1; then
                hwclock -w >/dev/null 2>&1 || true
                echo -e "${GREEN}  ✓ 已通过 HTTPS 响应头完成一次性临时校时${NC}"
                echo -e "${CYAN}  参考源: ${endpoint}${NC}"
                return 0
            fi
        fi
    done

    echo -e "${RED}  ✗ 一次性临时校时失败。${NC}"
    return 1
}

function check_timesync() {
    echo -e "${YELLOW}  检查时间同步状态...${NC}"

    local has_timedatectl=0
    local has_chronyc=0

    if command -v timedatectl &>/dev/null; then
        has_timedatectl=1
        local sync_status
        sync_status=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)
        if [[ "$sync_status" == "yes" ]]; then
            echo -e "${GREEN}  ✓ 时间已同步（NTPSynchronized=yes）${NC}"
            return 0
        fi
    fi

    if command -v chronyc &>/dev/null; then
        has_chronyc=1
        local leap_status
        leap_status=$(chronyc tracking 2>/dev/null | awk -F': *' '/^Leap status/ {print $2}' || true)
        if [[ "$leap_status" == "Normal" ]]; then
            echo -e "${GREEN}  ✓ 时间已同步（chrony: Leap status = Normal）${NC}"
            return 0
        fi
    fi

    if [[ $has_timedatectl -eq 0 && $has_chronyc -eq 0 ]]; then
        echo -e "${YELLOW}  未检测到可用的时间同步检查命令，正在尝试安装并启用时间同步服务...${NC}"
    else
        echo -e "${YELLOW}  已检测到时间同步尚未完成，正在尝试补齐并启用时间同步服务...${NC}"
    fi

    if command -v apt-get &>/dev/null; then
        apt-get update -y >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-timesyncd >/dev/null 2>&1 || true
        systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
    elif command -v dnf &>/dev/null; then
        dnf install -y chrony >/dev/null 2>&1 || true
        systemctl enable --now chronyd >/dev/null 2>&1 || true
    elif command -v yum &>/dev/null; then
        yum install -y chrony >/dev/null 2>&1 || true
        systemctl enable --now chronyd >/dev/null 2>&1 || true
    else
        echo -e "${RED}  ✗ 无法自动安装时间同步服务，请手动处理！${NC}"
        return 1
    fi

    echo -e "${YELLOW}  等待时间同步完成（最多约 16 秒）...${NC}"

    local i sync_check
    for i in {1..8}; do
        sleep 2
        if command -v timedatectl &>/dev/null; then
            sync_check=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)
            if [[ "$sync_check" == "yes" ]]; then
                echo -e "${GREEN}  ✓ 时间同步已就绪${NC}"
                return 0
            fi
        fi
        if command -v chronyc &>/dev/null; then
            local leap_status_loop
            leap_status_loop=$(chronyc tracking 2>/dev/null | awk -F': *' '/^Leap status/ {print $2}' || true)
            if [[ "$leap_status_loop" == "Normal" ]]; then
                echo -e "${GREEN}  ✓ 时间同步已就绪${NC}"
                return 0
            fi
        fi
    done

    if try_temporary_timesync; then
        echo -e "${YELLOW}  已完成一次性临时校时，继续安装。后续建议系统自行完成长期同步。${NC}"
        return 0
    fi

    echo -e "${RED}  ✗ 时间同步仍未完成。${NC}"
    return 1
}

function handle_timesync_failure() {
    local warning_msg="$1"
    echo -e "${YELLOW}${warning_msg}${NC}"
    if should_ignore_timesync_failure; then
        echo -e "${YELLOW}  已启用 force 模式：忽略时间同步检查，继续安装。${NC}"
        return 0
    fi
    if ask_yes_no "  是否仍继续安装"; then
        echo -e "${YELLOW}  已选择忽略时间同步检查，继续安装。${NC}"
        return 0
    fi
    echo -e "${RED}  已取消安装。${NC}"
    return 1
}

function check_bbr() {
    echo -e "${YELLOW}  检查 BBR + FQ 状态...${NC}"

    local current_cc current_qdisc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)

    echo -e "  拥塞控制  : ${CYAN}${current_cc:-未知}${NC}"
    echo -e "  队列调度  : ${CYAN}${current_qdisc:-未知}${NC}"

    if ! modprobe tcp_bbr 2>/dev/null && \
       ! grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        echo -e "${RED}  ✗ 当前内核不支持 BBR（内核版本需 ≥ 4.9），跳过。${NC}"
        return 1
    fi

    if [[ "$current_cc" == "bbr" && "$current_qdisc" == "fq" ]]; then
        echo -e "${GREEN}  ✓ BBR + FQ 已启用，无需操作${NC}"
        return 0
    fi

    echo -e "${YELLOW}  BBR 或 FQ 未完全启用，正在写入配置...${NC}"
    cat > "$SYSCTL_BBR_FILE" <<EOF2
# BBR + FQ — 由 Xray 管理脚本自动写入
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF2

    sysctl -p "$SYSCTL_BBR_FILE" >/dev/null 2>&1 || true

    local new_cc new_qdisc
    new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    new_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)

    if [[ "$new_cc" == "bbr" && "$new_qdisc" == "fq" ]]; then
        echo -e "${GREEN}  ✓ BBR + FQ 已成功启用${NC}"
        echo -e "  配置已写入: ${CYAN}${SYSCTL_BBR_FILE}${NC}"
        return 0
    fi

    echo -e "${YELLOW}  ⚠ 已写入配置，但当前未完全生效（cc=${new_cc:-unknown}, qdisc=${new_qdisc:-unknown}）。${NC}"
    return 1
}

function get_alpine_repo_branch() {
    local release_line=""
    release_line=$(cat /etc/alpine-release 2>/dev/null || true)
    if [[ "$release_line" =~ ^([0-9]+)\.([0-9]+) ]]; then
        printf 'v%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi
    printf '%s\n' 'edge'
}

function ensure_alpine_community_repo() {
    local repo_file="/etc/apk/repositories"
    local repo_branch community_line

    [[ -f "$repo_file" ]] || {
        echo -e "${RED}  ✗ 未找到 ${repo_file}${NC}"
        return 1
    }

    if grep -Eq '^[[:space:]]*https?://.*/community([[:space:]]|$)' "$repo_file"; then
        echo -e "${GREEN}  ✓ Alpine community 仓库已启用${NC}"
        return 0
    fi

    repo_branch=$(get_alpine_repo_branch)
    community_line="https://dl-cdn.alpinelinux.org/alpine/${repo_branch}/community"
    echo -e "${YELLOW}  未检测到 community 仓库，正在追加：${community_line}${NC}"
    printf '%s\n' "$community_line" >> "$repo_file" || return 1
    echo -e "${GREEN}  ✓ 已追加 Alpine community 仓库${NC}"
    return 0
}

function choose_alpine_dns_provider() {
    local choice
    while true; do
        echo -e "  ${CYAN}1.${NC} Cloudflare（1.1.1.1 / 1.0.0.1）" >&2
        echo -e "  ${CYAN}2.${NC} Google（8.8.8.8 / 8.8.4.4）" >&2
        read -r -p "选择安装期间使用的系统 DNS [1-2]，默认 1: " choice
        case "${choice:-1}" in
            1|01)
                printf '%s\n' 'cloudflare'
                return 0
                ;;
            2|02)
                printf '%s\n' 'google'
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1 或 2。${NC}" >&2
                ;;
        esac
    done
}

function apply_alpine_dns_provider() {
    local provider="$1"
    local primary secondary label

    case "$provider" in
        cloudflare)
            primary="1.1.1.1"
            secondary="1.0.0.1"
            label="Cloudflare"
            ;;
        google)
            primary="8.8.8.8"
            secondary="8.8.4.4"
            label="Google"
            ;;
        *)
            echo -e "${RED}  ✗ 未知 DNS 选项：${provider}${NC}"
            return 1
            ;;
    esac

    if [[ -f /etc/resolv.conf && ! -f "$ALPINE_RESOLV_BACKUP" ]]; then
        cp -a -- /etc/resolv.conf "$ALPINE_RESOLV_BACKUP" >/dev/null 2>&1 || true
    fi

    cat > /etc/resolv.conf <<DNS_EOF
nameserver ${primary}
nameserver ${secondary}
DNS_EOF

    echo -e "${GREEN}  ✓ 已设置系统 DNS：${label}（${primary} / ${secondary}）${NC}"
}

function install_alpine_runtime_deps() {
    echo -e "${YELLOW}  安装 Alpine 运行依赖...${NC}"
    apk update || return 1
    apk add shadowsocks-rust mimalloc chrony curl wget jq openssl coreutils procps ca-certificates iproute2 || return 1
}

function check_timesync_alpine() {
    echo -e "${YELLOW}  检查 Alpine 时间同步状态...${NC}"

    local leap_status=""
    if command -v chronyc >/dev/null 2>&1; then
        leap_status=$(chronyc tracking 2>/dev/null | awk -F': *' '/^Leap status/ {print $2; exit}' || true)
        if [[ "$leap_status" == "Normal" ]]; then
            echo -e "${GREEN}  ✓ 时间已同步（chrony: Leap status = Normal）${NC}"
            return 0
        fi
    fi

    echo -e "${YELLOW}  正在启用 chronyd 并等待同步...${NC}"
    apk add chrony >/dev/null 2>&1 || true
    rc-update add chronyd default >/dev/null 2>&1 || true
    rc-service chronyd restart >/dev/null 2>&1 || rc-service chronyd start >/dev/null 2>&1 || true

    local i=""
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 2
        if command -v chronyc >/dev/null 2>&1; then
            leap_status=$(chronyc tracking 2>/dev/null | awk -F': *' '/^Leap status/ {print $2; exit}' || true)
            if [[ "$leap_status" == "Normal" ]]; then
                echo -e "${GREEN}  ✓ Alpine 时间同步已就绪${NC}"
                return 0
            fi
        fi
    done

    echo -e "${YELLOW}  chronyd 尚未确认同步，正在尝试一次性临时校时...${NC}"
    if try_temporary_timesync; then
        rc-service chronyd restart >/dev/null 2>&1 || true
        echo -e "${YELLOW}  已通过一次性校时修正当前时间，后续建议继续观察 chronyd 同步状态。${NC}"
        return 0
    fi

    echo -e "${RED}  ✗ Alpine 时间同步仍未完成。${NC}"
    return 1
}

function backup_file_if_exists() {
    local file_path="$1"
    local backup_path=""
    if [[ -f "$file_path" ]]; then
        backup_path="${file_path}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a -- "$file_path" "$backup_path" || return 1
        echo -e "${YELLOW}  已备份旧文件: ${backup_path}${NC}"
    fi
}

function base64_encode_urlsafe_nopad() {
    printf '%s' "$1" | base64 | tr -d '\r\n=' | tr '+/' '-_'
}

function build_ss2022_uri() {
    local host="$1"
    local port="$2"
    local method="$3"
    local password="$4"
    local tag="$5"
    local userinfo uri_host

    userinfo=$(base64_encode_urlsafe_nopad "${method}:${password}")
    uri_host=$(format_host_for_uri "$host")
    printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$uri_host" "$port" "$(url_encode "$tag")"
}

function get_alpine_ss_port_from_config() {
    if [[ -f "$ALPINE_SS_CONFIG_FILE" ]]; then
        if command -v jq >/dev/null 2>&1; then
            jq -r '.server_port // empty' "$ALPINE_SS_CONFIG_FILE" 2>/dev/null || true
        else
            awk -F: '/"server_port"/ {gsub(/[^0-9]/, "", $2); print $2; exit}' "$ALPINE_SS_CONFIG_FILE" 2>/dev/null || true
        fi
    fi
}

function write_alpine_ssserver_config() {
    local port="$1"
    local method="$2"
    local password="$3"

    mkdir -p "$ALPINE_SS_CONFIG_DIR" || return 1
    backup_file_if_exists "$ALPINE_SS_CONFIG_FILE" || return 1
    cat > "$ALPINE_SS_CONFIG_FILE" <<CFG_EOF
{
  "server": "::",
  "server_port": ${port},
  "password": "$(json_escape "$password")",
  "method": "$(json_escape "$method")",
  "mode": "tcp_and_udp",
  "timeout": 300
}
CFG_EOF
}

function write_alpine_openrc_service() {
    backup_file_if_exists "$ALPINE_SS_SERVICE_FILE" || return 1
    cat > "$ALPINE_SS_SERVICE_FILE" <<'SERVICE_EOF'
#!/sbin/openrc-run

name="shadowsocks-rust server"
description="Shadowsocks Rust Server"

command="/usr/bin/ssserver"
command_args="-c /etc/shadowsocks-rust/ssserver.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
}
SERVICE_EOF
    chmod +x "$ALPINE_SS_SERVICE_FILE" >/dev/null 2>&1 || true
}

function validate_alpine_ss_config() {
    if [[ ! -f "$ALPINE_SS_CONFIG_FILE" ]]; then
        echo -e "${RED}  ✗ 未找到配置文件：${ALPINE_SS_CONFIG_FILE}${NC}"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${YELLOW}  ⚠ 未检测到 jq，跳过 JSON 语法校验。${NC}"
        return 0
    fi

    if ! jq empty "$ALPINE_SS_CONFIG_FILE" >/dev/null 2>&1; then
        cp -f -- "$ALPINE_SS_CONFIG_FILE" "${DATA_DIR}/last_failed_ssserver.json" 2>/dev/null || true
        echo -e "${RED}  ✗ SS2022 配置 JSON 语法验证失败。${NC}"
        echo -e "${YELLOW}  已保留失败配置: ${DATA_DIR}/last_failed_ssserver.json${NC}"
        return 1
    fi

    echo -e "${GREEN}  ✓ SS2022 配置 JSON 语法验证通过${NC}"
    return 0
}

function validate_alpine_ssserver_foreground() {
    echo -e "${YELLOW}  正在以前台方式短时验证 ssserver 配置...${NC}"
    validate_alpine_ss_config || return 1

    local fg_log=""
    local fg_ret=0
    fg_log=$(mktemp /tmp/ssserver-foreground.XXXXXX.log) || {
        echo -e "${RED}  ✗ 无法创建前台验证日志文件。${NC}"
        return 1
    }
    add_tmp_file "$fg_log"

    timeout 3 ssserver -c "$ALPINE_SS_CONFIG_FILE" -v >"$fg_log" 2>&1
    fg_ret=$?

    case "$fg_ret" in
        124|137|143)
            echo -e "${GREEN}  ✓ 前台短时验证通过（进程按预期持续运行，已自动结束测试）。${NC}"
            return 0
            ;;
        *)
            cp -f -- "$fg_log" "${DATA_DIR}/last_failed_ssserver_foreground.log" 2>/dev/null || true
            echo -e "${RED}  ✗ 前台验证失败，请先修正后再写入 OpenRC 自启。${NC}"
            if [[ -s "$fg_log" ]]; then
                echo -e "${CYAN}  最近输出:${NC}"
                sed -n '1,20p' "$fg_log"
            fi
            echo -e "${YELLOW}  已保留失败日志: ${DATA_DIR}/last_failed_ssserver_foreground.log${NC}"
            return 1
            ;;
    esac
}

function restart_alpine_ssservice() {
    line
    echo -e "${YELLOW}  重启 Alpine SS2022 服务...${NC}"
    ensure_alpine_supported || return 1
    validate_alpine_ss_config || { line; return 1; }

    if [[ ! -x "$ALPINE_SS_SERVICE_FILE" ]]; then
        echo -e "${RED}  ✗ 未找到 OpenRC 服务文件：${ALPINE_SS_SERVICE_FILE}${NC}"
        line
        return 1
    fi

    rc-service ssserver restart >/dev/null 2>&1 || rc-service ssserver start >/dev/null 2>&1 || {
        echo -e "${RED}  ✗ SS2022 服务启动失败。${NC}"
        line
        return 1
    }

    sleep 2
    if rc-service ssserver status >/dev/null 2>&1; then
        echo -e "${GREEN}  ✓ SS2022 服务已启动${NC}"
    else
        echo -e "${YELLOW}  ⚠ OpenRC 未明确返回运行中，请继续检查监听端口。${NC}"
    fi

    local listen_port=""
    listen_port=$(get_alpine_ss_port_from_config)
    if [[ -n "$listen_port" ]]; then
        if ss -ltnup 2>/dev/null | grep -q ":${listen_port}\b"; then
            echo -e "${GREEN}  ✓ 已检测到 ${listen_port} 端口监听${NC}"
        else
            echo -e "${YELLOW}  ⚠ 未明确检测到 ${listen_port} 端口监听，请手动检查：ss -ltnup | grep :${listen_port}${NC}"
        fi
    fi
    line
}

function update_alpine_ssservice() {
    line
    echo -e "${YELLOW}  更新 Alpine SS2022（shadowsocks-rust）...${NC}"
    ensure_alpine_supported || return 1
    ensure_alpine_community_repo || { line; return 1; }

    apk update || { line; return 1; }
    apk add --upgrade shadowsocks-rust mimalloc chrony curl wget jq openssl coreutils procps ca-certificates iproute2 || {
        echo -e "${RED}  ✗ 更新失败，请检查网络或仓库状态。${NC}"
        line
        return 1
    }

    echo -e "${GREEN}  ✓ shadowsocks-rust 已更新完成${NC}"
    if [[ -f "$ALPINE_SS_CONFIG_FILE" && -x "$ALPINE_SS_SERVICE_FILE" ]]; then
        restart_alpine_ssservice || return 1
        return 0
    fi
    line
}

function show_alpine_ss_status() {
    line
    center_echo "Alpine SS2022 服务状态" "${CYAN}${BOLD}"
    line
    ensure_alpine_supported || return 1

    if [[ -x "$ALPINE_SS_SERVICE_FILE" ]]; then
        rc-service ssserver status || true
    else
        echo -e "${YELLOW}  未找到 OpenRC 服务文件：${ALPINE_SS_SERVICE_FILE}${NC}"
    fi

    echo ""
    local listen_port=""
    listen_port=$(get_alpine_ss_port_from_config)
    if [[ -n "$listen_port" ]]; then
        center_echo "监听检查" "${CYAN}${BOLD}"
        ss -ltnup 2>/dev/null | grep ":${listen_port}\b" || echo -e "${YELLOW}  未检测到 ${listen_port} 端口监听${NC}"
        echo ""
    fi

    center_echo "日志提示" "${CYAN}${BOLD}"
    echo -e "${YELLOW}  OpenRC 默认没有 journalctl 风格统一日志。${NC}"
    echo -e "${CYAN}  如需看启动报错，可执行：${NC}"
    echo -e "${CYAN}    rc-service ssserver restart${NC}"
    echo -e "${CYAN}    ssserver -c ${ALPINE_SS_CONFIG_FILE} -v${NC}"
    line
}

function edit_alpine_ss_config() {
    while true; do
        line
        center_echo "修改配置文件" "${CYAN}${BOLD}"
        line
        echo -e "${CYAN}  路径: ${ALPINE_SS_CONFIG_FILE}${NC}"
        echo -e "${YELLOW}  仅建议熟悉 SS2022 配置者使用。${NC}"
        echo ""
        echo -e "  ${CYAN}1.${NC} 编辑当前配置"
        echo -e "  ${CYAN}2.${NC} 清空配置（高风险）"
        echo -e "  ${CYAN}0.${NC} 返回主菜单"
        line
        read -r -p "选择 [0/1/2]: " EDIT_CHOICE

        if [[ ! -f "$ALPINE_SS_CONFIG_FILE" ]]; then
            echo -e "${RED}  未找到配置文件，请先执行 Alpine SS2022 安装。${NC}"
            line
            return 1
        fi

        case "$EDIT_CHOICE" in
            1|01)
                echo ""
                if [[ -n "${EDITOR:-}" ]] && command -v "${EDITOR}" >/dev/null 2>&1; then
                    "${EDITOR}" "$ALPINE_SS_CONFIG_FILE"
                elif command -v nano >/dev/null 2>&1; then
                    nano "$ALPINE_SS_CONFIG_FILE"
                elif command -v vim >/dev/null 2>&1; then
                    vim "$ALPINE_SS_CONFIG_FILE"
                elif command -v vi >/dev/null 2>&1; then
                    vi "$ALPINE_SS_CONFIG_FILE"
                else
                    echo -e "${RED}  未找到可用编辑器（nano/vim/vi）。${NC}"
                    line
                    return 1
                fi

                echo ""
                if command -v jq >/dev/null 2>&1; then
                    if jq empty "$ALPINE_SS_CONFIG_FILE" >/dev/null 2>&1; then
                        echo -e "${GREEN}  ✓ JSON 语法校验通过。${NC}"
                    else
                        cp -f -- "$ALPINE_SS_CONFIG_FILE" "${DATA_DIR}/last_failed_ssserver.json" 2>/dev/null || true
                        echo -e "${RED}  ✗ 当前文件不是合法 JSON，请修正后再重启服务。${NC}"
                        echo -e "${YELLOW}  已保留失败配置: ${DATA_DIR}/last_failed_ssserver.json${NC}"
                    fi
                fi
                echo -e "${YELLOW}  已退出编辑器。请回主菜单执行“重启当前服务”。${NC}"
                line
                return 0
                ;;
            2|02)
                echo ""
                echo -e "${RED}${BOLD}  此操作会将当前配置清空为 0 字节。${NC}"
                echo -e "${YELLOW}  清空前会自动备份。${NC}"
                echo -e "${YELLOW}  未重新写入合法 JSON 前，服务无法重启。${NC}"
                read -r -p "输入 yes 确认清空 ${ALPINE_SS_CONFIG_FILE}: " CONFIRM_CLEAR
                if [[ "$CONFIRM_CLEAR" != "yes" ]]; then
                    echo -e "${YELLOW}  已取消。${NC}"
                    sleep 1
                    continue
                fi

                local manual_backup
                manual_backup="${ALPINE_SS_CONFIG_FILE}.bak.manual-clear.$(date +%Y%m%d-%H%M%S)"
                cp -a -- "$ALPINE_SS_CONFIG_FILE" "$manual_backup" || {
                    echo -e "${RED}  备份失败，已取消清空。${NC}"
                    line
                    return 1
                }

                truncate -s 0 "$ALPINE_SS_CONFIG_FILE" || {
                    echo -e "${RED}  清空失败，请手动检查权限或磁盘状态。${NC}"
                    line
                    return 1
                }

                echo -e "${GREEN}  ✓ 配置文件已清空。${NC}"
                echo -e "${CYAN}  备份文件: ${manual_backup}${NC}"
                echo -e "${YELLOW}  请先写入合法配置，再执行“重启当前服务”。${NC}"
                line
                return 0
                ;;
            "")
                continue
                ;;
            0|00)
                return 0
                ;;
            *)
                echo -e "${RED}  无效输入，请输入 0、1 或 2。${NC}"
                sleep 1
                ;;
        esac
    done
}

function uninstall_alpine_ss_and_delete_self() {
    line
    center_echo "卸载脚本和 SS2022" "${RED}${BOLD}"
    line
    echo -e "${RED}  - 卸载 shadowsocks-rust（Alpine）${NC}"
    echo -e "${RED}  - 删除 SS2022 配置与 OpenRC 服务文件${NC}"
    echo -e "${RED}  - 删除快捷指令 zdd${NC}"
    echo -e "${RED}  - 删除本脚本存储目录与生成的 txt 文件${NC}"
    line
    if should_auto_confirm_uninstall; then
        echo -e "${YELLOW}  检测到快捷完整卸载：已自动确认继续。${NC}"
    else
        read -r -p "输入 yes 继续: " CONFIRM
        if [[ "$CONFIRM" != "yes" ]]; then
            echo -e "${YELLOW}已取消。${NC}"
            return 0
        fi
    fi

    rc-service ssserver stop >/dev/null 2>&1 || true
    rc-update del ssserver default >/dev/null 2>&1 || true
    apk del shadowsocks-rust >/dev/null 2>&1 || true
    remove_path_quiet "$ALPINE_SS_SERVICE_FILE" "$ALPINE_SS_SERVICE_FILE"
    remove_path_quiet "$ALPINE_SS_CONFIG_DIR" "$ALPINE_SS_CONFIG_DIR"

    cleanup_doudou_runtime

    echo -e "${GREEN}  ✓ 卸载与清理已完成。${NC}"
    line
    exit 0
}

function install_alpine_ss2022() {
    line
    echo -e "${GREEN}${BOLD}  Alpine 专用 SS2022 安装${NC}"
    line

    echo -e "
${CYAN}[Step 1/7] 系统环境预检${NC}"
    ensure_alpine_supported || return 1

    echo -e "
${CYAN}[Step 2/7] 检查 Alpine 仓库、时间同步与依赖${NC}"
    ensure_alpine_community_repo || return 1
    if ! check_timesync_alpine; then
        handle_timesync_failure "  警告：时间同步未完成，这可能导致 apk、证书校验、TLS 握手或后续网络请求异常。" || return 1
    fi
    install_alpine_runtime_deps || return 1
    check_bbr || true

    echo -e "
${CYAN}[Step 3/7] 手动选择 SS2022 参数${NC}"
    local ss_method=""
    local ss_port=""
    ss_method=$(choose_ss_method) || return 1
    while true; do
        ss_port=$(read_manual_ss_port "请输入 SS2022 监听端口: ") || return 1
        if is_port_in_use "$ss_port"; then
            echo -e "${RED}  端口 ${ss_port} 已被占用，请换一个端口。${NC}"
        else
            break
        fi
    done

    echo -e "
${CYAN}[Step 4/7] 生成密钥与写入配置${NC}"
    local ss_password=""
    ss_password=$(ssservice genkey -m "$ss_method" 2>/dev/null | tr -d '
')
    if [[ -z "$ss_password" ]]; then
        echo -e "${RED}  ✗ 生成 SS2022 密钥失败，请检查 shadowsocks-rust 是否安装完整。${NC}"
        return 1
    fi
    write_alpine_ssserver_config "$ss_port" "$ss_method" "$ss_password" || return 1

    echo -e "
${CYAN}[Step 5/7] 前台短时验证配置${NC}"
    validate_alpine_ssserver_foreground || return 1

    echo -e "
${CYAN}[Step 6/7] 写入 OpenRC 并启动服务${NC}"
    write_alpine_openrc_service || return 1
    rc-update add ssserver default >/dev/null 2>&1 || true
    restart_alpine_ssservice || return 1

    echo -e "
${CYAN}[Step 7/7] 生成节点信息${NC}"
    local public_ip_v4=""
    local public_ip_v6=""
    local ss_link_v4=""
    local ss_link_v6=""
    local sub_text=""
    local ports_text=""

    public_ip_v4=$(get_public_ip_v4 || true)
    public_ip_v6=$(get_public_ip_v6 || true)

    if [[ -n "$public_ip_v4" ]]; then
        ss_link_v4=$(build_ss2022_uri "$public_ip_v4" "$ss_port" "$ss_method" "$ss_password" "SS2022-Alpine-${ss_port}")
    fi
    if [[ -n "$public_ip_v6" ]]; then
        ss_link_v6=$(build_ss2022_uri "$public_ip_v6" "$ss_port" "$ss_method" "$ss_password" "SS2022-Alpine-IPv6-${ss_port}")
    fi

    sub_text="订阅:
  SS2022:
"
    if [[ -n "$ss_link_v4" ]]; then
        sub_text+="  ${ss_link_v4}
"
    else
        sub_text+="  （未获取到公网 IPv4，请手动替换为你的服务器地址）
"
    fi
    if [[ -n "$ss_link_v6" ]]; then
        sub_text+="
  SS2022 (IPv6):
  ${ss_link_v6}
"
    fi

    ports_text="端口:
  SS2022 :     ${ss_port}"
    write_dynamic_result_files "$sub_text" "$ports_text"
    write_install_runtime_kind "alpine-ss2022"
    render_saved_node_info "配置完成" || {
        echo -e "${RED}  节点信息写入失败，请检查 ${INFO_FILE}${NC}"
        return 1
    }
}

function get_public_ip_v4() {
    local ip=""
    local endpoint
    for endpoint in "https://api.ipify.org" "https://ifconfig.me" "https://ip.sb" "https://ipinfo.io/ip"; do
        ip=$(curl -4 -fsS --max-time 5 "$endpoint" 2>/dev/null || true)
        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

function get_public_ip_v6() {
    local ip=""
    local endpoint
    for endpoint in "https://api64.ipify.org" "https://ifconfig.me" "https://ip.sb"; do
        ip=$(curl -6 -fsS --max-time 5 "$endpoint" 2>/dev/null || true)
        if [[ "$ip" =~ : ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

function format_host_for_uri() {
    local host="$1"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        echo "[$host]"
    else
        echo "$host"
    fi
}

function is_port_in_use() {
    local port="$1"
    ss -ltnup 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:|\])${port}$"
}

function pick_random_free_port() {
    local port=""
    local i
    for i in {1..30}; do
        port=$(shuf -i 40000-65000 -n 1)
        if ! is_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done
    return 1
}

function backup_existing_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local backup_file
        backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a -- "$CONFIG_FILE" "$backup_file" || return 1
        echo -e "${YELLOW}  已备份旧配置: ${backup_file}${NC}"
    fi
}

function ensure_sni_benchmark_ready() {
    local missing=()
    local ts_probe=""

    command -v openssl >/dev/null 2>&1 || missing+=("openssl")
    command -v timeout >/dev/null 2>&1 || missing+=("timeout")
    ts_probe=$(date +%s%3N 2>/dev/null || true)
    [[ "$ts_probe" =~ ^[0-9]+$ ]] || missing+=("gnu-date")

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    echo -e "${RED}  ✗ 当前环境缺少 SNI 测速所需依赖。${NC}"
    echo -e "${YELLOW}  缺失项: ${missing[*]}${NC}"
    if is_alpine_system; then
        echo -e "${CYAN}  建议：先执行 10 号 Alpine 专用 SS2022 安装，或手动安装：apk add openssl coreutils${NC}"
    else
        echo -e "${CYAN}  建议：先执行 01 安装，或手动安装 openssl / coreutils 后再测速。${NC}"
    fi
    return 1
}

function get_loaded_sni_pool_signature() {
    printf '%s
' "${DEST_OPTIONS[@]}" | cksum | awk '{print $1 ":" $2}'
}

function benchmark_dest() {
    ensure_sni_benchmark_ready || return 1
    load_sni_pool
    line
    echo -e "${CYAN}${BOLD}  REALITY SNI 延迟测试（每个域名测试 3 次 TLS 握手）${NC}"
    line
    show_sni_pool_source

    local best_avg=99999999
    BEST_DEST=""
    BEST_DEST_POOL_SIG=""

    local d
    for d in "${DEST_OPTIONS[@]}"; do
        local times=()
        local total=0
        local success=0
        local i

        for i in 1 2 3; do
            local t1 t2 elapsed
            t1=$(date +%s%3N 2>/dev/null || echo 0)
            if timeout 3 openssl s_client \
                -connect "${d}:443" \
                -servername "${d}" \
                -verify_return_error \
                </dev/null &>/dev/null; then
                t2=$(date +%s%3N 2>/dev/null || echo 0)
                elapsed=$((t2 - t1))
                [[ $elapsed -lt 0 ]] && elapsed=0
                times+=("${elapsed}")
                total=$((total + elapsed))
                success=$((success + 1))
            else
                times+=("超时")
            fi
        done

        local avg_str="N/A"
        local avg_val=99999999
        if [[ $success -gt 0 ]]; then
            avg_val=$((total / success))
            avg_str="${avg_val} ms"
        fi

        local col1="${times[0]}" col2="${times[1]}" col3="${times[2]}"
        [[ "$col1" != "超时" ]] && col1="${col1} ms"
        [[ "$col2" != "超时" ]] && col2="${col2} ms"
        [[ "$col3" != "超时" ]] && col3="${col3} ms"

        if [[ $avg_val -lt $best_avg ]]; then
            best_avg=$avg_val
            BEST_DEST="$d"
            printf "  ${GREEN}%-40s %7s %7s %7s %8s ★${NC}\n" "$d" "$col1" "$col2" "$col3" "$avg_str"
        else
            printf "  %-40s %7s %7s %7s %8s\n" "$d" "$col1" "$col2" "$col3" "$avg_str"
        fi
    done

    echo ""
    if [[ -z "$BEST_DEST" ]]; then
        echo -e "${RED}  ✗ 所有候选 SNI 均无法完成 TLS 握手，安装已中止。${NC}"
        echo -e "${YELLOW}  请在 SNI 管理中调整候选池，或添加更适合你线路的 SNI 后再试。${NC}"
        line
        return 1
    fi

    BEST_DEST_POOL_SIG=$(get_loaded_sni_pool_signature)
    echo -e "${GREEN}  ✓ 自动锚定最优 SNI：${BOLD}${BEST_DEST}${NC}${GREEN}（平均 ${best_avg} ms）${NC}"
    line
    return 0
}


function print_download_error_reason() {
    local curl_code="$1"
    local err_file="$2"
    local raw_msg=""
    raw_msg=$(tail -n 1 "$err_file" 2>/dev/null | tr -d '
')

    case "$curl_code" in
        6)
            echo -e "${YELLOW}    原因：域名解析失败。${NC}"
            echo -e "${YELLOW}    判断：当前机器 DNS 可能异常，或临时无法解析目标域名。${NC}"
            ;;
        7)
            echo -e "${YELLOW}    原因：无法建立 TCP 连接。${NC}"
            echo -e "${YELLOW}    判断：可能是目标站点不可达、防火墙限制、网络中断，或中间链路异常。${NC}"
            ;;
        22)
            if grep -Eq 'error: 50[234]|HTTP/[0-9.]+ 50[234]' "$err_file"; then
                echo -e "${YELLOW}    原因：远端服务器返回 HTTP 502/503/504。${NC}"
                echo -e "${YELLOW}    判断：通常不是脚本语法问题，而是下载源或网络链路临时异常。${NC}"
            else
                echo -e "${YELLOW}    原因：远端返回了 HTTP 错误状态码。${NC}"
                echo -e "${YELLOW}    判断：通常是下载源异常、访问受限，或中间层返回了错误页面。${NC}"
            fi
            ;;
        28)
            echo -e "${YELLOW}    原因：连接超时或响应超时。${NC}"
            echo -e "${YELLOW}    判断：通常是 VPS 到下载源网络不稳定，或目标站点响应过慢。${NC}"
            ;;
        35)
            echo -e "${YELLOW}    原因：TLS 握手失败。${NC}"
            echo -e "${YELLOW}    判断：可能是中间链路干扰、TLS 协商异常，或目标站点临时故障。${NC}"
            ;;
        60)
            echo -e "${YELLOW}    原因：TLS/证书校验失败。${NC}"
            echo -e "${YELLOW}    判断：可能是系统 CA 证书异常、系统时间不准，或链路被干扰。${NC}"
            ;;
        *)
            echo -e "${YELLOW}    原因：下载命令执行失败（curl exit code: ${curl_code}）。${NC}"
            echo -e "${YELLOW}    判断：更像是外部下载源或网络链路异常，不是当前菜单逻辑错误。${NC}"
            ;;
    esac

    if [[ -n "$raw_msg" ]]; then
        echo -e "${CYAN}    原始信息：${raw_msg}${NC}"
    fi
}

function download_and_run_xray_installer() {
    local action="$1"
    local installer curl_err url max_retry retry sleep_seconds curl_ret
    installer=$(mktemp /tmp/xray-install.XXXXXX.sh)
    curl_err=$(mktemp /tmp/xray-install-curl.XXXXXX.log)
    add_tmp_file "$installer"
    add_tmp_file "$curl_err"

    url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
    max_retry=3
    sleep_seconds=10

    echo -e "${YELLOW}  正在下载 Xray 官方安装脚本...${NC}"
    echo -e "${CYAN}  下载源: ${url}${NC}"

    for retry in $(seq 1 "$max_retry"); do
        : > "$curl_err"
        rm -f -- "$installer"

        echo -e "${CYAN}  第 ${retry}/${max_retry} 次尝试...${NC}"
        if curl -fsSL --connect-timeout 10 --max-time 60 -o "$installer" "$url" 2>"$curl_err"; then
            echo -e "${GREEN}  ✓ 下载成功${NC}"
            break
        fi

        curl_ret=$?
        echo -e "${RED}  ✗ 第 ${retry}/${max_retry} 次下载失败${NC}"
        print_download_error_reason "$curl_ret" "$curl_err"

        if [[ "$retry" -lt "$max_retry" ]]; then
            echo -e "${YELLOW}    处理：${sleep_seconds} 秒后自动重试...${NC}"
            sleep "$sleep_seconds"
        else
            echo -e "${RED}  ✗ 官方安装脚本下载失败，已达到最大重试次数。${NC}"
            echo -e "${YELLOW}    结论：更像是外部下载源或网络链路异常，不是当前管理脚本菜单逻辑错误。${NC}"
            echo -e "${YELLOW}    建议：稍后重试，或手动检查 GitHub / DNS / 出站网络。${NC}"
            return 1
        fi
    done

    if ! grep -Eq '(^#!/.*(sh|bash))|XTLS|Xray-install' "$installer"; then
        echo -e "${RED}  ✗ 下载内容校验失败，已拒绝执行。${NC}"
        echo -e "${YELLOW}    判断：获取到的内容不像官方安装脚本，可能是下载异常、网页错误页或上游临时返回了非脚本内容。${NC}"
        return 1
    fi

    chmod +x "$installer" || return 1

    case "$action" in
        install)
            bash "$installer" install
            ;;
        remove)
            bash "$installer" remove --purge
            ;;
        *)
            return 1
            ;;
    esac
}

function detect_xray_bind_warnings() {
    local reality_port="$1"
    local ss_port="$2"
    echo -e "${YELLOW}  端口监听检查...${NC}"

    if ss -ltnup 2>/dev/null | grep -Eq "(^|[[:space:]])(\*|0\.0\.0\.0|::|\[::\]):${reality_port}[[:space:]]"; then
        echo -e "${GREEN}  ✓ 已检测到 ${reality_port} 端口监听${NC}"
    else
        echo -e "${YELLOW}  ⚠ 未明确检测到 ${reality_port} 端口监听，请手动检查：ss -ltnup | grep :${reality_port}${NC}"
    fi

    if ss -ltnup 2>/dev/null | grep -Eq "(^|[[:space:]])(\*|0\.0\.0\.0|::|\[::\]):${ss_port}[[:space:]]"; then
        echo -e "${GREEN}  ✓ 已检测到 ${ss_port} 端口监听${NC}"
    else
        echo -e "${YELLOW}  ⚠ 未明确检测到 ${ss_port} 端口监听，请手动检查：ss -ltnup | grep :${ss_port}${NC}"
    fi
}



function write_subscription_files() {
    local reality_link="$1"
    local enc_link="$2"
    local ss_link="$3"
    local reality_port="$4"
    local enc_port="$5"
    local ss_port="$6"
    local reality_link_v6="${7:-}"
    local enc_link_v6="${8:-}"
    local ss_link_v6="${9:-}"
    local now_time
    now_time=$(date '+%Y-%m-%d %H:%M:%S')

    (
        umask 077
        cat > "$INFO_FILE" <<INFOEOF
作者    : ${AUTHOR_NAME}
版本    : ${SCRIPT_VERSION}
生成时间: ${now_time}

订阅:
  REALITY:
  ${reality_link}

  Vless-Enc:
  ${enc_link}

  SS2022:
  ${ss_link}
INFOEOF

        if [[ -n "$reality_link_v6" && -n "$ss_link_v6" ]]; then
            cat >> "$INFO_FILE" <<INFOEOF

  REALITY (IPv6):
  ${reality_link_v6}
INFOEOF
            if [[ -n "$enc_link_v6" ]]; then
                cat >> "$INFO_FILE" <<INFOEOF

  Vless-Enc (IPv6):
  ${enc_link_v6}
INFOEOF
            fi
            cat >> "$INFO_FILE" <<INFOEOF

  SS2022 (IPv6):
  ${ss_link_v6}
INFOEOF
        fi

        cat >> "$INFO_FILE" <<INFOEOF

端口:
  REALITY:     ${reality_port}
  Vless-Enc:   ${enc_port}
  SS2022 :     ${ss_port}
INFOEOF

        cat > "$SUB_FILE" <<SUBEOF
作者    : ${AUTHOR_NAME}
版本    : ${SCRIPT_VERSION}
生成时间: ${now_time}

订阅:
  REALITY:
  ${reality_link}

  Vless-Enc:
  ${enc_link}

  SS2022:
  ${ss_link}
SUBEOF

        if [[ -n "$reality_link_v6" && -n "$ss_link_v6" ]]; then
            cat >> "$SUB_FILE" <<SUBEOF

  REALITY (IPv6):
  ${reality_link_v6}
SUBEOF
            if [[ -n "$enc_link_v6" ]]; then
                cat >> "$SUB_FILE" <<SUBEOF

  Vless-Enc (IPv6):
  ${enc_link_v6}
SUBEOF
            fi
            cat >> "$SUB_FILE" <<SUBEOF

  SS2022 (IPv6):
  ${ss_link_v6}
SUBEOF
        fi
    )

    chmod 600 "$INFO_FILE" "$SUB_FILE" >/dev/null 2>&1 || true
}


function get_saved_generate_time() {
    local file_path="$1"
    awk -F': ' '/^生成时间: /{print $2; exit}' "$file_path" 2>/dev/null || true
}

function print_saved_txt_files() {
    echo -e "${CYAN}  文本文件:${NC}"
    echo -e "${CYAN}    - ${INFO_FILE}${NC}"
    echo -e "${CYAN}    - ${SUB_FILE}${NC}"
}

function print_quick_command() {
    echo -e "${CYAN}  快捷指令: zdd xray | zdd install | zdd uninstall${NC}"
}

function render_saved_meta_block() {
    local saved_time="$1"
    echo -e "${GREEN}作者    : ${AUTHOR_NAME}${NC}"
    echo -e "${GREEN}版本    : ${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}生成时间: ${saved_time}${NC}"
}

function render_saved_node_info() {
    local title="$1"
    local saved_time=""

    if [[ ! -f "$INFO_FILE" ]]; then
        return 1
    fi

    saved_time=$(get_saved_generate_time "$INFO_FILE")
    [[ -n "$saved_time" ]] || saved_time="未知"

    line
    center_echo "$title" "${GREEN}${BOLD}"
    echo ""
    render_saved_meta_block "$saved_time"
    echo ""
    sed -e '/^作者    : /d' -e '/^版本    : /d' -e '/^生成时间: /d' "$INFO_FILE"
    echo ""
    print_quick_command
    print_saved_txt_files
    line
    return 0
}


function manage_sni() {
    load_sni_pool
    while true; do
        line
        echo -e "${CYAN}${BOLD}  SNI 管理 & 测速${NC}"
        line
        show_sni_pool_source
        echo -e "  当前候选池（共 ${#DEST_OPTIONS[@]} 个）："
        local idx=1 d
        for d in "${DEST_OPTIONS[@]}"; do
            printf "    ${CYAN}%2d.${NC} %s\n" "$idx" "$d"
            idx=$((idx + 1))
        done
        echo ""
        echo -e "     ${CYAN}a.${NC} 新增域名"
        echo -e "     ${CYAN}d.${NC} 删除域名"
        echo -e "     ${CYAN}r.${NC} 恢复内置默认候选池"
        echo -e "     ${CYAN}t.${NC} 立即对当前候选池测速"
        echo -e "     ${CYAN}0.${NC} 返回主菜单"
        line
        read -r -p "选择: " SNI_CHOICE

        case "$SNI_CHOICE" in
            "")
                continue
                ;;
            a|A)
                read -r -p "新增域名: " NEW_DOMAIN
                NEW_DOMAIN=$(echo "$NEW_DOMAIN" | tr -d '[:space:]')
                if [[ -z "$NEW_DOMAIN" ]]; then
                    echo -e "${RED}  域名不能为空。${NC}"
                elif printf '%s\n' "${DEST_OPTIONS[@]}" | grep -Fxq "$NEW_DOMAIN"; then
                    echo -e "${YELLOW}  该域名已存在，无需重复添加。${NC}"
                else
                    DEST_OPTIONS+=("$NEW_DOMAIN")
                    save_sni_pool
                    echo -e "${GREEN}  ✓ 已添加：${NEW_DOMAIN}${NC}"
                fi
                sleep 1
                ;;
            d|D)
                if [[ ${#DEST_OPTIONS[@]} -le 1 ]]; then
                    echo -e "${RED}  候选池至少需保留 1 个域名，无法删除。${NC}"
                    sleep 1
                    continue
                fi
                read -r -p "删除序号 (1-${#DEST_OPTIONS[@]}): " DEL_IDX
                if [[ "$DEL_IDX" =~ ^[0-9]+$ ]] && [[ $DEL_IDX -ge 1 ]] && [[ $DEL_IDX -le ${#DEST_OPTIONS[@]} ]]; then
                    local DEL_NAME="${DEST_OPTIONS[$((DEL_IDX-1))]}"
                    DEST_OPTIONS=("${DEST_OPTIONS[@]:0:$((DEL_IDX-1))}" "${DEST_OPTIONS[@]:$DEL_IDX}")
                    save_sni_pool
                    echo -e "${GREEN}  ✓ 已删除：${DEL_NAME}${NC}"
                else
                    echo -e "${RED}  无效序号。${NC}"
                fi
                sleep 1
                ;;
            r|R)
                read -r -p "输入 yes 确认恢复默认候选池: " CONFIRM_R
                if [[ "$CONFIRM_R" == "yes" ]]; then
                    DEST_OPTIONS=("${DEFAULT_DEST_OPTIONS[@]}")
                    save_sni_pool
                    echo -e "${GREEN}  ✓ 已恢复内置默认候选池（${#DEST_OPTIONS[@]} 个域名）${NC}"
                else
                    echo -e "  已取消。"
                fi
                sleep 1
                ;;
            t|T)
                benchmark_dest
                echo -e "${CYAN}  提示：当前会话内重新运行安装（主菜单 01），若候选池未变，将直接应用本次测速得到的最优 SNI。${NC}"
                read -r -p "按 Enter 继续..." _
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}  无效输入。${NC}"
                sleep 1
                ;;
        esac
    done
}


function uri_decode() {
    local data="$1"
    data="${data//+/ }"
    printf '%b' "${data//%/\\x}"
}

function get_query_param() {
    local query="$1"
    local key="$2"
    local pair k v had_noglob=0
    local IFS='&'

    case "$-" in
        *f*) had_noglob=1 ;;
    esac
    set -f

    for pair in $query; do
        k="${pair%%=*}"
        v="${pair#*=}"
        if [[ "$k" == "$key" ]]; then
            if [[ $had_noglob -eq 0 ]]; then
                set +f
            fi
            uri_decode "$v"
            return 0
        fi
    done

    if [[ $had_noglob -eq 0 ]]; then
        set +f
    fi
    return 1
}

function base64_decode_relaxed() {
    local s="$1"
    s="${s//-/+}"
    s="${s//_/\/}"
    case $((${#s} % 4)) in
        2) s+="==" ;;
        3) s+="=" ;;
        1) s+="===" ;;
    esac
    printf '%s' "$s" | base64 -d 2>/dev/null
}

PARSED_HOST=""
PARSED_PORT=""
PARSED_LINK_KIND=""
PARSED_LINK_LABEL=""
PARSED_OUTBOUND_JSON=""
PARSED_USER_ID=""
PARSED_ENCRYPTION=""
PARSED_FLOW=""
PARSED_SECURITY=""
PARSED_TRANSPORT=""
PARSED_METHOD=""

function normalize_share_link() {
    local raw="$1"
    printf '%s' "$raw" | tr -d '\r[:space:]'
}

function preview_short_value() {
    local value="$1"
    local limit="${2:-48}"
    if [[ ${#value} -le $limit ]]; then
        printf '%s' "$value"
    else
        printf '%s...' "${value:0:$limit}"
    fi
}

function print_parsed_outbound_preview() {
    echo -e "${CYAN}  解析预览:${NC}" >&2
    echo -e "${CYAN}    kind     : ${PARSED_LINK_KIND}${NC}" >&2
    echo -e "${CYAN}    address  : ${PARSED_HOST}${NC}" >&2
    echo -e "${CYAN}    port     : ${PARSED_PORT}${NC}" >&2
    [[ -n "$PARSED_LINK_LABEL" ]] && echo -e "${CYAN}    label    : ${PARSED_LINK_LABEL}${NC}" >&2
    if [[ "$PARSED_LINK_KIND" == "vless" ]]; then
        [[ -n "$PARSED_USER_ID" ]] && echo -e "${CYAN}    uuid     : $(preview_short_value "$PARSED_USER_ID" 12)${NC}" >&2
        [[ -n "$PARSED_ENCRYPTION" ]] && echo -e "${CYAN}    encrypt  : $(preview_short_value "$PARSED_ENCRYPTION" 72)${NC}" >&2
        [[ -n "$PARSED_FLOW" ]] && echo -e "${CYAN}    flow     : ${PARSED_FLOW}${NC}" >&2
        [[ -n "$PARSED_SECURITY" ]] && echo -e "${CYAN}    security : ${PARSED_SECURITY}${NC}" >&2
        [[ -n "$PARSED_TRANSPORT" ]] && echo -e "${CYAN}    network  : ${PARSED_TRANSPORT}${NC}" >&2
    elif [[ "$PARSED_LINK_KIND" == "ss" ]]; then
        [[ -n "$PARSED_METHOD" ]] && echo -e "${CYAN}    method   : ${PARSED_METHOD}${NC}" >&2
    fi
}

function parse_host_port() {
    local hostport="$1"
    if [[ "$hostport" =~ ^\[(.*)\]:(.*)$ ]]; then
        PARSED_HOST="${BASH_REMATCH[1]}"
        PARSED_PORT="${BASH_REMATCH[2]}"
    elif [[ "$hostport" == *:* ]]; then
        PARSED_HOST="${hostport%:*}"
        PARSED_PORT="${hostport##*:}"
    else
        return 1
    fi
    [[ "$PARSED_PORT" =~ ^[0-9]+$ ]]
}

function parse_ss_link_to_outbound() {
    local link="$1"
    local tag="$2"
    local body main fragment left right creds hostport decoded method password
    local main_no_query="" query=""

    body="${link#ss://}"
    main="${body%%#*}"
    fragment=""
    if [[ "$body" == *#* ]]; then
        fragment="${body#*#}"
    fi

    main_no_query="${main%%\?*}"
    if [[ "$main" == *\?* ]]; then
        query="${main#*\?}"
    fi

    if [[ "$main_no_query" == *"@"* ]]; then
        left="${main_no_query%@*}"
        right="${main_no_query#*@}"
        left=$(uri_decode "$left")
        right=$(uri_decode "$right")
        hostport="${right%/}"
        if [[ "$left" == *:* ]]; then
            creds="$left"
        else
            creds=$(base64_decode_relaxed "$left") || return 1
        fi
    else
        decoded=$(base64_decode_relaxed "$(uri_decode "$main_no_query")") || return 1
        decoded=$(uri_decode "$decoded")
        creds="${decoded%@*}"
        hostport="${decoded#*@}"
        hostport="${hostport%/}"
    fi

    [[ -n "$creds" && -n "$hostport" ]] || return 1
    [[ "$creds" == *:* ]] || return 1
    method="${creds%%:*}"
    password="${creds#*:}"
    parse_host_port "$hostport" || return 1

    PARSED_LINK_KIND="ss"
    PARSED_LINK_LABEL=$(uri_decode "$fragment")
    [[ -n "$PARSED_LINK_LABEL" ]] || PARSED_LINK_LABEL="SS 落地"
    PARSED_METHOD="$method"

    PARSED_OUTBOUND_JSON=$(cat <<EOF
    {
      "tag": "${tag}",
      "protocol": "shadowsocks",
      "settings": {
        "servers": [
          {
            "address": "$(json_escape "$PARSED_HOST")",
            "port": ${PARSED_PORT},
            "method": "$(json_escape "$method")",
            "password": "$(json_escape "$password")"
          }
        ]
      }
    }
EOF
)
}

function parse_vless_link_to_outbound() {
    local link="$1"
    local tag="$2"
    local body main fragment uuid rest hostport query
    local security encryption flow transport sni pbk sid fp
    local user_flow_json stream_json label_dec
    local uuid_dec="" hostport_dec="" fingerprint_json="" shortid_json=""

    body="${link#vless://}"
    main="${body%%#*}"
    fragment=""
    if [[ "$body" == *#* ]]; then
        fragment="${body#*#}"
    fi

    uuid="${main%%@*}"
    rest="${main#*@}"
    [[ -n "$uuid" && "$rest" != "$main" ]] || return 1

    if [[ "$rest" == *\?* ]]; then
        hostport="${rest%%\?*}"
        query="${rest#*\?}"
    else
        hostport="$rest"
        query=""
    fi

    uuid_dec=$(uri_decode "$uuid")
    hostport_dec=$(uri_decode "$hostport")
    hostport_dec="${hostport_dec%/}"
    parse_host_port "$hostport_dec" || return 1

    security=$(get_query_param "$query" "security" || true)
    encryption=$(get_query_param "$query" "encryption" || true)
    flow=$(get_query_param "$query" "flow" || true)
    transport=$(get_query_param "$query" "type" || true)
    sni=$(get_query_param "$query" "sni" || true)
    [[ -n "$sni" ]] || sni=$(get_query_param "$query" "serverName" || true)
    pbk=$(get_query_param "$query" "pbk" || true)
    [[ -n "$pbk" ]] || pbk=$(get_query_param "$query" "publicKey" || true)
    sid=$(get_query_param "$query" "sid" || true)
    [[ -n "$sid" ]] || sid=$(get_query_param "$query" "shortId" || true)
    fp=$(get_query_param "$query" "fp" || true)
    [[ -n "$fp" ]] || fp=$(get_query_param "$query" "fingerprint" || true)
    [[ -n "$fp" ]] || fp="firefox"
    [[ -n "$transport" ]] || transport="tcp"
    [[ "$transport" == "raw" ]] && transport="tcp"

    user_flow_json=""
    if [[ -n "$flow" ]]; then
        user_flow_json=', "flow": "'"$(json_escape "$flow")"'"'
    fi

    if [[ "$security" == "reality" ]]; then
        [[ -n "$sni" && -n "$pbk" ]] || return 1

        fingerprint_json=''
        if [[ -n "$fp" ]]; then
            fingerprint_json=$'
          "fingerprint": "'"$(json_escape "$fp")"'",'
        fi

        shortid_json=''
        if [[ -n "$sid" ]]; then
            shortid_json=$'
          "shortId": "'"$(json_escape "$sid")"'",'
        fi

        stream_json=$(cat <<EOF
,
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "$(json_escape "$sni")",
          "publicKey": "$(json_escape "$pbk")",${shortid_json}${fingerprint_json}
          "spiderX": "/"
        }
      }
EOF
)
    else
        stream_json=$(cat <<EOF
,
      "streamSettings": {
        "network": "${transport}"
      }
EOF
)
    fi

    label_dec=$(uri_decode "$fragment")
    if [[ -n "$encryption" && "$encryption" != "none" ]]; then
        [[ -n "$label_dec" ]] || label_dec="Vless-Enc 落地"
    elif [[ "$security" == "reality" ]]; then
        [[ -n "$label_dec" ]] || label_dec="VLESS Reality 落地"
    else
        [[ -n "$label_dec" ]] || label_dec="VLESS 落地"
    fi

    [[ -n "$encryption" ]] || encryption="none"
    PARSED_LINK_KIND="vless"
    PARSED_LINK_LABEL="$label_dec"
    PARSED_USER_ID="$uuid_dec"
    PARSED_ENCRYPTION="$encryption"
    PARSED_FLOW="$flow"
    PARSED_SECURITY="$security"
    PARSED_TRANSPORT="$transport"
    PARSED_OUTBOUND_JSON=$(cat <<EOF
    {
      "tag": "${tag}",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$(json_escape "$PARSED_HOST")",
            "port": ${PARSED_PORT},
            "users": [
              {
                "id": "$(json_escape "$uuid_dec")",
                "encryption": "$(json_escape "$encryption")"${user_flow_json}
              }
            ]
          }
        ]
      }${stream_json}
    }
EOF
)
}

function build_outbound_from_link() {
    local link="$1"
    local tag="$2"
    PARSED_HOST=""
    PARSED_PORT=""
    PARSED_LINK_KIND=""
    PARSED_LINK_LABEL=""
    PARSED_OUTBOUND_JSON=""
    PARSED_USER_ID=""
    PARSED_ENCRYPTION=""
    PARSED_FLOW=""
    PARSED_SECURITY=""
    PARSED_TRANSPORT=""
    PARSED_METHOD=""
    case "$link" in
        ss://*) parse_ss_link_to_outbound "$link" "$tag" ;;
        vless://*) parse_vless_link_to_outbound "$link" "$tag" ;;
        *) return 1 ;;
    esac
}

function get_common_block_rules_json() {
cat <<'EOF'
      {
        "type": "field",
        "domain": [
          "full:localhost",
          "full:localhost.localdomain"
        ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "network": "udp",
        "port": "53,853",
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "network": "tcp",
        "port": "53,853",
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "network": "tcp",
        "port": "25,465,587,2525",
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "ip": [
          "geoip:private",
          "0.0.0.0/8",
          "10.0.0.0/8",
          "100.64.0.0/10",
          "127.0.0.0/8",
          "169.254.0.0/16",
          "169.254.169.254/32",
          "172.16.0.0/12",
          "192.0.0.0/24",
          "192.0.2.0/24",
          "192.168.0.0/16",
          "198.18.0.0/15",
          "198.51.100.0/24",
          "203.0.113.0/24",
          "224.0.0.0/4",
          "240.0.0.0/4",
          "255.255.255.255/32",
          "::/128",
          "::1/128",
          "fc00::/7",
          "fe80::/10",
          "ff00::/8",
          "2001:db8::/32"
        ],
        "outboundTag": "blocked"
      },
EOF
}

function write_dynamic_result_files() {
    local sub_text="$1"
    local ports_text="$2"
    local now_time
    now_time=$(date '+%Y-%m-%d %H:%M:%S')

    (
        umask 077
        {
            printf '作者    : %s\n' "$AUTHOR_NAME"
            printf '版本    : %s\n' "$SCRIPT_VERSION"
            printf '生成时间: %s\n\n' "$now_time"
            printf '%b\n' "$sub_text"
            if [[ -n "$ports_text" ]]; then
                printf '\n%b\n' "$ports_text"
            fi
        } > "$INFO_FILE"

        {
            printf '作者    : %s\n' "$AUTHOR_NAME"
            printf '版本    : %s\n' "$SCRIPT_VERSION"
            printf '生成时间: %s\n\n' "$now_time"
            printf '%b\n' "$sub_text"
        } > "$SUB_FILE"
    )

    chmod 600 "$INFO_FILE" "$SUB_FILE" >/dev/null 2>&1 || true
}


function get_install_scenario_label() {
    case "$1" in
        1) printf '%s' '单 Reality（直出 / 多落地）' ;;
        2) printf '%s' '单 SS 直出' ;;
        3) printf '%s' '单 Vless-Enc 直出' ;;
        4) printf '%s' 'Reality Vless-Enc SS 三入站直出' ;;
        5) printf '%s' 'SS 传导链' ;;
        6) printf '%s' 'Vless-Enc 传导链' ;;
        7) printf '%s' 'XHTTP + Reality 上下行分离' ;;
        8) printf '%s' 'XHTTP + Vless-Enc 上下行分离（实验性）' ;;
        *) printf '%s' '未知模板' ;;
    esac
}

function render_install_context() {
    local template_label="$1"
    local install_mode="$2"
    local install_mode_label=""
    case "$install_mode" in
        auto) install_mode_label="自动模式" ;;
        manual) install_mode_label="手动模式" ;;
        *) install_mode_label="$install_mode" ;;
    esac
    echo -e "${CYAN}  当前模板: ${template_label}${NC}"
    echo -e "${CYAN}  安装模式: ${install_mode_label}${NC}"
}

function choose_install_scenario() {
    local choice
    while true; do
        line >&2
        echo -e "${CYAN}${BOLD}  第三层：选择安装模板${NC}" >&2
        line >&2
        echo -e "${CYAN}  基础直出:${NC}" >&2
        echo -e "  ${CYAN}1.${NC} 单 Reality（直出 / 多落地）" >&2
        echo -e "  ${CYAN}2.${NC} 单 SS 直出" >&2
        echo -e "  ${CYAN}3.${NC} 单 Vless-Enc 直出" >&2
        echo -e "  ${CYAN}4.${NC} Reality Vless-Enc SS 三入站直出" >&2
        echo -e "" >&2
        echo -e "${CYAN}  进阶链路:${NC}" >&2
        echo -e "  ${CYAN}5.${NC} SS 传导链（SS 入站 -> SS 出站）" >&2
        echo -e "  ${CYAN}6.${NC} Vless-Enc 传导链（Vless-Enc 入站 -> VLESS 系出站）" >&2
        echo -e "  ${CYAN}7.${NC} XHTTP + Reality 上下行分离（须双栈 / 直出 / 多落地）" >&2
        echo -e "  ${CYAN}8.${NC} XHTTP + Vless-Enc 上下行分离（须双栈 / 直出 / 高风险慎用）" >&2
        line >&2
        read -r -p "选择 [1-8]: " choice
        case "$choice" in
            1|2|3|4|5|6|7|8) printf '%s' "$choice"; return 0 ;;
            *) echo -e "${RED}  请输入 1-8。${NC}" >&2 ;;
        esac
    done
}

function choose_xhttp_split_direction() {
    local choice
    while true; do
        echo -e "  ${CYAN}1.${NC} v6 去 / v4 回（默认）" >&2
        echo -e "  ${CYAN}2.${NC} v4 去 / v6 回" >&2
        read -r -p "选择 XHTTP 分离方向 [1-2]，默认 1: " choice
        case "${choice:-1}" in
            1|01)
                printf '%s' 'v6_up_v4_down'
                return 0
                ;;
            2|02)
                printf '%s' 'v4_up_v6_down'
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1 或 2。${NC}" >&2
                ;;
        esac
    done
}

function get_xhttp_split_direction_desc() {
    case "$1" in
        v6_up_v4_down) printf '%s' 'v6 去 / v4 回' ;;
        v4_up_v6_down) printf '%s' 'v4 去 / v6 回' ;;
        *) printf '%s' 'v6 去 / v4 回' ;;
    esac
}

function get_xhttp_split_direction_share_name() {
    case "$1" in
        v6_up_v4_down) printf '%s' 'v6去v4回' ;;
        v4_up_v6_down) printf '%s' 'v4去v6回' ;;
        *) printf '%s' 'v6去v4回' ;;
    esac
}

function generate_xhttp_path() {
    local rand_left=""
    local rand_right=""
    rand_left=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 5)
    rand_right=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 5)
    [[ -n "$rand_left" ]] || rand_left=$(openssl rand -hex 3 2>/dev/null | cut -c1-5 || true)
    [[ -n "$rand_right" ]] || rand_right=$(openssl rand -hex 3 2>/dev/null | cut -c1-5 || true)
    [[ -n "$rand_left" ]] || rand_left="$(date +%s | tail -c 6)"
    [[ -n "$rand_right" ]] || rand_right="$(date +%N | tail -c 6)"
    printf '/%s_%s' "$rand_left" "$rand_right"
}

function read_manual_xhttp_path() {
    local prompt="$1"
    local value
    while true; do
        read -r -p "$prompt" value
        value=$(printf '%s' "$value" | tr -d '[:space:]')
        [[ -n "$value" ]] || {
            echo -e "${RED}  path 不能为空。${NC}" >&2
            continue
        }
        [[ "$value" == /* ]] || value="/${value}"
        if [[ "$value" == *'"'* || "$value" == *"'"* ]]; then
            echo -e "${RED}  path 不能包含引号。${NC}" >&2
            continue
        fi
        printf '%s' "$value"
        return 0
    done
}

XHTTP_PATCH_LAST_JSON=""

function build_xhttp_client_patch_json() {
    local address="$1"
    local port="$2"
    local security="$3"
    local server_name="$4"
    local fingerprint="$5"
    local public_key="$6"
    local short_id="$7"
    local path="$8"

    if [[ "$security" == "reality" ]]; then
        cat <<EOF
{
"downloadSettings": {
"address": "$(json_escape "$address")",
"port": ${port},
"network": "xhttp",
"security": "reality",
"realitySettings": {
"serverName": "$(json_escape "$server_name")",
"fingerprint": "$(json_escape "$fingerprint")",
"publicKey": "$(json_escape "$public_key")",
"shortId": "$(json_escape "$short_id")"
},
"xhttpSettings": {
"path": "$(json_escape "$path")"
}
}
}
EOF
    else
        cat <<EOF
{
"downloadSettings": {
"address": "$(json_escape "$address")",
"port": ${port},
"network": "xhttp",
"xhttpSettings": {
"path": "$(json_escape "$path")"
}
}
}
EOF
    fi
}

function write_xhttp_client_patch_file() {
    local file_path="$1"
    local address="$2"
    local port="$3"
    local security="$4"
    local server_name="$5"
    local fingerprint="$6"
    local public_key="$7"
    local short_id="$8"
    local path="$9"

    XHTTP_PATCH_LAST_JSON=$(build_xhttp_client_patch_json "$address" "$port" "$security" "$server_name" "$fingerprint" "$public_key" "$short_id" "$path") || return 1
    return 0
}
function precheck_reality_port_before_apply() {
    local scenario="$1"
    local port="$2"

    case "$scenario" in
        1|4|7)
            echo -e "${YELLOW}  端口预检...${NC}"
            if is_port_in_use_by_non_xray "$port"; then
                echo -e "${RED}  端口 ${port} 已被非 xray 进程占用，安装已中止。${NC}"
                echo -e "${YELLOW}  请先执行：ss -ltnup | grep :${port}${NC}"
                return 1
            fi
            echo -e "${GREEN}  ✓ Reality 目标端口 ${port} 未被非 xray 进程占用${NC}"
            ;;
    esac
    return 0
}

function install_xray() {
    line
    echo -e "${GREEN}${BOLD}  多方式安装${NC}"
    line

    echo -e "\n${CYAN}[Step 1/7] 系统环境预检${NC}"
    ensure_systemd_supported || return 1
    if ! check_timesync; then
        handle_timesync_failure "  警告：时间同步未完成，这可能导致下载、证书校验、TLS 握手或 Reality 相关流程异常。" || return 1
    fi
    check_bbr || true

    echo -e "\n${CYAN}[Step 2/7] 第二层：安装模式${NC}"
    local INSTALL_MODE="auto"
    if is_quick_install_noninteractive; then
        echo -e "${YELLOW}  检测到非交互快速安装：安装模式自动使用默认值（自动模式）。${NC}"
    else
        while true; do
            echo -e "  ${CYAN}1.${NC} 自动模式"
            echo -e "  ${CYAN}2.${NC} 手动模式"
            read -r -p "选择 [1-2]，默认 1: " INSTALL_MODE_CHOICE
            case "${INSTALL_MODE_CHOICE:-1}" in
                1|01) INSTALL_MODE="auto"; break ;;
                2|02) INSTALL_MODE="manual"; break ;;
                *) echo -e "${RED}  请输入 1 或 2。${NC}" ;;
            esac
        done
    fi

    echo -e "\n${CYAN}[Step 3/7] 第三层：模板选择${NC}"
    local SCENARIO=""
    if is_quick_install_noninteractive; then
        if [[ -n "$QUICK_SCENARIO" ]]; then
            SCENARIO="$QUICK_SCENARIO"
            echo -e "${YELLOW}  检测到非交互快速安装：安装模板自动使用指定值（$(printf '%02d' "$SCENARIO") $(get_install_scenario_label "$SCENARIO")）。${NC}"
        else
            SCENARIO="1"
            echo -e "${YELLOW}  检测到非交互快速安装：安装模板自动使用默认值（01 单 Reality）。${NC}"
        fi
    else
        SCENARIO=$(choose_install_scenario)
    fi
    local TEMPLATE_LABEL
    TEMPLATE_LABEL=$(get_install_scenario_label "$SCENARIO")

    local FREEDOM_DOMAIN_STRATEGY="UseIPv4"
    local REALITY_PORT="$DEFAULT_PORT"
    local SNI_SOURCE="auto"
    local MANUAL_DEST=""
    local DEST=""
    local SS_PORT_SOURCE="auto"
    local MANUAL_SS_PORT=""
    local ENC_PORT_SOURCE="auto"
    local MANUAL_ENC_PORT=""
    local ENC_RTT_MODE="0rtt"
    local ENC_SHAPE_MODE="xorpub"
    local ENC_TICKET_WINDOW="600s"
    local ENC_AUTH_METHOD="x25519"
    local ENC_PADDING_PROFILE="off"
    local ENC_PADDING_PROFILE_DESC="$(get_vlessenc_padding_profile_desc off)"
    local ENC_PADDING_CLIENT=""
    local ENC_PADDING_SERVER=""
    local NEED_LANDING="0"
    local LANDING_LINK=""
    local LANDING_EXPECT="any"
    local FREEDOM_DESC="IPv4 优先"
    local SS_METHOD_DESC="2022-blake3-aes-128-gcm"
    local LOCAL_SS_METHOD="2022-blake3-aes-128-gcm"
    local REALITY_LANDING_COUNT=0
    local -a LANDING_LINKS=()
    local -a REALITY_LANDING_UUIDS=()
    local -a LANDING_LABELS=()
    local -a LANDING_JSONS=()
    local -a LANDING_TAGS=()
    local XHTTP_SPLIT_DIRECTION="v6_up_v4_down"
    local XHTTP_SPLIT_DESC="$(get_xhttp_split_direction_desc v6_up_v4_down)"
    local XHTTP_PATH="$(generate_xhttp_path)"
    local XHTTP_SECURITY=""
    local XHTTP_MODE_ENABLED="0"
    local XHTTP_WARNING_TEXT=""
    local XHTTP_REQ_V4=""
    local XHTTP_REQ_V6=""

    echo -e "${GREEN}  已选：${TEMPLATE_LABEL}${NC}"

    case "$SCENARIO" in
        1)
            echo -e "${CYAN}  说明：Reality 专用模板支持 0-3 个落地出口。0 代表纯直出；1-3 代表在直出之外，再增加 1-3 个落地入口。${NC}"
            echo -e "${CYAN}  这些入口共用同一个 Reality 监听端口，通过不同用户 / UUID 区分直出与各个落地出口。${NC}"
            REALITY_LANDING_COUNT=$(choose_reality_landing_count)
            if (( REALITY_LANDING_COUNT > 0 )); then
                NEED_LANDING="1"
                LANDING_EXPECT="any"
            fi
            ;;
        5)
            NEED_LANDING="1"
            LANDING_EXPECT="ss"
            ;;
        6)
            NEED_LANDING="1"
            LANDING_EXPECT="vless"
            ;;
        7)
            XHTTP_MODE_ENABLED="1"
            XHTTP_SECURITY="reality"
            echo -e "${CYAN}  说明：该模板使用 XHTTP + Reality，并通过 downloadSettings 做去程 / 回程分离。${NC}"
            echo -e "${CYAN}  这些入口共用同一个 XHTTP + Reality 监听端口，通过不同用户 / UUID 区分直出与各个落地出口。${NC}"
            REALITY_LANDING_COUNT=$(choose_reality_landing_count)
            if (( REALITY_LANDING_COUNT > 0 )); then
                NEED_LANDING="1"
                LANDING_EXPECT="any"
            fi
            ;;
        8)
            XHTTP_MODE_ENABLED="1"
            XHTTP_SECURITY="none"
            ENC_RTT_MODE="1rtt"
            ENC_SHAPE_MODE="random"
            ENC_AUTH_METHOD="mlkem768"
            ENC_PADDING_PROFILE="aggressive"
            ENC_PADDING_PROFILE_DESC="$(get_vlessenc_padding_profile_desc aggressive)"
            echo -e "${RED}${BOLD}  警告：该模板为 XHTTP + Vless-Enc，无 TLS / 无 Reality，仅适合实验研究，不建议在高风险公网环境使用。${NC}"
            ;;
    esac

    echo -e "${YELLOW}  说明：01 安装为覆盖安装，会生成新的完整配置并替换当前 Xray 配置；旧配置会先自动备份。${NC}"

    if [[ "$INSTALL_MODE" == "auto" ]]; then
        echo -e "${CYAN}  自动模式将使用本模板默认值：${NC}"
        case "$SCENARIO" in
            1)
                echo -e "${CYAN}    - Reality 端口：${REALITY_PORT}${NC}"
                echo -e "${CYAN}    - Reality SNI：自动测速选优${NC}"
                if (( REALITY_LANDING_COUNT == 0 )); then
                    echo -e "${CYAN}    - 架构：纯直出${NC}"
                else
                    echo -e "${CYAN}    - 架构：直出 + ${REALITY_LANDING_COUNT} 个落地出口${NC}"
                fi
                ;;
            2)
                echo -e "${CYAN}    - SS2022 加密：${SS_METHOD_DESC}${NC}"
                echo -e "${CYAN}    - SS2022 端口：随机高位端口${NC}"
                ;;
            3)
                echo -e "${CYAN}    - Vless-Enc：xorpub / 0rtt / x25519 认证${NC}"
                echo -e "${CYAN}    - Vless-Enc padding / delay：${ENC_PADDING_PROFILE_DESC}${NC}"
                echo -e "${CYAN}    - Vless-Enc 端口：随机高位端口${NC}"
                ;;
            4)
                echo -e "${CYAN}    - Reality 端口：${REALITY_PORT}${NC}"
                echo -e "${CYAN}    - Reality SNI：自动测速选优${NC}"
                echo -e "${CYAN}    - SS2022 加密：${SS_METHOD_DESC}${NC}"
                echo -e "${CYAN}    - Vless-Enc：xorpub / 0rtt / x25519 认证${NC}"
                echo -e "${CYAN}    - Vless-Enc padding / delay：${ENC_PADDING_PROFILE_DESC}${NC}"
                ;;
            5)
                echo -e "${CYAN}    - SS2022 加密：${SS_METHOD_DESC}${NC}"
                echo -e "${CYAN}    - 入口：SS 入站${NC}"
                echo -e "${CYAN}    - 出口：SS 落地${NC}"
                ;;
            6)
                echo -e "${CYAN}    - Vless-Enc：xorpub / 0rtt / x25519 认证${NC}"
                echo -e "${CYAN}    - Vless-Enc padding / delay：${ENC_PADDING_PROFILE_DESC}${NC}"
                echo -e "${CYAN}    - 入口：Vless-Enc 入站${NC}"
                echo -e "${CYAN}    - 出口：VLESS / Reality / Vless-Enc${NC}"
                ;;
            7)
                echo -e "${CYAN}    - XHTTP + Reality：启用${NC}"
                echo -e "${CYAN}    - 分离方向：${XHTTP_SPLIT_DESC}${NC}"
                echo -e "${CYAN}    - XHTTP path：${XHTTP_PATH}${NC}"
                echo -e "${CYAN}    - Reality 端口：${REALITY_PORT}${NC}"
                echo -e "${CYAN}    - Reality SNI：自动测速选优${NC}"
                echo -e "${CYAN}    - 客户端：推荐 v2rayN + Xray 内核；其他客户端本脚本不支持自动适配${NC}"
                ;;
            8)
                echo -e "${CYAN}    - XHTTP + Vless-Enc：实验性启用${NC}"
                echo -e "${CYAN}    - 分离方向：${XHTTP_SPLIT_DESC}${NC}"
                echo -e "${CYAN}    - XHTTP path：${XHTTP_PATH}${NC}"
                echo -e "${CYAN}    - Vless-Enc：random / 1rtt / mlkem768 认证${NC}"
                echo -e "${CYAN}    - Vless-Enc padding / delay：${ENC_PADDING_PROFILE_DESC}${NC}"
                echo -e "${CYAN}    - 客户端：推荐 v2rayN + Xray 内核；其他客户端本脚本不支持自动适配${NC}"
                ;;
        esac
    fi

    if [[ "$INSTALL_MODE" == "manual" ]]; then
        echo ""
        if ask_yes_no "  是否手动选择直连出站的 IPv4 策略（y=手动选择，n=使用默认配置：IPv4 优先）"; then
            FREEDOM_DOMAIN_STRATEGY=$(choose_freedom_domain_strategy)
            [[ "$FREEDOM_DOMAIN_STRATEGY" == "ForceIPv4" ]] && FREEDOM_DESC="仅 IPv4"
        fi

        if [[ "$SCENARIO" == "1" || "$SCENARIO" == "4" || "$SCENARIO" == "7" ]]; then
            echo ""
            echo -e "${CYAN}  当前模板包含 Reality 入站，因此需要设置 Reality 端口与 SNI。${NC}"
            echo -e "${CYAN}  Reality 端口：${NC}"
            REALITY_PORT=$(choose_reality_port)
            echo ""
            if ask_yes_no "  是否手动输入 REALITY SNI（y=手动输入，n=使用默认配置：自动测速选优）"; then
                MANUAL_DEST=$(read_manual_sni "请输入 SNI / serverName / dest 域名: ")
                SNI_SOURCE="manual"
            fi
        fi

        if [[ "$SCENARIO" == "2" || "$SCENARIO" == "4" || "$SCENARIO" == "5" ]]; then
            echo ""
            echo -e "${YELLOW}  警告！SS 和 Vless-Enc 不适合过墙${NC}"
            echo -e "${CYAN}  先定义 SS2022 入站，再决定具体加密方式。${NC}"
            echo -e "${CYAN}  SS2022 加密方式：${NC}"
            LOCAL_SS_METHOD=$(choose_ss_method)
            SS_METHOD_DESC="$LOCAL_SS_METHOD"
            if ask_yes_no "  是否手动指定 SS2022 端口（y=手动指定，n=使用默认配置：随机高位端口）"; then
                MANUAL_SS_PORT=$(read_manual_ss_port "请输入 SS2022 端口: ")
                SS_PORT_SOURCE="manual"
            fi
        fi

        if [[ "$SCENARIO" == "3" || "$SCENARIO" == "4" || "$SCENARIO" == "6" || "$SCENARIO" == "8" ]]; then
            echo ""
            if [[ "$SCENARIO" != "8" ]]; then
                echo -e "${YELLOW}  警告！SS 和 Vless-Enc 不适合过墙${NC}"
            else
                echo -e "${RED}  警告！该模板无 TLS / 无 Reality，仅适合实验研究。${NC}"
            fi
            echo -e "${CYAN}  先定义 Vless-Enc 入站端口，再配置握手与实验性参数。${NC}"
            if ask_yes_no "  是否手动指定 Vless-Enc 端口（y=手动指定，n=使用默认配置：随机高位端口）"; then
                MANUAL_ENC_PORT=$(read_manual_ss_port "请输入 Vless-Enc 端口: ")
                ENC_PORT_SOURCE="manual"
            fi
            echo ""
            echo -e "${CYAN}  Vless-Enc 握手模式：${NC}"
            echo -e "${CYAN}  - 0rtt：更偏性能；1rtt：更偏保守${NC}"
            ENC_RTT_MODE=$(choose_vlessenc_rtt_mode)
            echo ""
            echo -e "${CYAN}  Vless-Enc 包形态：${NC}"
            echo -e "${CYAN}  - xorpub / native / random：默认推荐 xorpub${NC}"
            ENC_SHAPE_MODE=$(choose_vlessenc_shape_mode)
            echo ""
            echo -e "${CYAN}  Vless-Enc 认证方式：${NC}"
            echo -e "${CYAN}  - x25519 更短；mlkem768 更长且认证也抗量子${NC}"
            ENC_AUTH_METHOD=$(choose_vlessenc_auth_method)
            echo ""
            echo -e "${CYAN}  Vless-Enc 实验性 padding / delay：${NC}"
            echo -e "${CYAN}  - 客户端与服务端将使用不同规则；手动自定义时可分别输入。${NC}"
            ENC_PADDING_PROFILE=$(choose_vlessenc_padding_profile)
            ENC_PADDING_PROFILE_DESC=$(get_vlessenc_padding_profile_desc "$ENC_PADDING_PROFILE")
            if [[ "$ENC_PADDING_PROFILE" == "custom" ]]; then
                echo ""
                ENC_PADDING_CLIENT=$(read_manual_vlessenc_padding_profile "客户端")
                echo ""
                ENC_PADDING_SERVER=$(read_manual_vlessenc_padding_profile "服务端")
            fi
        fi

        if [[ "$SCENARIO" == "7" || "$SCENARIO" == "8" ]]; then
            echo ""
            echo -e "${CYAN}  当前模板包含 XHTTP 分离链路，需要额外指定分离方向与 path。${NC}"
            XHTTP_SPLIT_DIRECTION=$(choose_xhttp_split_direction)
            XHTTP_SPLIT_DESC=$(get_xhttp_split_direction_desc "$XHTTP_SPLIT_DIRECTION")
            echo -e "${CYAN}  客户端建议：v2rayN + Xray 内核。其他客户端本脚本不支持自动适配。${NC}"
            if ask_yes_no "  是否手动指定 XHTTP path（y=手动输入，n=使用默认随机 path）"; then
                XHTTP_PATH=$(read_manual_xhttp_path "请输入 XHTTP path: ")
            fi
        fi
    fi

    if [[ "$SCENARIO" == "1" || "$SCENARIO" == "4" || "$SCENARIO" == "7" ]]; then
        echo -e "${CYAN}  当前 Reality 端口：${REALITY_PORT}${NC}"
    fi
    if [[ "$SCENARIO" == "2" || "$SCENARIO" == "4" || "$SCENARIO" == "5" ]]; then
        echo -e "${CYAN}  当前 SS2022 加密方式：${SS_METHOD_DESC}${NC}"
    fi
    if [[ "$SCENARIO" == "3" || "$SCENARIO" == "4" || "$SCENARIO" == "6" || "$SCENARIO" == "8" ]]; then
        echo -e "${CYAN}  当前 Vless-Enc 实验性 padding / delay：${ENC_PADDING_PROFILE_DESC}${NC}"
    fi
    if [[ "$SCENARIO" == "7" || "$SCENARIO" == "8" ]]; then
        XHTTP_REQ_V4=$(get_public_ip_v4 || true)
        XHTTP_REQ_V6=$(get_public_ip_v6 || true)
        if [[ -z "$XHTTP_REQ_V4" || -z "$XHTTP_REQ_V6" ]]; then
            echo -e "${RED}  ✗ 当前机器未检测到双栈公网（需要同时具备 IPv4 与 IPv6），无法使用 XHTTP 分离链路。${NC}"
            return 1
        fi
        echo -e "${CYAN}  当前 XHTTP 分离方向：${XHTTP_SPLIT_DESC}${NC}"
        echo -e "${CYAN}  当前 XHTTP path：${XHTTP_PATH}${NC}"
    fi

    if [[ "$SCENARIO" == "1" && "$REALITY_LANDING_COUNT" -gt 0 ]] || [[ "$SCENARIO" == "7" && "$REALITY_LANDING_COUNT" -gt 0 ]]; then
        echo ""
        echo -e "${CYAN}  当前模板为 Reality 多出口模式，需要依次输入 ${REALITY_LANDING_COUNT} 个落地目标链接。${NC}"
        echo -e "${CYAN}  支持输入 ss:// 或 vless:// 链接；每个链接会绑定到一个独立的用户入口。${NC}"
        local idx
        for idx in $(seq 1 "$REALITY_LANDING_COUNT"); do
            while true; do
                read -r -p "请输入第 ${idx} 个落地链接: " LANDING_LINK
                LANDING_LINK=$(normalize_share_link "$LANDING_LINK")
                [[ -n "$LANDING_LINK" ]] || { echo -e "${RED}  链接不能为空。${NC}"; continue; }
                case "$LANDING_LINK" in
                    ss://*|vless://*) LANDING_LINKS+=("$LANDING_LINK"); break ;;
                    *) echo -e "${RED}  仅支持 ss:// 或 vless:// 链接。${NC}" ;;
                esac
            done
        done
    elif [[ "$NEED_LANDING" == "1" ]]; then
        echo ""
        echo -e "${CYAN}  当前模板需要输入一个落地 / 传导目标链接。${NC}"
        case "$LANDING_EXPECT" in
            ss) echo -e "${CYAN}  原因：当前模板为 SS 传导链，因此需要一个 ss:// 出站目标。${NC}" ;;
            vless) echo -e "${CYAN}  原因：当前模板为 Vless-Enc 传导链，因此需要一个 vless:// 出站目标。${NC}" ;;
        esac
        while true; do
            read -r -p "请输入落地 / 传导链接: " LANDING_LINK
            LANDING_LINK=$(normalize_share_link "$LANDING_LINK")
            [[ -n "$LANDING_LINK" ]] || { echo -e "${RED}  链接不能为空。${NC}"; continue; }
            case "$LANDING_EXPECT" in
                ss)
                    [[ "$LANDING_LINK" == ss://* ]] || { echo -e "${RED}  该模板只接受 ss:// 链接。${NC}"; continue; }
                    ;;
                vless)
                    [[ "$LANDING_LINK" == vless://* ]] || { echo -e "${RED}  该模板只接受 vless:// 链接。${NC}"; continue; }
                    ;;
            esac
            LANDING_LINKS=("$LANDING_LINK")
            break
        done
    fi

    echo -e "\n${CYAN}[Step 4/7] 安装依赖与 Xray 核心${NC}"
    render_install_context "$TEMPLATE_LABEL" "$INSTALL_MODE"
    install_deps || {
        echo -e "${RED}依赖安装失败，请检查网络和软件源。${NC}"
        return 1
    }

    echo -e "${YELLOW}  安装 Xray 核心程序...${NC}"
    download_and_run_xray_installer install || {
        echo -e "${RED}Xray 安装失败！请检查网络连接后重试。${NC}"
        return 1
    }

    if [[ ! -x /usr/local/bin/xray ]]; then
        echo -e "${RED}Xray 安装失败：未找到 /usr/local/bin/xray${NC}"
        return 1
    fi
    echo -e "${GREEN}  ✓ 安装成功：$(/usr/local/bin/xray version | head -1)${NC}"

    if [[ "$SCENARIO" == "1" || "$SCENARIO" == "4" || "$SCENARIO" == "7" ]]; then
        echo -e "\n${CYAN}[Step 5/7] REALITY SNI 延迟测速${NC}"
        render_install_context "$TEMPLATE_LABEL" "$INSTALL_MODE"
        if [[ "$SNI_SOURCE" == "manual" ]]; then
            DEST="$MANUAL_DEST"
            echo -e "${GREEN}  ✓ 使用手动指定 SNI：${DEST}${NC}"
        else
            load_sni_pool
            local CURRENT_POOL_SIG=""
            CURRENT_POOL_SIG=$(get_loaded_sni_pool_signature)
            if [[ -n "$BEST_DEST" && -n "$BEST_DEST_POOL_SIG" && "$BEST_DEST_POOL_SIG" == "$CURRENT_POOL_SIG" ]]; then
                DEST="$BEST_DEST"
                echo -e "${GREEN}  ✓ 复用当前会话已测速的最优 SNI：${DEST}${NC}"
            else
                benchmark_dest || return 1
                DEST="$BEST_DEST"
            fi
        fi
    else
        echo -e "\n${CYAN}[Step 5/7] 模板参数确认${NC}"
        render_install_context "$TEMPLATE_LABEL" "$INSTALL_MODE"
        echo -e "${GREEN}  ✓ 当前模板无需 REALITY SNI 测速${NC}"
    fi

    echo -e "\n${CYAN}[Step 6/7] 生成密钥、端口与落地参数${NC}"
    render_install_context "$TEMPLATE_LABEL" "$INSTALL_MODE"
    local PORT="$REALITY_PORT"
    local SHORT_ID UUID KEYS PRIVATE_KEY PUBLIC_KEY
    local REALITY_DIRECT_UUID=""
    local REALITY_DIRECT_LINK=""
    local LOCAL_SS_PORT="" LOCAL_SS_PWD=""
    local LOCAL_ENC_PORT=""
    local VLESS_ENC_DECRYPTION="" VLESS_ENC_ENCRYPTION=""
    local VLESSENC_PAIR_RAW="" VLESS_ENC_DECRYPTION_BASE="" VLESS_ENC_ENCRYPTION_BASE=""
    local -a REALITY_LANDING_LINKS=()
    local -a REALITY_LANDING_LINKS_V6=()

    if [[ "$SCENARIO" == "1" || "$SCENARIO" == "4" || "$SCENARIO" == "7" ]]; then
        SHORT_ID=$(generate_short_id) || { echo -e "${RED}  ✗ 生成 shortId 失败，安装已中止。${NC}"; return 1; }
        KEYS=$(/usr/local/bin/xray x25519 2>/dev/null || true)
        PRIVATE_KEY=$(printf '%s' "$KEYS" | extract_x25519_private || true)
        PUBLIC_KEY=$(printf '%s'  "$KEYS" | extract_x25519_public || true)
        [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || { echo -e "${RED}  ✗ 生成 Reality x25519 密钥失败，安装已中止。${NC}"; return 1; }
        if [[ "$SCENARIO" == "1" || "$SCENARIO" == "7" ]]; then
            REALITY_DIRECT_UUID=$(/usr/local/bin/xray uuid 2>/dev/null || true)
            [[ -n "$REALITY_DIRECT_UUID" ]] || { echo -e "${RED}  ✗ 生成 Reality UUID 失败，安装已中止。${NC}"; return 1; }
            local idx
            for idx in $(seq 1 "$REALITY_LANDING_COUNT"); do
                local one_uuid
                one_uuid=$(/usr/local/bin/xray uuid 2>/dev/null || true)
                [[ -n "$one_uuid" ]] || { echo -e "${RED}  ✗ 生成第 ${idx} 个落地 UUID 失败，安装已中止。${NC}"; return 1; }
                REALITY_LANDING_UUIDS+=("$one_uuid")
            done
        else
            UUID=$(/usr/local/bin/xray uuid 2>/dev/null || true)
            [[ -n "$UUID" ]] || { echo -e "${RED}  ✗ 生成 Reality UUID 失败，安装已中止。${NC}"; return 1; }
        fi
    fi

    if [[ "$SCENARIO" == "3" || "$SCENARIO" == "4" || "$SCENARIO" == "6" || "$SCENARIO" == "8" ]]; then
        UUID=$(/usr/local/bin/xray uuid 2>/dev/null || true)
        [[ -n "$UUID" ]] || { echo -e "${RED}  ✗ 生成 Vless-Enc UUID 失败，安装已中止。${NC}"; return 1; }
    fi

    if [[ "$SCENARIO" == "2" || "$SCENARIO" == "4" || "$SCENARIO" == "5" ]]; then
        if [[ "$SS_PORT_SOURCE" == "manual" ]]; then
            while is_port_in_use "$MANUAL_SS_PORT" || [[ "$MANUAL_SS_PORT" == "$PORT" ]]; do
                echo -e "${RED}  端口 ${MANUAL_SS_PORT} 已被占用或与 Reality 冲突。${NC}"
                MANUAL_SS_PORT=$(read_manual_ss_port "请重新输入 SS2022 端口: ")
            done
            LOCAL_SS_PORT="$MANUAL_SS_PORT"
        else
            LOCAL_SS_PORT=$(pick_random_free_port_excluding "$PORT") || { echo -e "${RED}  ✗ 无法选出可用的随机高位 SS2022 端口。${NC}"; return 1; }
        fi
        if [[ "$LOCAL_SS_METHOD" == *"256"* ]]; then
            LOCAL_SS_PWD=$(openssl rand -base64 32 | tr -d '\n')
        else
            LOCAL_SS_PWD=$(openssl rand -base64 16 | tr -d '\n')
        fi
    fi

    if [[ "$SCENARIO" == "3" || "$SCENARIO" == "4" || "$SCENARIO" == "6" || "$SCENARIO" == "8" ]]; then
        if [[ "$ENC_PORT_SOURCE" == "manual" ]]; then
            while is_port_in_use "$MANUAL_ENC_PORT" || [[ "$MANUAL_ENC_PORT" == "$PORT" || "$MANUAL_ENC_PORT" == "$LOCAL_SS_PORT" ]]; do
                echo -e "${RED}  端口 ${MANUAL_ENC_PORT} 已被占用或与现有端口冲突。${NC}"
                MANUAL_ENC_PORT=$(read_manual_ss_port "请重新输入 Vless-Enc 端口: ")
            done
            LOCAL_ENC_PORT="$MANUAL_ENC_PORT"
        else
            LOCAL_ENC_PORT=$(pick_random_free_port_excluding "$PORT" "$LOCAL_SS_PORT") || { echo -e "${RED}  ✗ 无法为 Vless-Enc 选出可用的随机高位端口。${NC}"; return 1; }
        fi
        VLESSENC_PAIR_RAW=$(get_vlessenc_pair_from_xray "$ENC_AUTH_METHOD" || true)
        [[ -n "$VLESSENC_PAIR_RAW" ]] || { echo -e "${RED}  ✗ 调用 xray vlessenc 生成 Vless-Enc 参数失败。${NC}"; return 1; }
        VLESS_ENC_DECRYPTION_BASE=${VLESSENC_PAIR_RAW%%$'\t'*}
        VLESS_ENC_ENCRYPTION_BASE=${VLESSENC_PAIR_RAW#*$'\t'}
        [[ -n "$VLESS_ENC_DECRYPTION_BASE" && -n "$VLESS_ENC_ENCRYPTION_BASE" ]] || { echo -e "${RED}  ✗ 解析 xray vlessenc 输出失败。${NC}"; return 1; }
        VLESS_ENC_DECRYPTION=$(rewrite_vlessenc_block2_block3 "$VLESS_ENC_DECRYPTION_BASE" "$ENC_SHAPE_MODE" "$ENC_TICKET_WINDOW") || { echo -e "${RED}  ✗ 重写服务端 Vless-Enc 参数失败。${NC}"; return 1; }
        VLESS_ENC_ENCRYPTION=$(rewrite_vlessenc_block2_block3 "$VLESS_ENC_ENCRYPTION_BASE" "$ENC_SHAPE_MODE" "$ENC_RTT_MODE") || { echo -e "${RED}  ✗ 重写客户端 Vless-Enc 参数失败。${NC}"; return 1; }
        if [[ "$ENC_PADDING_PROFILE" != "custom" ]]; then
            ENC_PADDING_CLIENT=$(get_vlessenc_padding_profile_for_side "$ENC_PADDING_PROFILE" "client")
            ENC_PADDING_SERVER=$(get_vlessenc_padding_profile_for_side "$ENC_PADDING_PROFILE" "server")
        fi
        if [[ -n "$ENC_PADDING_CLIENT" ]]; then
            VLESS_ENC_ENCRYPTION=$(rewrite_vlessenc_padding_profile "$VLESS_ENC_ENCRYPTION" "$ENC_PADDING_CLIENT") || { echo -e "${RED}  ✗ 写入客户端 Vless-Enc padding / delay 失败。${NC}"; return 1; }
        fi
        if [[ -n "$ENC_PADDING_SERVER" ]]; then
            VLESS_ENC_DECRYPTION=$(rewrite_vlessenc_padding_profile "$VLESS_ENC_DECRYPTION" "$ENC_PADDING_SERVER") || { echo -e "${RED}  ✗ 写入服务端 Vless-Enc padding / delay 失败。${NC}"; return 1; }
        fi
    fi

    if [[ "$SCENARIO" == "1" && "$REALITY_LANDING_COUNT" -gt 0 ]] || [[ "$SCENARIO" == "7" && "$REALITY_LANDING_COUNT" -gt 0 ]]; then
        local idx
        for idx in $(seq 1 "$REALITY_LANDING_COUNT"); do
            build_outbound_from_link "${LANDING_LINKS[$((idx-1))]}" "landing${idx}" || { echo -e "${RED}  ✗ 解析第 ${idx} 个落地链接失败，请检查格式。${NC}"; return 1; }
            print_parsed_outbound_preview
            LANDING_JSONS+=("$PARSED_OUTBOUND_JSON")
            LANDING_LABELS+=("$PARSED_LINK_LABEL")
            LANDING_TAGS+=("landing${idx}")
        done
    elif [[ "$SCENARIO" == "5" || "$SCENARIO" == "6" ]]; then
        build_outbound_from_link "${LANDING_LINKS[0]}" "landing" || { echo -e "${RED}  ✗ 解析落地 / 传导链接失败，请检查格式。${NC}"; return 1; }
        print_parsed_outbound_preview
        LANDING_JSONS=("$PARSED_OUTBOUND_JSON")
        LANDING_LABELS=("$PARSED_LINK_LABEL")
        LANDING_TAGS=("landing")
    fi

    echo -e "${GREEN}  ✓ 端口、密钥与模板参数已准备完成${NC}"

    echo -e "\n${CYAN}[Step 7/7] 写入配置并启动服务${NC}"
    render_install_context "$TEMPLATE_LABEL" "$INSTALL_MODE"
    ensure_runtime_layout
    mkdir -p "$CONFIG_DIR"
    rm -rf -- "$XHTTP_PATCH_DIR" >/dev/null 2>&1 || true
    backup_existing_config || { echo -e "${RED}  旧配置备份失败，安装已中止。${NC}"; return 1; }

    local OUTBOUND_JSON
    OUTBOUND_JSON='{
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "'"${FREEDOM_DOMAIN_STRATEGY}"'"
      }
    }'

    local INBOUNDS_JSON=""
    local OUTBOUNDS_JSON=""
    local ALLOW_RULES_JSON=""
    local COMMON_RULES_JSON
    local SUBS_TEXT=""
    local PORTS_TEXT=""
    local SERVER_IP_RAW="" SERVER_IP_URI="" SERVER_IP_URI_V6="" SERVER_IP_V4="" SERVER_IP_V6=""
    local REALITY_LINK_V6="" VLESS_ENC_LINK_V6="" SS_NODE_LINK_V6=""
    local VLESS_LINK="" VLESS_ENC_LINK="" SS_NODE_LINK=""
    local VLESS_ENC_ENCRYPTION_URI=""
    local XHTTP_UP_IP_RAW="" XHTTP_UP_IP_URI="" XHTTP_DOWN_IP_RAW=""
    local -a XHTTP_PATCH_FILES=()
    local -a XHTTP_PATCH_LABELS=()
    local -a XHTTP_PATCH_JSONS=()
    local -a XHTTP_ENTRY_LINKS=()

    COMMON_RULES_JSON=$(get_common_block_rules_json)

    SERVER_IP_V4=$(get_public_ip_v4 || true)
    SERVER_IP_V6=$(get_public_ip_v6 || true)
    if [[ -n "$SERVER_IP_V4" ]]; then
        SERVER_IP_RAW="$SERVER_IP_V4"
    elif [[ -n "$SERVER_IP_V6" ]]; then
        SERVER_IP_RAW="$SERVER_IP_V6"
    fi
    if [[ -z "$SERVER_IP_RAW" ]]; then
        read -r -p "请输入本机公网 IP/域名: " SERVER_IP_RAW
    fi
    [[ -n "$SERVER_IP_RAW" ]] || { echo -e "${RED}  未提供服务器地址，安装中止。${NC}"; return 1; }
    SERVER_IP_URI=$(format_host_for_uri "$SERVER_IP_RAW")
    if [[ -n "$SERVER_IP_V6" ]]; then
        SERVER_IP_URI_V6=$(format_host_for_uri "$SERVER_IP_V6")
    fi

    if [[ "$SCENARIO" == "7" || "$SCENARIO" == "8" ]]; then
        [[ -n "$SERVER_IP_V4" && -n "$SERVER_IP_V6" ]] || { echo -e "${RED}  ✗ 未检测到双栈公网，无法生成 XHTTP 分离链路客户端配置。${NC}"; return 1; }
        case "$XHTTP_SPLIT_DIRECTION" in
            v6_up_v4_down)
                XHTTP_UP_IP_RAW="$SERVER_IP_V6"
                XHTTP_DOWN_IP_RAW="$SERVER_IP_V4"
                ;;
            v4_up_v6_down)
                XHTTP_UP_IP_RAW="$SERVER_IP_V4"
                XHTTP_DOWN_IP_RAW="$SERVER_IP_V6"
                ;;
        esac
        XHTTP_UP_IP_URI=$(format_host_for_uri "$XHTTP_UP_IP_RAW")
    fi

    if [[ "$SCENARIO" == "1" || "$SCENARIO" == "4" ]]; then
        if [[ "$SCENARIO" == "1" ]]; then
            VLESS_LINK="vless://${REALITY_DIRECT_UUID}@${SERVER_IP_URI}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=firefox&type=raw&flow=xtls-rprx-vision&sni=${DEST}&sid=${SHORT_ID}#Reality-直出-zdd"
            if [[ -n "$SERVER_IP_URI_V6" ]]; then
                REALITY_LINK_V6="vless://${REALITY_DIRECT_UUID}@${SERVER_IP_URI_V6}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=firefox&type=raw&flow=xtls-rprx-vision&sni=${DEST}&sid=${SHORT_ID}#Reality-直出-IPv6-zdd"
            fi
        else
            VLESS_LINK="vless://${UUID}@${SERVER_IP_URI}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=firefox&type=raw&flow=xtls-rprx-vision&sni=${DEST}&sid=${SHORT_ID}#Reality-zdd"
            if [[ -n "$SERVER_IP_URI_V6" ]]; then
                REALITY_LINK_V6="vless://${UUID}@${SERVER_IP_URI_V6}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=firefox&type=raw&flow=xtls-rprx-vision&sni=${DEST}&sid=${SHORT_ID}#Reality-IPv6-zdd"
            fi
        fi
    fi
    if [[ "$SCENARIO" == "3" || "$SCENARIO" == "4" || "$SCENARIO" == "6" ]]; then
        VLESS_ENC_ENCRYPTION_URI=$(url_encode "$VLESS_ENC_ENCRYPTION")
        VLESS_ENC_LINK="vless://${UUID}@${SERVER_IP_URI}:${LOCAL_ENC_PORT}?encryption=${VLESS_ENC_ENCRYPTION_URI}&flow=xtls-rprx-vision&headerType=none&type=tcp#Vless-Enc-zdd"
        if [[ -n "$SERVER_IP_URI_V6" ]]; then
            VLESS_ENC_LINK_V6="vless://${UUID}@${SERVER_IP_URI_V6}:${LOCAL_ENC_PORT}?encryption=${VLESS_ENC_ENCRYPTION_URI}&flow=xtls-rprx-vision&headerType=none&type=tcp#Vless-Enc-IPv6-zdd"
        fi
    fi
    if [[ "$SCENARIO" == "2" || "$SCENARIO" == "4" || "$SCENARIO" == "5" ]]; then
        local SS_USERINFO
        SS_USERINFO=$(base64_encode_urlsafe_nopad "${LOCAL_SS_METHOD}:${LOCAL_SS_PWD}")
        SS_NODE_LINK="ss://${SS_USERINFO}@${SERVER_IP_URI}:${LOCAL_SS_PORT}#SS-zdd"
    fi

    case "$SCENARIO" in
        1)
            local REALITY_CLIENTS_JSON=""
            local REALITY_OUTBOUNDS_JSON=""
            local REALITY_RULES_JSON=""
            REALITY_CLIENTS_JSON=$(cat <<EOF
          {
            "id": "${REALITY_DIRECT_UUID}",
            "flow": "xtls-rprx-vision",
            "email": "reality_direct"
          }
EOF
)
            REALITY_RULES_JSON=$(cat <<'EOF'
      {
        "type": "field",
        "inboundTag": ["in-reality"],
        "user": ["reality_direct"],
        "network": "tcp,udp",
        "outboundTag": "direct"
      },
EOF
)
            if [[ "$REALITY_LANDING_COUNT" -gt 0 ]]; then
                local idx
                for idx in $(seq 1 "$REALITY_LANDING_COUNT"); do
                    REALITY_CLIENTS_JSON+=$(cat <<EOF
,
          {
            "id": "${REALITY_LANDING_UUIDS[$((idx-1))]}",
            "flow": "xtls-rprx-vision",
            "email": "reality_landing_${idx}"
          }
EOF
)
                    REALITY_OUTBOUNDS_JSON+=$(printf '%s,\n' "${LANDING_JSONS[$((idx-1))]}")
                    REALITY_RULES_JSON+=$(cat <<EOF
      {
        "type": "field",
        "inboundTag": ["in-reality"],
        "user": ["reality_landing_${idx}"],
        "network": "tcp,udp",
        "outboundTag": "landing${idx}"
      },
EOF
)
                    REALITY_LANDING_LINKS+=("vless://${REALITY_LANDING_UUIDS[$((idx-1))]}@${SERVER_IP_URI}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=firefox&type=raw&flow=xtls-rprx-vision&sni=${DEST}&sid=${SHORT_ID}#Reality-落地${idx}-zdd")
                    if [[ -n "$SERVER_IP_URI_V6" ]]; then
                        REALITY_LANDING_LINKS_V6+=("vless://${REALITY_LANDING_UUIDS[$((idx-1))]}@${SERVER_IP_URI_V6}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=firefox&type=raw&flow=xtls-rprx-vision&sni=${DEST}&sid=${SHORT_ID}#Reality-落地${idx}-IPv6-zdd")
                    fi
                done
            fi
            INBOUNDS_JSON=$(cat <<EOF
    {
      "tag": "in-reality",
      "listen": "::",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
${REALITY_CLIENTS_JSON}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}:443",
          "serverNames": ["${DEST}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      }
    }
EOF
)
            OUTBOUNDS_JSON=$(cat <<EOF
    ${OUTBOUND_JSON},
${REALITY_OUTBOUNDS_JSON}    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
EOF
)
            ALLOW_RULES_JSON="$REALITY_RULES_JSON"
            SUBS_TEXT=$(cat <<EOF
当前架构:
  - 入口: Reality
  - 直出: freedom / ${FREEDOM_DESC}
  - 落地数量: ${REALITY_LANDING_COUNT}

订阅:
  REALITY（直出入口）:
  ${VLESS_LINK}
EOF
)
            if [[ -n "$REALITY_LINK_V6" ]]; then
                SUBS_TEXT+=$(cat <<EOF

  REALITY（直出入口 / IPv6）:
  ${REALITY_LINK_V6}
EOF
)
            fi
            if [[ "$REALITY_LANDING_COUNT" -gt 0 ]]; then
                local idx
                for idx in $(seq 1 "$REALITY_LANDING_COUNT"); do
                    SUBS_TEXT+=$(cat <<EOF

  REALITY（落地入口 ${idx}）:
  ${REALITY_LANDING_LINKS[$((idx-1))]}
EOF
)
                    if [[ ${#REALITY_LANDING_LINKS_V6[@]} -ge ${idx} ]]; then
                        SUBS_TEXT+=$(cat <<EOF

  REALITY（落地入口 ${idx} / IPv6）:
  ${REALITY_LANDING_LINKS_V6[$((idx-1))]}
EOF
)
                    fi
                done
                SUBS_TEXT+="\n\n说明:"
                SUBS_TEXT+="\n  - 直出入口: 命中 reality_direct 用户，服务端直接出站"
                for idx in $(seq 1 "$REALITY_LANDING_COUNT"); do
                    SUBS_TEXT+="\n  - 落地入口 ${idx}: 命中 reality_landing_${idx} 用户，服务端转发到 ${LANDING_LABELS[$((idx-1))]}"
                    SUBS_TEXT+="\n    落地原始链接 ${idx}: ${LANDING_LINKS[$((idx-1))]}"
                done
            fi
            PORTS_TEXT=$(cat <<EOF
端口:
  REALITY:     ${PORT}

出站说明:
  直出出口:    freedom / ${FREEDOM_DESC}
EOF
)
            if [[ "$REALITY_LANDING_COUNT" -gt 0 ]]; then
                local idx
                for idx in $(seq 1 "$REALITY_LANDING_COUNT"); do
                    PORTS_TEXT+=$(cat <<EOF
  落地出口 ${idx}:  ${LANDING_LABELS[$((idx-1))]}
EOF
)
                done
            fi
            ;;
        2)
            INBOUNDS_JSON=$(cat <<EOF
    {
      "tag": "in-ss",
      "listen": "::",
      "port": ${LOCAL_SS_PORT},
      "protocol": "shadowsocks",
      "settings": {
        "method": "${LOCAL_SS_METHOD}",
        "password": "${LOCAL_SS_PWD}",
        "network": "tcp,udp"
      }
    }
EOF
)
            OUTBOUNDS_JSON=$(cat <<EOF
    ${OUTBOUND_JSON},
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
EOF
)
            ALLOW_RULES_JSON=$(cat <<'EOF'
      {
        "type": "field",
        "inboundTag": ["in-ss"],
        "network": "tcp,udp",
        "outboundTag": "direct"
      },
EOF
)
            SUBS_TEXT=$(cat <<EOF
当前架构:
  - 入口: SS2022
  - 出口: freedom / ${FREEDOM_DESC}

订阅:
  SS2022（直出）:
  ${SS_NODE_LINK}
EOF
)
            if [[ -n "$SS_NODE_LINK_V6" ]]; then
                SUBS_TEXT+=$(cat <<EOF

  SS2022（直出 / IPv6）:
  ${SS_NODE_LINK_V6}
EOF
)
            fi
            PORTS_TEXT=$(cat <<EOF
端口:
  SS2022:      ${LOCAL_SS_PORT}
EOF
)
            ;;
        3)
            INBOUNDS_JSON=$(cat <<EOF
    {
      "tag": "in-enc",
      "listen": "::",
      "port": ${LOCAL_ENC_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "enc_user"
          }
        ],
        "decryption": "${VLESS_ENC_DECRYPTION}"
      },
      "streamSettings": {
        "network": "tcp"
      }
    }
EOF
)
            OUTBOUNDS_JSON=$(cat <<EOF
    ${OUTBOUND_JSON},
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
EOF
)
            ALLOW_RULES_JSON=$(cat <<'EOF'
      {
        "type": "field",
        "inboundTag": ["in-enc"],
        "network": "tcp,udp",
        "outboundTag": "direct"
      },
EOF
)
            SUBS_TEXT=$(cat <<EOF
当前架构:
  - 入口: Vless-Enc
  - 出口: freedom / ${FREEDOM_DESC}

订阅:
  Vless-Enc（直出）:
  ${VLESS_ENC_LINK}
EOF
)
            if [[ -n "$VLESS_ENC_LINK_V6" ]]; then
                SUBS_TEXT+=$(cat <<EOF

  Vless-Enc（直出 / IPv6）:
  ${VLESS_ENC_LINK_V6}
EOF
)
            fi
            SUBS_TEXT+=$(cat <<EOF

说明:
  - 客户端实验性 padding / delay: ${ENC_PADDING_PROFILE_DESC}
EOF
)
            if [[ -n "$ENC_PADDING_CLIENT" ]]; then
                SUBS_TEXT+=$(cat <<EOF
  - 客户端实际规则: ${ENC_PADDING_CLIENT}
  - 服务端实际规则: ${ENC_PADDING_SERVER}
EOF
)
            fi
            PORTS_TEXT=$(cat <<EOF
端口:
  Vless-Enc:   ${LOCAL_ENC_PORT}
EOF
)
            ;;
        4)
            INBOUNDS_JSON=$(cat <<EOF
    {
      "tag": "in-reality",
      "listen": "::",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "reality_user"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}:443",
          "serverNames": ["${DEST}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      }
    },
    {
      "tag": "in-enc",
      "listen": "::",
      "port": ${LOCAL_ENC_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "enc_user"
          }
        ],
        "decryption": "${VLESS_ENC_DECRYPTION}"
      },
      "streamSettings": {
        "network": "tcp"
      }
    },
    {
      "tag": "in-ss",
      "listen": "::",
      "port": ${LOCAL_SS_PORT},
      "protocol": "shadowsocks",
      "settings": {
        "method": "${LOCAL_SS_METHOD}",
        "password": "${LOCAL_SS_PWD}",
        "network": "tcp,udp"
      }
    }
EOF
)
            OUTBOUNDS_JSON=$(cat <<EOF
    ${OUTBOUND_JSON},
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
EOF
)
            ALLOW_RULES_JSON=$(cat <<'EOF'
      {
        "type": "field",
        "inboundTag": [
          "in-reality",
          "in-enc",
          "in-ss"
        ],
        "network": "tcp,udp",
        "outboundTag": "direct"
      },
EOF
)
            SUBS_TEXT=$(cat <<EOF
当前架构:
  - 入口: Reality + Vless-Enc + SS2022
  - 出口: freedom / ${FREEDOM_DESC}

订阅:
  REALITY（直出）:
  ${VLESS_LINK}

  Vless-Enc（直出）:
  ${VLESS_ENC_LINK}

  SS2022（直出）:
  ${SS_NODE_LINK}
EOF
)
            if [[ -n "$REALITY_LINK_V6" ]]; then
                SUBS_TEXT+=$(cat <<EOF

  REALITY（直出 / IPv6）:
  ${REALITY_LINK_V6}
EOF
)
            fi
            if [[ -n "$VLESS_ENC_LINK_V6" ]]; then
                SUBS_TEXT+=$(cat <<EOF

  Vless-Enc（直出 / IPv6）:
  ${VLESS_ENC_LINK_V6}
EOF
)
            fi
            if [[ -n "$SS_NODE_LINK_V6" ]]; then
                SUBS_TEXT+=$(cat <<EOF

  SS2022（直出 / IPv6）:
  ${SS_NODE_LINK_V6}
EOF
)
            fi
            SUBS_TEXT+=$(cat <<EOF

说明:
  - Vless-Enc 客户端实验性 padding / delay: ${ENC_PADDING_PROFILE_DESC}
EOF
)
            if [[ -n "$ENC_PADDING_CLIENT" ]]; then
                SUBS_TEXT+=$(cat <<EOF
  - Vless-Enc 客户端实际规则: ${ENC_PADDING_CLIENT}
  - Vless-Enc 服务端实际规则: ${ENC_PADDING_SERVER}
EOF
)
            fi
            PORTS_TEXT=$(cat <<EOF
端口:
  REALITY:     ${PORT}
  Vless-Enc:   ${LOCAL_ENC_PORT}
  SS2022:      ${LOCAL_SS_PORT}
EOF
)
            ;;
        5)
            INBOUNDS_JSON=$(cat <<EOF
    {
      "tag": "in-ss",
      "listen": "::",
      "port": ${LOCAL_SS_PORT},
      "protocol": "shadowsocks",
      "settings": {
        "method": "${LOCAL_SS_METHOD}",
        "password": "${LOCAL_SS_PWD}",
        "network": "tcp,udp"
      }
    }
EOF
)
            OUTBOUNDS_JSON=$(cat <<EOF
    ${OUTBOUND_JSON},
${LANDING_JSONS[0]},
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
EOF
)
            ALLOW_RULES_JSON=$(cat <<'EOF'
      {
        "type": "field",
        "inboundTag": ["in-ss"],
        "network": "tcp,udp",
        "outboundTag": "landing"
      },
EOF
)
            SUBS_TEXT=$(cat <<EOF
当前架构:
  - 入口: SS2022
  - 出口: SS 传导目标

订阅:
  SS2022（传导链入口）:
  ${SS_NODE_LINK}
EOF
)
            if [[ -n "$SS_NODE_LINK_V6" ]]; then
                SUBS_TEXT+=$(cat <<EOF

  SS2022（传导链入口 / IPv6）:
  ${SS_NODE_LINK_V6}
EOF
)
            fi
            SUBS_TEXT+=$(cat <<EOF

说明:
  - 入口协议: SS 入站
  - 出口协议: SS 出站
  - 当前传导目标: ${LANDING_LABELS[0]}
  - 传导原始链接: ${LANDING_LINKS[0]}
EOF
)
            PORTS_TEXT=$(cat <<EOF
端口:
  SS2022:      ${LOCAL_SS_PORT}

出站说明:
  传导方向:    SS 入站 -> SS 出站
  传导目标:    ${LANDING_LABELS[0]}
EOF
)
            ;;
        6)
            INBOUNDS_JSON=$(cat <<EOF
    {
      "tag": "in-enc",
      "listen": "::",
      "port": ${LOCAL_ENC_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "enc_user"
          }
        ],
        "decryption": "${VLESS_ENC_DECRYPTION}"
      },
      "streamSettings": {
        "network": "tcp"
      }
    }
EOF
)
            OUTBOUNDS_JSON=$(cat <<EOF
    ${OUTBOUND_JSON},
${LANDING_JSONS[0]},
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
EOF
)
            ALLOW_RULES_JSON=$(cat <<'EOF'
      {
        "type": "field",
        "inboundTag": ["in-enc"],
        "network": "tcp,udp",
        "outboundTag": "landing"
      },
EOF
)
            SUBS_TEXT=$(cat <<EOF
当前架构:
  - 入口: Vless-Enc
  - 出口: VLESS / Reality / Vless-Enc

订阅:
  Vless-Enc（传导链入口）:
  ${VLESS_ENC_LINK}
EOF
)
            if [[ -n "$VLESS_ENC_LINK_V6" ]]; then
                SUBS_TEXT+=$(cat <<EOF

  Vless-Enc（传导链入口 / IPv6）:
  ${VLESS_ENC_LINK_V6}
EOF
)
            fi
            SUBS_TEXT+=$(cat <<EOF

说明:
  - 入口协议: Vless-Enc 入站
  - 出口协议: VLESS / Reality / Vless-Enc 出站（按你输入的链接决定）
  - 当前传导目标: ${LANDING_LABELS[0]}
  - 传导原始链接: ${LANDING_LINKS[0]}
  - 客户端实验性 padding / delay: ${ENC_PADDING_PROFILE_DESC}
EOF
)
            if [[ -n "$ENC_PADDING_CLIENT" ]]; then
                SUBS_TEXT+=$(cat <<EOF
  - 客户端实际规则: ${ENC_PADDING_CLIENT}
  - 服务端实际规则: ${ENC_PADDING_SERVER}
EOF
)
            fi
            PORTS_TEXT=$(cat <<EOF
端口:
  Vless-Enc:   ${LOCAL_ENC_PORT}

出站说明:
  传导方向:    Vless-Enc 入站 -> VLESS / Reality / Vless-Enc 出站
  传导目标:    ${LANDING_LABELS[0]}
EOF
)
            ;;
        7)
            local XHTTP_REALITY_CLIENTS_JSON=""
            local XHTTP_REALITY_OUTBOUNDS_JSON=""
            local XHTTP_REALITY_RULES_JSON=""
            XHTTP_REALITY_CLIENTS_JSON=$(cat <<EOF
          {
            "id": "${REALITY_DIRECT_UUID}",
            "email": "xhttp_reality_direct"
          }
EOF
)
            XHTTP_REALITY_RULES_JSON=$(cat <<'EOF'
      {
        "type": "field",
        "inboundTag": ["in-xhttp-reality"],
        "user": ["xhttp_reality_direct"],
        "network": "tcp,udp",
        "outboundTag": "direct"
      },
EOF
)
            XHTTP_ENTRY_LINKS+=("vless://${REALITY_DIRECT_UUID}@${XHTTP_UP_IP_URI}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=firefox&type=xhttp&sni=${DEST}&sid=${SHORT_ID}&path=$(url_encode "$XHTTP_PATH")&mode=auto#XHTTP-Reality-$(get_xhttp_split_direction_share_name "$XHTTP_SPLIT_DIRECTION")-直出-zdd")
            XHTTP_PATCH_LABELS+=("XHTTP + Reality 直出入口")
            XHTTP_PATCH_FILES+=("${XHTTP_PATCH_DIR}/xhttp_reality_direct_patch.json")
            write_xhttp_client_patch_file "${XHTTP_PATCH_DIR}/xhttp_reality_direct_patch.json" "$XHTTP_DOWN_IP_RAW" "$PORT" "reality" "${DEST}" "firefox" "$PUBLIC_KEY" "$SHORT_ID" "$XHTTP_PATH"
            XHTTP_PATCH_JSONS+=("$XHTTP_PATCH_LAST_JSON")
            if [[ "$REALITY_LANDING_COUNT" -gt 0 ]]; then
                local idx
                for idx in $(seq 1 "$REALITY_LANDING_COUNT"); do
                    XHTTP_REALITY_CLIENTS_JSON+=$(cat <<EOF
,
          {
            "id": "${REALITY_LANDING_UUIDS[$((idx-1))]}",
            "email": "xhttp_reality_landing_${idx}"
          }
EOF
)
                    XHTTP_REALITY_OUTBOUNDS_JSON+=$(printf '%s,\n' "${LANDING_JSONS[$((idx-1))]}")
                    XHTTP_REALITY_RULES_JSON+=$(cat <<EOF
      {
        "type": "field",
        "inboundTag": ["in-xhttp-reality"],
        "user": ["xhttp_reality_landing_${idx}"],
        "network": "tcp,udp",
        "outboundTag": "landing${idx}"
      },
EOF
)
                    XHTTP_ENTRY_LINKS+=("vless://${REALITY_LANDING_UUIDS[$((idx-1))]}@${XHTTP_UP_IP_URI}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=firefox&type=xhttp&sni=${DEST}&sid=${SHORT_ID}&path=$(url_encode "$XHTTP_PATH")&mode=auto#XHTTP-Reality-$(get_xhttp_split_direction_share_name "$XHTTP_SPLIT_DIRECTION")-落地${idx}-zdd")
                    XHTTP_PATCH_LABELS+=("XHTTP + Reality 落地入口 ${idx}")
                    XHTTP_PATCH_FILES+=("${XHTTP_PATCH_DIR}/xhttp_reality_landing${idx}_patch.json")
                    write_xhttp_client_patch_file "${XHTTP_PATCH_DIR}/xhttp_reality_landing${idx}_patch.json" "$XHTTP_DOWN_IP_RAW" "$PORT" "reality" "${DEST}" "firefox" "$PUBLIC_KEY" "$SHORT_ID" "$XHTTP_PATH"
                    XHTTP_PATCH_JSONS+=("$XHTTP_PATCH_LAST_JSON")
                done
            fi
            INBOUNDS_JSON=$(cat <<EOF
    {
      "tag": "in-xhttp-reality",
      "listen": "::",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
${XHTTP_REALITY_CLIENTS_JSON}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}:443",
          "serverNames": ["${DEST}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        },
        "xhttpSettings": {
          "host": "",
          "path": "${XHTTP_PATH}",
          "mode": "auto"
        }
      }
    }
EOF
)
            OUTBOUNDS_JSON=$(cat <<EOF
    ${OUTBOUND_JSON},
${XHTTP_REALITY_OUTBOUNDS_JSON}    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
EOF
)
            ALLOW_RULES_JSON="$XHTTP_REALITY_RULES_JSON"
            SUBS_TEXT=$(cat <<EOF
当前架构:
  - 入口: XHTTP + Reality
  - 分离方向: ${XHTTP_SPLIT_DESC}
  - 直出: freedom / ${FREEDOM_DESC}
  - 落地数量: ${REALITY_LANDING_COUNT}

订阅:
EOF
)
            local idx2
            for idx2 in "${!XHTTP_ENTRY_LINKS[@]}"; do
                SUBS_TEXT+=$(cat <<EOF
  ${XHTTP_PATCH_LABELS[$idx2]}:
  ${XHTTP_ENTRY_LINKS[$idx2]}

对应客户端 JSON（完整复制，顶左粘贴到 v2rayN 的 XHTTP Extra 原始 JSON）:
${XHTTP_PATCH_JSONS[$idx2]}
EOF
)
                if [[ $idx2 -lt $((${#XHTTP_ENTRY_LINKS[@]}-1)) ]]; then
                    SUBS_TEXT+="\n"
                fi
            done
            SUBS_TEXT+=$(cat <<EOF

说明:
  - 该模板的基础链接仅包含主入口参数，不能单独使用。
  - 需要将上方完整 JSON 顶左粘贴到 v2rayN 的 XHTTP Extra 原始 JSON。
  - 推荐客户端: v2rayN + Xray 内核。其他客户端本脚本不支持自动适配。
  - 当前 XHTTP path: ${XHTTP_PATH}
EOF
)
            if [[ "$REALITY_LANDING_COUNT" -gt 0 ]]; then
                for idx2 in $(seq 1 "$REALITY_LANDING_COUNT"); do
                    SUBS_TEXT+="\n  - 落地入口 ${idx2}: ${LANDING_LABELS[$((idx2-1))]}"
                    SUBS_TEXT+="\n    落地原始链接 ${idx2}: ${LANDING_LINKS[$((idx2-1))]}"
                done
            fi
            PORTS_TEXT=$(cat <<EOF
端口:
  XHTTP + Reality: ${PORT}

出站说明:
  分离方向:    ${XHTTP_SPLIT_DESC}
  直出出口:    freedom / ${FREEDOM_DESC}
  客户端 JSON: 见上方订阅区
EOF
)
            ;;
        8)
            VLESS_ENC_ENCRYPTION_URI=$(url_encode "$VLESS_ENC_ENCRYPTION")
            XHTTP_ENTRY_LINKS+=("vless://${UUID}@${XHTTP_UP_IP_URI}:${LOCAL_ENC_PORT}?encryption=${VLESS_ENC_ENCRYPTION_URI}&flow=xtls-rprx-vision&headerType=none&type=xhttp&path=$(url_encode "$XHTTP_PATH")&mode=auto#XHTTP-Vless-Enc-$(get_xhttp_split_direction_share_name "$XHTTP_SPLIT_DIRECTION")-实验-zdd")
            XHTTP_PATCH_LABELS+=("XHTTP + Vless-Enc 实验入口")
            XHTTP_PATCH_FILES+=("${XHTTP_PATCH_DIR}/xhttp_vlessenc_patch.json")
            write_xhttp_client_patch_file "${XHTTP_PATCH_DIR}/xhttp_vlessenc_patch.json" "$XHTTP_DOWN_IP_RAW" "$LOCAL_ENC_PORT" "none" "" "" "" "" "$XHTTP_PATH"
            XHTTP_PATCH_JSONS+=("$XHTTP_PATCH_LAST_JSON")
            INBOUNDS_JSON=$(cat <<EOF
    {
      "tag": "in-xhttp-enc",
      "listen": "::",
      "port": ${LOCAL_ENC_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "xhttp_enc_user"
          }
        ],
        "decryption": "${VLESS_ENC_DECRYPTION}"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "host": "",
          "path": "${XHTTP_PATH}",
          "mode": "auto"
        }
      }
    }
EOF
)
            OUTBOUNDS_JSON=$(cat <<EOF
    ${OUTBOUND_JSON},
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
EOF
)
            ALLOW_RULES_JSON=$(cat <<'EOF'
      {
        "type": "field",
        "inboundTag": ["in-xhttp-enc"],
        "network": "tcp,udp",
        "outboundTag": "direct"
      },
EOF
)
            SUBS_TEXT=$(cat <<EOF
当前架构:
  - 入口: XHTTP + Vless-Enc（实验性）
  - 分离方向: ${XHTTP_SPLIT_DESC}
  - 出口: freedom / ${FREEDOM_DESC}

订阅:
  XHTTP + Vless-Enc（实验入口）:
  ${XHTTP_ENTRY_LINKS[0]}

对应客户端 JSON（完整复制，顶左粘贴到 v2rayN 的 XHTTP Extra 原始 JSON）:
${XHTTP_PATCH_JSONS[0]}

说明:
  - 警告：该模板无 TLS / 无 Reality，仅适合实验研究，不建议在高风险公网环境使用。
  - 推荐客户端: v2rayN + Xray 内核。其他客户端本脚本不支持自动适配。
  - 上面的 JSON 需要完整复制，并顶左粘贴到对应节点的 XHTTP Extra 原始 JSON；不能只导入基础链接。
  - 当前 XHTTP path: ${XHTTP_PATH}
  - 客户端实验性 padding / delay: ${ENC_PADDING_PROFILE_DESC}
EOF
)
            if [[ -n "$ENC_PADDING_CLIENT" ]]; then
                SUBS_TEXT+=$(cat <<EOF
  - 客户端实际规则: ${ENC_PADDING_CLIENT}
  - 服务端实际规则: ${ENC_PADDING_SERVER}
EOF
)
            fi
            PORTS_TEXT=$(cat <<EOF
端口:
  XHTTP + Vless-Enc: ${LOCAL_ENC_PORT}

出站说明:
  分离方向:    ${XHTTP_SPLIT_DESC}
  直出出口:    freedom / ${FREEDOM_DESC}
  客户端 JSON: 见上方订阅区
EOF
)
            ;;
    esac

    local TEMP_CONFIG
    TEMP_CONFIG=$(mktemp /tmp/xray_config.XXXXXX.json)
    add_tmp_file "$TEMP_CONFIG"

    cat > "$TEMP_CONFIG" <<JSONEOF
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "inbounds": [
${INBOUNDS_JSON}
  ],
  "outbounds": [
${OUTBOUNDS_JSON}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
${COMMON_RULES_JSON}
${ALLOW_RULES_JSON}
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "blocked"
      }
    ]
  }
}
JSONEOF

    echo -e "${YELLOW}  验证配置文件...${NC}"
    if ! /usr/local/bin/xray run -test -config "$TEMP_CONFIG"; then
        cp -f -- "$TEMP_CONFIG" "${DATA_DIR}/last_failed_config.json" 2>/dev/null || true
        echo -e "${RED}  ✗ 配置文件验证失败！${NC}"
        echo -e "${YELLOW}  已保留失败配置: ${DATA_DIR}/last_failed_config.json${NC}"
        echo -e "${YELLOW}  当前运行中的旧配置未被覆盖。${NC}"
        return 1
    fi
    echo -e "${GREEN}  ✓ 配置文件语法验证通过${NC}"

    cp -f -- "$TEMP_CONFIG" "$CONFIG_FILE" || return 1

    systemctl enable xray >/dev/null 2>&1 || true
    systemctl restart xray

    local check_attempt=0
    while [[ $check_attempt -lt 5 ]]; do
        sleep 2
        if systemctl is-active --quiet xray; then
            break
        fi
        check_attempt=$((check_attempt + 1))
        echo -e "${YELLOW}  等待服务启动... (${check_attempt}/5)${NC}"
    done

    if ! systemctl is-active --quiet xray; then
        echo -e "${RED}  Xray 服务启动失败！请查看日志：journalctl -u xray -n 50 --no-pager${NC}"
        return 1
    fi
    echo -e "${GREEN}  ✓ Xray 服务已启动${NC}"

    case "$SCENARIO" in
        1|4) detect_xray_bind_warnings "$PORT" "$LOCAL_SS_PORT"; [[ -n "$LOCAL_ENC_PORT" ]] && { ss -ltnup | grep -q ":${LOCAL_ENC_PORT}" && echo -e "${GREEN}  ✓ 已检测到 ${LOCAL_ENC_PORT} 端口监听${NC}" || echo -e "${YELLOW}  ⚠ 请手动检查：ss -ltnup | grep :${LOCAL_ENC_PORT}${NC}"; } ;;
        2|5) detect_xray_bind_warnings "$LOCAL_SS_PORT" "$LOCAL_SS_PORT" ;;
        3|6|8) ss -ltnup | grep -q ":${LOCAL_ENC_PORT}" && echo -e "${GREEN}  ✓ 已检测到 ${LOCAL_ENC_PORT} 端口监听${NC}" || echo -e "${YELLOW}  ⚠ 请手动检查：ss -ltnup | grep :${LOCAL_ENC_PORT}${NC}" ;;
        7) ss -ltnup | grep -q ":${PORT}" && echo -e "${GREEN}  ✓ 已检测到 ${PORT} 端口监听${NC}" || echo -e "${YELLOW}  ⚠ 请手动检查：ss -ltnup | grep :${PORT}${NC}" ;;
    esac

    write_dynamic_result_files "$SUBS_TEXT" "$PORTS_TEXT"
    write_install_runtime_kind "xray"
    render_saved_node_info "配置完成" || { echo -e "${RED}  节点信息写入失败，请检查 ${INFO_FILE}${NC}"; return 1; }
}


function install_default_flow() {
    if is_alpine_system; then
        echo -e "${YELLOW}  检测到当前为 Alpine / OpenRC，已自动转到 10 号 Alpine 专用 SS2022 流程。${NC}"
        install_alpine_ss2022
    else
        install_xray
    fi
}

function run_quick_install_entry() {
    if is_alpine_system; then
        echo -e "${YELLOW}检测到 Alpine / OpenRC，快速安装将自动转到 10 号 Alpine 专用 SS2022 流程。${NC}"
        if is_quick_install_noninteractive; then
            echo -e "${RED}当前为非交互快速安装，但 Alpine 专用 SS2022 需要你手动选择端口和加密方式。${NC}"
            echo -e "${YELLOW}请改用交互终端运行本地脚本，或先进入主菜单后执行 10 号 Alpine 专用流程。${NC}"
            return 1
        fi
        install_alpine_ss2022
    else
        install_xray
    fi
}

function update_current_service() {
    if is_alpine_runtime_present || is_alpine_system; then
        update_alpine_ssservice
    else
        update_xray
    fi
}

function restart_current_service() {
    if is_alpine_runtime_present || is_alpine_system; then
        restart_alpine_ssservice
    else
        restart_xray
    fi
}

function show_runtime_status() {
    if is_alpine_runtime_present || is_alpine_system; then
        show_alpine_ss_status
    else
        show_status
    fi
}

function edit_runtime_config() {
    if is_alpine_runtime_present || is_alpine_system; then
        edit_alpine_ss_config
    else
        edit_config
    fi
}

function should_auto_confirm_uninstall() {
    [[ "$QUICK_UNINSTALL" == "1" ]]
}

function uninstall_current_service_and_delete_self() {
    if is_alpine_runtime_present || is_alpine_system; then
        uninstall_alpine_ss_and_delete_self
    else
        uninstall_xray_and_delete_self
    fi
}

function update_xray() {
    ensure_systemd_supported || return 1
    line
    echo -e "${YELLOW}  更新 Xray 核心程序...${NC}"

    local update_log
    local update_ret
    update_log=$(mktemp /tmp/xray-update.XXXXXX.log)
    add_tmp_file "$update_log"

    set +o pipefail
    download_and_run_xray_installer install 2>&1 | tee "$update_log"
    update_ret=${PIPESTATUS[0]}
    set -o pipefail

    if [[ $update_ret -ne 0 ]]; then
        echo -e "${RED}更新失败！请检查网络后重试。${NC}"
        line
        return 1
    fi

    if [[ ! -x /usr/local/bin/xray ]]; then
        echo -e "${RED}更新失败：未找到 /usr/local/bin/xray${NC}"
        line
        return 1
    fi

    if grep -Fqi "No new version" "$update_log"; then
        echo -e "${GREEN}  ✓ 当前已是最新版本：$(/usr/local/bin/xray version | head -1)${NC}"
        echo -e "${YELLOW}  未检测到新版本，本次不执行重启。${NC}"
        line
        return 0
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}  未找到配置文件，跳过服务重启。${NC}"
        echo -e "${GREEN}  ✓ 核心已更新。当前版本: $(/usr/local/bin/xray version | head -1)${NC}"
        line
        return 0
    fi

    echo -e "${YELLOW}  先验证当前配置文件...${NC}"
    if ! /usr/local/bin/xray run -test -config "$CONFIG_FILE"; then
        cp -f -- "$CONFIG_FILE" "${DATA_DIR}/last_failed_config.json" 2>/dev/null || true
        echo -e "${YELLOW}  ⚠ 核心已更新，但当前配置文件验证失败，未执行重启。${NC}"
        echo -e "${YELLOW}  请先检查配置：${CONFIG_FILE}${NC}"
        echo -e "${YELLOW}  已保留失败配置: ${DATA_DIR}/last_failed_config.json${NC}"
        echo -e "${YELLOW}  当前运行中的旧服务未被重启。${NC}"
        line
        return 1
    fi

    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}  ✓ 更新成功并已重启！当前版本: $(/usr/local/bin/xray version | head -1)${NC}"
    else
        echo -e "${RED}  ✗ 核心已更新，但服务启动失败，请查看: journalctl -u xray -n 30 --no-pager${NC}"
    fi
    line
}

function restart_xray() {
    ensure_systemd_supported || return 1
    line
    echo -e "${YELLOW}  重启 Xray 服务...${NC}"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}  ✗ 未找到配置文件：${CONFIG_FILE}${NC}"
        line
        return 1
    fi

    echo -e "${YELLOW}  先验证当前配置文件...${NC}"
    if ! /usr/local/bin/xray run -test -config "$CONFIG_FILE"; then
        cp -f -- "$CONFIG_FILE" "${DATA_DIR}/last_failed_config.json" 2>/dev/null || true
        echo -e "${RED}  ✗ 当前配置文件验证失败，已取消重启。${NC}"
        echo -e "${YELLOW}  请先检查配置：${CONFIG_FILE}${NC}"
        echo -e "${YELLOW}  已保留失败配置: ${DATA_DIR}/last_failed_config.json${NC}"
        echo -e "${YELLOW}  当前运行中的旧服务未被改动。${NC}"
        line
        return 1
    fi

    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}  ✓ Xray 服务已重启，运行正常。${NC}"
    else
        echo -e "${RED}  ✗ 重启失败，请查看: journalctl -u xray -n 30 --no-pager${NC}"
    fi
    line
}


function show_info() {
    if render_saved_node_info "节点信息"; then
        return 0
    fi

    if [[ -f "$SUB_FILE" ]]; then
        line
        center_echo "节点信息" "${GREEN}${BOLD}"
        line
        echo -e "${YELLOW}  未找到 ${INFO_FILE}${NC}"
        print_quick_command
        print_saved_txt_files
        line
        return 0
    fi

    echo -e "${RED}未找到节点信息文件，请先执行安装。${NC}"
    return 1
}


function show_status() {
    ensure_systemd_supported || return 1
    line
    center_echo "Xray 服务状态" "${CYAN}${BOLD}"
    line
    systemctl status xray --no-pager -l || true
    echo ""
    center_echo "最新日志（最近 30 行）" "${CYAN}${BOLD}"
    journalctl -u xray -n 30 --no-pager || true
    line
}

function edit_config() {
    while true; do
        line
        center_echo "修改配置文件" "${CYAN}${BOLD}"
        line
        echo -e "${CYAN}  路径: ${CONFIG_FILE}${NC}"
        echo -e "${YELLOW}  仅建议熟悉 Xray 配置者使用。${NC}"
        echo ""
        echo -e "  ${CYAN}1.${NC} 编辑当前配置"
        echo -e "  ${CYAN}2.${NC} 清空配置（高风险）"
        echo -e "  ${CYAN}0.${NC} 返回主菜单"
        line
        read -r -p "选择 [0/1/2]: " EDIT_CHOICE

        if [[ ! -f "$CONFIG_FILE" ]]; then
            echo -e "${RED}  未找到配置文件，请先执行安装。${NC}"
            line
            return 1
        fi

        case "$EDIT_CHOICE" in
            1|01)
                echo ""
                if [[ -n "${EDITOR:-}" ]] && command -v "${EDITOR}" >/dev/null 2>&1; then
                    "${EDITOR}" "$CONFIG_FILE"
                elif command -v nano >/dev/null 2>&1; then
                    nano "$CONFIG_FILE"
                elif command -v vim >/dev/null 2>&1; then
                    vim "$CONFIG_FILE"
                elif command -v vi >/dev/null 2>&1; then
                    vi "$CONFIG_FILE"
                else
                    echo -e "${RED}  未找到可用编辑器（nano/vim/vi）。${NC}"
                    line
                    return 1
                fi

                echo ""
                echo -e "${YELLOW}  已退出编辑器。请回主菜单执行“重启 Xray 服务”。${NC}"
                line
                return 0
                ;;
            2|02)
                echo ""
                echo -e "${RED}${BOLD}  此操作会将当前配置清空为 0 字节。${NC}"
                echo -e "${YELLOW}  清空前会自动备份。${NC}"
                echo -e "${YELLOW}  未重新写入合法 JSON 前，Xray 无法重启。${NC}"
                read -r -p "输入 yes 确认清空 ${CONFIG_FILE}: " CONFIRM_CLEAR
                if [[ "$CONFIRM_CLEAR" != "yes" ]]; then
                    echo -e "${YELLOW}  已取消。${NC}"
                    sleep 1
                    continue
                fi

                local manual_backup
                manual_backup="${CONFIG_FILE}.bak.manual-clear.$(date +%Y%m%d-%H%M%S)"
                cp -a -- "$CONFIG_FILE" "$manual_backup" || {
                    echo -e "${RED}  备份失败，已取消清空。${NC}"
                    line
                    return 1
                }

                truncate -s 0 "$CONFIG_FILE" || {
                    echo -e "${RED}  清空失败，请手动检查权限或磁盘状态。${NC}"
                    line
                    return 1
                }

                echo -e "${GREEN}  ✓ 配置文件已清空。${NC}"
                echo -e "${CYAN}  备份文件: ${manual_backup}${NC}"
                echo -e "${YELLOW}  请先写入合法配置，再执行“重启 Xray 服务”。${NC}"
                line
                return 0
                ;;
            "")
                continue
                ;;
            0|00)
                return 0
                ;;
            *)
                echo -e "${RED}  无效输入，请输入 0、1 或 2。${NC}"
                sleep 1
                ;;
        esac
    done
}

function run_syscheck() {
    line
    center_echo "系统环境检测" "${CYAN}${BOLD}"
    line
    if is_alpine_system; then
        check_timesync_alpine || true
    else
        check_timesync || true
    fi
    echo ""
    check_bbr || true
    line
}

function remove_path_quiet() {
    local path="$1"
    local label="$2"

    if [[ -e "$path" || -L "$path" ]]; then
        if rm -rf -- "$path"; then
            echo -e "${GREEN}  ✓ 已删除: ${label}${NC}"
        else
            echo -e "${YELLOW}  ⚠ 删除失败: ${label}${NC}"
        fi
    fi
}

function cleanup_xray_artifacts() {
    echo -e "${YELLOW}  清理 Xray 残留...${NC}"

    remove_path_quiet "/usr/local/bin/xray" "/usr/local/bin/xray"
    remove_path_quiet "/usr/local/share/xray" "/usr/local/share/xray"
    remove_path_quiet "/usr/local/etc/xray" "/usr/local/etc/xray"
    remove_path_quiet "/var/log/xray" "/var/log/xray"
    remove_path_quiet "/var/lib/xray" "/var/lib/xray"
    remove_path_quiet "/run/xray" "/run/xray"
    remove_path_quiet "/etc/systemd/system/xray.service" "/etc/systemd/system/xray.service"
    remove_path_quiet "/etc/systemd/system/xray@.service" "/etc/systemd/system/xray@.service"
    remove_path_quiet "/etc/systemd/system/xray.service.d" "/etc/systemd/system/xray.service.d"
    remove_path_quiet "/etc/systemd/system/xray@.service.d" "/etc/systemd/system/xray@.service.d"
    remove_path_quiet "/etc/systemd/system/multi-user.target.wants/xray.service" "/etc/systemd/system/multi-user.target.wants/xray.service"
    remove_path_quiet "/etc/systemd/system/multi-user.target.wants/xray@.service" "/etc/systemd/system/multi-user.target.wants/xray@.service"

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true
}

function cleanup_doudou_runtime() {
    echo -e "${YELLOW}  清理脚本自身文件...${NC}"

    remove_path_quiet "$INFO_FILE" "$INFO_FILE"
    remove_path_quiet "$SUB_FILE" "$SUB_FILE"
    remove_path_quiet "$SERVICE_KIND_FILE" "$SERVICE_KIND_FILE"
    remove_path_quiet "$ALPINE_RESOLV_BACKUP" "$ALPINE_RESOLV_BACKUP"
    remove_path_quiet "$SNI_POOL_FILE" "$SNI_POOL_FILE"
    remove_path_quiet "$SYSCTL_BBR_FILE" "$SYSCTL_BBR_FILE"
    remove_path_quiet "$QUICK_BIN" "$QUICK_BIN"
    remove_path_quiet "$LEGACY_QUICK_BIN" "$LEGACY_QUICK_BIN"
    remove_path_quiet "$SELF_DIR" "$SELF_DIR"
    remove_path_quiet "$DATA_DIR" "$DATA_DIR"
}

function cleanup_script_only_runtime() {
    echo -e "${YELLOW}  清理脚本自身文件...${NC}"

    remove_path_quiet "$INFO_FILE" "$INFO_FILE"
    remove_path_quiet "$SUB_FILE" "$SUB_FILE"
    remove_path_quiet "$SERVICE_KIND_FILE" "$SERVICE_KIND_FILE"
    remove_path_quiet "$ALPINE_RESOLV_BACKUP" "$ALPINE_RESOLV_BACKUP"
    remove_path_quiet "$SNI_POOL_FILE" "$SNI_POOL_FILE"
    remove_path_quiet "$SYSCTL_BBR_FILE" "$SYSCTL_BBR_FILE"
    remove_path_quiet "$QUICK_BIN" "$QUICK_BIN"
    remove_path_quiet "$LEGACY_QUICK_BIN" "$LEGACY_QUICK_BIN"
    remove_path_quiet "$SELF_DIR" "$SELF_DIR"
    remove_path_quiet "$DATA_DIR" "$DATA_DIR"
}

function uninstall_script_only() {
    line
    center_echo "仅卸载脚本" "${RED}${BOLD}"
    line
    echo -e "${RED}  - 删除快捷指令 zdd${NC}"
    echo -e "${RED}  - 删除本脚本存储目录、生成的 txt 文件与脚本写入项${NC}"
    echo -e "${RED}  - 保留当前服务、配置与相关残留${NC}"
    line
    if ! ask_yes_no "是否仅卸载脚本并保留当前服务与配置"; then
        echo -e "${YELLOW}已取消。${NC}"
        return 0
    fi

    cleanup_script_only_runtime

    echo -e "${GREEN}  ✓ 脚本已卸载，当前服务已保留。${NC}"
    line
    exit 0
}

function uninstall_xray_and_delete_self() {
    line
    center_echo "卸载脚本和 Xray" "${RED}${BOLD}"
    line
    echo -e "${RED}  - 卸载 Xray${NC}"
    echo -e "${RED}  - 删除配置、服务文件与常见残留${NC}"
    echo -e "${RED}  - 删除快捷指令 zdd${NC}"
    echo -e "${RED}  - 删除本脚本存储目录与生成的 txt 文件${NC}"
    line
    if should_auto_confirm_uninstall; then
        echo -e "${YELLOW}  检测到快捷完整卸载：已自动确认继续。${NC}"
    else
        read -r -p "输入 yes 继续: " CONFIRM
        if [[ "$CONFIRM" != "yes" ]]; then
            echo -e "${YELLOW}已取消。${NC}"
            return 0
        fi
    fi

    echo -e "${YELLOW}  停止并禁用 Xray 服务...${NC}"
    systemctl stop xray >/dev/null 2>&1 || true
    systemctl disable xray >/dev/null 2>&1 || true

    echo -e "${YELLOW}  调用官方卸载脚本...${NC}"
    if ! download_and_run_xray_installer remove; then
        echo -e "${YELLOW}  ⚠ 官方卸载未完成，继续执行本地兜底清理。${NC}"
    fi

    cleanup_xray_artifacts
    cleanup_doudou_runtime

    echo -e "${GREEN}  ✓ 卸载与清理已完成。${NC}"
    line
    exit 0
}

function uninstall_menu() {
    while true; do
        line
        center_echo "卸载 脚本 Xray SS-Rust" "${RED}${BOLD}"
        line
        echo -e "  ${CYAN}1.${NC} 仅卸载脚本"
        echo -e "  ${CYAN}2.${NC} 卸载 脚本 Xray SS-Rust"
        echo -e "  ${CYAN}0.${NC} 返回主菜单"
        line
        read -r -p "选择 [0/1/2]: " UNINSTALL_CHOICE

        case "$UNINSTALL_CHOICE" in
            "")
                continue
                ;;
            1|01)
                uninstall_script_only
                ;;
            2|02)
                uninstall_current_service_and_delete_self
                ;;
            0|00)
                return 0
                ;;
            *)
                echo -e "${RED}  无效输入，请输入 0、1 或 2。${NC}"
                sleep 1
                ;;
        esac
    done
}

if [[ "$QUICK_INSTALL" == "1" ]]; then
    run_quick_install_entry
    exit $?
fi

if [[ "$QUICK_UNINSTALL" == "1" ]]; then
    uninstall_current_service_and_delete_self
    exit $?
fi

while true; do
    clear_screen
    line
    echo -e "  ${GREEN}${BOLD}Xray 一键管理脚本 ${SCRIPT_VERSION}${NC}"
    echo -e "  ${GREEN}${BRAND_HEADER}${NC}"
    echo -e "  ${YELLOW}警告！SS 和 Vless-Enc 不适合过墙${NC}"
    echo -e "  ${YELLOW}警告！Vless-Enc 手动模式的 padding 为实验性更推荐默认不填${NC}"
    echo -e "  Reality 默认端口 443 手动模式增加 8443"
    echo -e "  SS 默认加密 2022-blake3-aes-128-gcm 手动模式增加 256-gcm"
    echo -e "  Vless-Enc 默认 xorpub 0rtt x25519 手动模式可换并加 padding"
    echo -e "  SNI测速 + 时间同步 + BBR+FQ + Vless-Enc"
    echo -e "  快捷调用可输入: zdd xray | zdd install | zdd uninstall"
    line
    echo -e "  ${CYAN}01.${NC} 覆盖安装"
    echo -e "  ${CYAN}02.${NC} 更新 Xray"
    echo -e "  ${CYAN}03.${NC} 重启 Xray"
    echo -e "  ${CYAN}04.${NC} 查看订阅链接"
    echo -e "  ${CYAN}05.${NC} 查看状态 & 日志"
    echo -e "  ${CYAN}06.${NC} SNI 管理 & 测速"
    echo -e "  ${CYAN}07.${NC} 环境检测（时间 & BBR）"
    echo -e "  ${CYAN}08.${NC} 修改 Xray 配置（退出后重启服务生效）"
    echo -e "  ${CYAN}09.${NC} 卸载 Xray 脚本等文件（可单独卸载脚本）"
    echo -e "  ${CYAN}10.${NC} Alpine 专用 SS2022（shadowsocks-rust）"
    echo -e "  ${CYAN}00.${NC} 退出脚本"
    line
    read -r -p "选择: " CHOICE

    case "$CHOICE" in
        "")
            continue
            ;;
        1|01) install_default_flow    ;;
        2|02) update_current_service  ;;
        3|03) restart_current_service ;;
        4|04) show_info               ;;
        5|05) show_runtime_status     ;;
        6|06) manage_sni              ;;
        7|07) run_syscheck            ;;
        8|08) edit_runtime_config     ;;
        9|09) uninstall_menu          ;;
        10)   install_alpine_ss2022   ;;
        0|00)
            echo -e "${GREEN}已退出。${NC}"
            sleep 0.3
            clear_screen
            exit 0
            ;;
        *) echo -e "${RED}无效输入，请重新选择。${NC}"; sleep 1; continue ;;
    esac

    echo ""
    read -r -p "按 Enter 返回主菜单..." _
done
