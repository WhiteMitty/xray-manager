#!/bin/bash

set -u
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BRIGHT_YELLOW='\033[1;93m'
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
SOURCE_RECORD_FILE="${SELF_DIR}/source-record"
SCRIPT_REMOTE_URL="https://raw.githubusercontent.com/WhiteMitty/xray-manager/main/xray-manager.sh"
QUICK_BIN="/usr/local/bin/zxray"
LEGACY_QUICK_BIN="/usr/local/bin/zdd"
INFO_FILE="${DATA_DIR}/xray_node_info.txt"
SUB_FILE="${DATA_DIR}/xray_subscription.txt"
CONFIG_FILE="/usr/local/etc/xray/config.json"
CONFIG_DIR="/usr/local/etc/xray"
SNI_POOL_FILE="${DATA_DIR}/.xray_sni_pool"
SYSCTL_BBR_FILE="/etc/sysctl.d/99-bbr.conf"
SYSCTL_BBR_BACKUP_FILE="${DATA_DIR}/sysctl_99-bbr.conf.original"
XHTTP_PATCH_DIR="${DATA_DIR}/xhttp_patches"
DEFAULT_PORT=443
REALITY_GATE_PORT=4431
REALITY_GATE_RULES_JSON=""
TMP_FILES=()
BEST_DEST=""
BEST_DEST_POOL_SIG=""
SNI_POOL_SOURCE="default"
QUICK_INSTALL=0
QUICK_UNINSTALL=0
QUICK_UPDATE=0
QUICK_FORCE=0
QUICK_SCENARIO=""
SERVICE_KIND_FILE="${DATA_DIR}/.install_kind"
ALPINE_SS_CONFIG_DIR="/etc/shadowsocks-rust"
ALPINE_SS_CONFIG_FILE="${ALPINE_SS_CONFIG_DIR}/ssserver.json"
ALPINE_SS_SERVICE_FILE="/etc/init.d/ssserver"
ALPINE_XRAY_SERVICE_FILE="/etc/init.d/xray"
ALPINE_RESOLV_BACKUP="${DATA_DIR}/alpine_resolv.conf.bak"

DEFAULT_DEST_OPTIONS=(
    "c.6sc.co"
    "www.aws.com"
    "www.amd.com"
    "www.sony.com"
    "www.tesla.com"
    "www.intel.com"
    "www.adobe.com"
    "www.amazon.com"
    "drivers.amd.com"
    "a0.awsstatic.com"
    "d1.awsstatic.com"
    "s0.awsstatic.com"
    "gateway.icloud.com"
    "m.media-amazon.com"
    "addons.mozilla.org"
    "tag.demandbase.com"
    "t0.m.awsstatic.com"
    "s.company-target.com"
    "images-na.ssl-images-amazon.com"
    "i7158c100-ds-aksb-a.akamaihd.net"
)

function line() {
    local linebuf
    printf -v linebuf '%*s' "$UI_WIDTH" ''
    echo -e "${GREEN}${linebuf// /-}${NC}"
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

function record_source_file() {
    local source_path="${1:-}"
    local source_dir=""
    local source_base=""
    local source_sha=""
    local record_tmp=""

    [[ -n "$source_path" ]] || return 0
    case "$source_path" in
        /proc/*|/dev/*|/tmp/doudou-entry.*.sh)
            return 0
            ;;
    esac
    [[ -f "$source_path" && ! -L "$source_path" ]] || return 0

    if [[ "$source_path" != /* ]]; then
        source_dir=$(cd -- "$(dirname -- "$source_path")" 2>/dev/null && pwd -P) || return 0
        source_base=$(basename -- "$source_path" 2>/dev/null || true)
        [[ -n "$source_base" ]] || return 0
        source_path="${source_dir}/${source_base}"
    fi

    [[ "$source_path" != "$SELF_SCRIPT_PATH" ]] || return 0
    command -v sha256sum >/dev/null 2>&1 || return 0
    source_sha=$(sha256sum -- "$source_path" 2>/dev/null | awk 'NR==1 {print $1}')
    [[ "$source_sha" =~ ^[0-9a-fA-F]{64}$ ]] || return 0

    record_tmp="${SOURCE_RECORD_FILE}.new.$$"
    if ! (
        umask 077
        printf '%s\n%s\n' "$source_path" "${source_sha,,}" > "$record_tmp"
    ); then
        rm -f -- "$record_tmp" >/dev/null 2>&1 || true
        return 1
    fi
    chmod 600 "$record_tmp" >/dev/null 2>&1 || true
    mv -f -- "$record_tmp" "$SOURCE_RECORD_FILE" 2>/dev/null || {
        rm -f -- "$record_tmp" >/dev/null 2>&1 || true
        return 1
    }
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
        if [[ "$current_path" != "$SELF_SCRIPT_PATH" ]]; then
            record_source_file "$current_path" >/dev/null 2>&1 || true
        fi
    fi

    local legacy_path
    for legacy_path in \
        "$LEGACY_QUICK_BIN" "/usr/local/bin/doudou" "/usr/local/bin/xray-manager" \
        "/usr/bin/zxray" "/usr/bin/zdd" "/usr/bin/doudou" "/usr/bin/xray-manager" \
        "/usr/sbin/zxray" "/usr/sbin/zdd" "/usr/sbin/doudou" "/usr/sbin/xray-manager" \
        "/root/bin/zxray" "/root/bin/zdd" "/root/bin/doudou" "/root/bin/xray-manager" \
        "/root/.local/bin/zxray" "/root/.local/bin/zdd" "/root/.local/bin/doudou" "/root/.local/bin/xray-manager"; do
        rm -f -- "$legacy_path" >/dev/null 2>&1 || true
    done

    cat > "$QUICK_BIN" <<EOF
#!/bin/bash
set -u

    if [[ \$# -eq 0 ]]; then
        exec "$SELF_SCRIPT_PATH"
    fi

    echo "用法: zxray"
    exit 1
EOF
    chmod 755 "$QUICK_BIN" >/dev/null 2>&1 || true
}

function download_latest_script_to() {
    local target_path="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$target_path" "$SCRIPT_REMOTE_URL" || return 1
        return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -qO "$target_path" "$SCRIPT_REMOTE_URL" || return 1
        return 0
    fi

    echo -e "${RED}错误：未检测到 curl 或 wget，无法拉取最新脚本。${NC}"
    return 1
}

function self_update_and_update_xray() {
    line
    echo -e "${YELLOW}  正在拉取最新脚本并覆盖当前版本...${NC}"

    local temp_script=""
    temp_script=$(mktemp /tmp/doudou-self-update.XXXXXX.sh) || {
        echo -e "${RED}  ✗ 无法创建临时更新文件。${NC}"
        line
        return 1
    }
    add_tmp_file "$temp_script"

    if ! download_latest_script_to "$temp_script"; then
        echo -e "${RED}  ✗ 最新脚本拉取失败，请检查网络后重试。${NC}"
        line
        return 1
    fi

    if ! grep -q '^#!/bin/bash' "$temp_script"; then
        echo -e "${RED}  ✗ 拉取结果不是有效脚本，已取消覆盖。${NC}"
        line
        return 1
    fi

    ensure_runtime_layout
    if ! mv -f -- "$temp_script" "$SELF_SCRIPT_PATH" 2>/dev/null; then
        if ! cp -f -- "$temp_script" "$SELF_SCRIPT_PATH" 2>/dev/null; then
            echo -e "${RED}  ✗ 覆盖当前脚本失败。${NC}"
            line
            return 1
        fi
        rm -f -- "$temp_script" >/dev/null 2>&1 || true
    fi
    chmod 755 "$SELF_SCRIPT_PATH" >/dev/null 2>&1 || true

    echo -e "${GREEN}  ✓ 脚本已更新到最新版本。${NC}"
    echo -e "${YELLOW}  正在继续更新当前运行组件...${NC}"
    line
    exec env DOUDOU_SELF_UPDATED=1 bash "$SELF_SCRIPT_PATH" --quick-update
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
            --quick-update)
                QUICK_UPDATE=1
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
    local recorded_kind=""
    if [[ -f "$SERVICE_KIND_FILE" ]]; then
        recorded_kind=$(head -n 1 "$SERVICE_KIND_FILE" 2>/dev/null || true)
        case "$recorded_kind" in
            alpine-ss2022|alpine-xray-vlessenc)
                if is_alpine_system; then
                    printf '%s\n' "$recorded_kind"
                    return 0
                fi
                echo -e "${YELLOW}警告：记录的 Alpine 安装类型与当前系统不匹配，将改用实际文件和服务探测。${NC}" >&2
                ;;
            xray)
                if ! is_alpine_system; then
                    printf '%s\n' "$recorded_kind"
                    return 0
                fi
                echo -e "${YELLOW}警告：记录的 systemd Xray 类型与当前 Alpine / OpenRC 系统不匹配，将改用实际文件和服务探测。${NC}" >&2
                ;;
            *)
                echo -e "${YELLOW}警告：检测到无效的安装类型记录，将改用实际文件和服务探测。${NC}" >&2
                ;;
        esac
    fi

    if is_alpine_system && [[ -x "$ALPINE_XRAY_SERVICE_FILE" || ( -x /usr/local/bin/xray && -f "$CONFIG_FILE" ) ]]; then
        printf '%s\n' 'alpine-xray-vlessenc'
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
    case "$(get_install_runtime_kind 2>/dev/null || true)" in
        alpine-ss2022|alpine-xray-vlessenc)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
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
            linebuf=$(printf '%s' "$linebuf" | tr -d '\n')
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

function get_port_listener_details() {
    local port="$1"
    ss -ltnupH 2>/dev/null | awk -v port="$port" '
        $5 ~ ("(^|:|\\])" port "$") { print }
    '
}

function is_port_in_use_by_xray() {
    local port="$1"
    get_port_listener_details "$port" | grep -q 'users:(("xray"'
}

function get_xray_pids_by_port() {
    local port="$1"
    get_port_listener_details "$port" | grep -o 'pid=[0-9]\+' | cut -d= -f2 | sort -u
}

function print_port_listener_details() {
    local port="$1"
    local details=""
    details=$(get_port_listener_details "$port")
    if [[ -n "$details" ]]; then
        echo -e "${CYAN}  端口 ${port} 占用详情:${NC}"
        printf '%s\n' "$details"
    else
        echo -e "${GREEN}  端口 ${port} 当前未检测到监听${NC}"
    fi
}

function stop_alpine_known_service_on_port() {
    local port="$1"
    local details=""
    local pids=""
    local i=""

    details=$(get_port_listener_details "$port")
    [[ -n "$details" ]] || return 0

    if printf '%s\n' "$details" | grep -q 'users:(("xray"'; then
        echo -e "${YELLOW}  检测到端口 ${port} 当前由 xray 占用，正在尝试自动释放...${NC}"
        rc-service xray stop >/dev/null 2>&1 || true
        for i in 1 2 3; do
            sleep 1
            if ! is_port_in_use "$port"; then
                return 0
            fi
        done
        pids=$(get_xray_pids_by_port "$port" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')
        if [[ -n "$pids" ]]; then
            kill $pids >/dev/null 2>&1 || true
            for i in 1 2 3; do
                sleep 1
                if ! is_port_in_use "$port"; then
                    return 0
                fi
            done
        fi
        return 1
    fi

    if printf '%s\n' "$details" | grep -q 'users:(("ssserver"'; then
        echo -e "${YELLOW}  检测到端口 ${port} 当前由 ssserver 占用，正在尝试自动释放...${NC}"
        rc-service ssserver stop >/dev/null 2>&1 || true
        for i in 1 2 3; do
            sleep 1
            if ! is_port_in_use "$port"; then
                return 0
            fi
        done
        pids=$(printf '%s\n' "$details" | grep -o 'pid=[0-9]\+' | cut -d= -f2 | sort -u | tr '\n' ' ' | sed 's/[[:space:]]\+$//')
        if [[ -n "$pids" ]]; then
            kill $pids >/dev/null 2>&1 || true
            for i in 1 2 3; do
                sleep 1
                if ! is_port_in_use "$port"; then
                    return 0
                fi
            done
        fi
        return 1
    fi

    return 1
}

function ensure_alpine_install_port_available() {
    local port="$1"
    local purpose="$2"

    if ! is_port_in_use "$port"; then
        return 0
    fi

    if stop_alpine_known_service_on_port "$port" && ! is_port_in_use "$port"; then
        echo -e "${GREEN}  ✓ 已自动释放端口 ${port}，将用于 ${purpose}${NC}"
        return 0
    fi

    echo -e "${RED}  ✗ 端口 ${port} 已被占用，无法用于 ${purpose} 安装。${NC}"
    print_port_listener_details "$port"
    return 1
}

function show_reality_alternate_port_hint() {
    local port="$1"
    echo -e "${YELLOW}  提示：手动模式可选择任意 1-65535 的未占用 Reality 端口（${REALITY_GATE_PORT} 除外）。当前冲突端口：${port}${NC}"
}

function stop_xray_occupying_port() {
    local port="$1"
    local pids=""
    local i=""

    echo -e "${YELLOW}  检测到端口 ${port} 当前由 xray 占用，正在尝试关闭旧实例...${NC}"
    systemctl stop xray >/dev/null 2>&1 || true

    for i in 1 2 3; do
        sleep 1
        if ! is_port_in_use "$port"; then
            echo -e "${GREEN}  ✓ 已释放端口 ${port}（通过停止 xray 服务）${NC}"
            return 0
        fi
    done

    if is_port_in_use_by_xray "$port"; then
        pids=$(get_xray_pids_by_port "$port" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')
        if [[ -n "$pids" ]]; then
            echo -e "${YELLOW}  systemd 停止后仍检测到残留 xray 进程，正在尝试结束: ${pids}${NC}"
            kill $pids >/dev/null 2>&1 || true
            for i in 1 2 3; do
                sleep 1
                if ! is_port_in_use "$port"; then
                    echo -e "${GREEN}  ✓ 已释放端口 ${port}（已结束残留 xray 进程）${NC}"
                    return 0
                fi
            done
        fi
    fi

    echo -e "${RED}  ✗ 端口 ${port} 仍被占用，无法继续。${NC}"
    print_port_listener_details "$port"
    return 1
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
        echo -e "  ${CYAN}0.${NC} 返回上一步" >&2
        echo -e "  ${CYAN}b.${NC} 返回主菜单" >&2
        read -r -p "选择 [1-2/0/b]，默认 1（1=IPv4 优先 / 2=仅 IPv4）: " ds_choice
        case "${ds_choice:-1}" in
            1|01)
                echo "UseIPv4"
                return 0
                ;;
            2|02)
                echo "ForceIPv4"
                return 0
                ;;
            0|00)
                echo "__BACK__"
                return 0
                ;;
            b|B)
                echo "__MAIN__"
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1、2、0 或 b。${NC}" >&2
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
        if [[ -z "$value" ]]; then
            echo -e "${RED}  SNI 不能为空。${NC}" >&2
            continue
        fi
        if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
            echo -e "${RED}  SNI 仅允许字母、数字、点、下划线和连字符。${NC}" >&2
            continue
        fi
        echo "$value"
        return 0
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
    local port
    while true; do
        echo -e "  ${CYAN}1.${NC} 443（默认）" >&2
        echo -e "  ${CYAN}2.${NC} 自定义端口（1-65535）" >&2
        echo -e "  ${CYAN}0.${NC} 返回上一步" >&2
        echo -e "  ${CYAN}b.${NC} 返回主菜单" >&2
        read -r -p "选择 Reality 端口 [1-2/0/b]，默认 1: " choice
        case "${choice:-1}" in
            1|01)
                echo "443"
                return 0
                ;;
            2|02)
                port=$(read_manual_ss_port "请输入 Reality 端口: ")
                if [[ "$port" == "$REALITY_GATE_PORT" ]]; then
                    echo -e "${RED}  ${REALITY_GATE_PORT} 端口保留给 Reality fallback gate，请换一个端口。${NC}" >&2
                    continue
                fi
                echo "$port"
                return 0
                ;;
            0|00)
                echo "__BACK__"
                return 0
                ;;
            b|B)
                echo "__MAIN__"
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1、2、0 或 b。${NC}" >&2
                ;;
        esac
    done
}

function choose_ss_method() {
    local choice
    while true; do
        echo -e "  ${CYAN}1.${NC} 2022-blake3-aes-128-gcm（默认）" >&2
        echo -e "  ${CYAN}2.${NC} 2022-blake3-aes-256-gcm" >&2
        echo -e "  ${CYAN}0.${NC} 返回上一步" >&2
        echo -e "  ${CYAN}b.${NC} 返回主菜单" >&2
        read -r -p "选择 SS2022 加密方式 [1-2/0/b]，默认 1: " choice
        case "${choice:-1}" in
            1|01)
                echo "2022-blake3-aes-128-gcm"
                return 0
                ;;
            2|02)
                echo "2022-blake3-aes-256-gcm"
                return 0
                ;;
            0|00)
                echo "__BACK__"
                return 0
                ;;
            b|B)
                echo "__MAIN__"
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1、2、0 或 b。${NC}" >&2
                ;;
        esac
    done
}

function choose_reality_landing_count() {
    local choice
    local custom_count
    while true; do
        echo -e "  ${CYAN}1.${NC} 直出（0 个落地）" >&2
        echo -e "  ${CYAN}2.${NC} 输入落地总数（1-10 个）" >&2
        echo -e "  ${CYAN}0.${NC} 返回上一步" >&2
        echo -e "  ${CYAN}b.${NC} 返回主菜单" >&2
        read -r -p "选择 Reality 落地数量 [1-2/0/b]，默认 1: " choice
        case "${choice:-1}" in
            1|01)
                printf '%s' "0"
                return 0
                ;;
            2|02)
                while true; do
                    read -r -p "请输入落地总数 [1-10]: " custom_count
                    if [[ "$custom_count" =~ ^[0-9]+$ ]] && (( custom_count >= 1 && custom_count <= 10 )); then
                        printf '%s' "$custom_count"
                        return 0
                    fi
                    echo -e "${RED}  请输入 1-10 之间的数字。${NC}" >&2
                done
                ;;
            0|00)
                printf '%s' '__BACK__'
                return 0
                ;;
            b|B)
                printf '%s' '__MAIN__'
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1、2、0 或 b。${NC}" >&2
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
        echo -e "  ${CYAN}0.${NC} 返回上一步" >&2
        echo -e "  ${CYAN}b.${NC} 返回主菜单" >&2
        read -r -p "选择实验性 padding / delay 档位 [1-4/0/b]，默认 1: " choice
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
            0|00)
                printf '%s' '__BACK__'
                return 0
                ;;
            b|B)
                printf '%s' '__MAIN__'
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1-4、0 或 b。${NC}" >&2
                ;;
        esac
    done
}

function get_vlessenc_padding_profile_desc() {
    case "$1" in
        off) printf '%s' '默认：不额外追加自定义 padding / delay，保持核心默认行为' ;;
        gentle) printf '%s' '温和：少量 padding + 轻微 delay，主要做轻量长度与节奏扰动' ;;
        aggressive) printf '%s' '激进：更多 padding 段与更大 delay 抖动，伪装更强但更影响时延与稳定性' ;;
        custom) printf '%s' '手动自定义：客户端 / 服务端分别输入规则，适合已理解格式后再改' ;;
        *) printf '%s' '默认：不额外追加自定义 padding / delay，保持核心默认行为' ;;
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
        echo -e "  ${CYAN}0.${NC} 返回上一步" >&2
        echo -e "  ${CYAN}b.${NC} 返回主菜单" >&2
        read -r -p "选择 [1-2/0/b]，默认 1: " choice
        case "${choice:-1}" in
            1|01)
                echo "0rtt"
                return 0
                ;;
            2|02)
                echo "1rtt"
                return 0
                ;;
            0|00)
                echo "__BACK__"
                return 0
                ;;
            b|B)
                echo "__MAIN__"
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1、2、0 或 b。${NC}" >&2
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
        echo -e "  ${CYAN}0.${NC} 返回上一步" >&2
        echo -e "  ${CYAN}b.${NC} 返回主菜单" >&2
        read -r -p "选择 [1-3/0/b]，默认 1: " choice
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
            0|00)
                echo "__BACK__"
                return 0
                ;;
            b|B)
                echo "__MAIN__"
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1、2、3、0 或 b。${NC}" >&2
                ;;
        esac
    done
}

function choose_vlessenc_auth_method() {
    local choice
    while true; do
        echo -e "  ${CYAN}1.${NC} x25519（更短；认证不抗量子）" >&2
        echo -e "  ${CYAN}2.${NC} mlkem768（更长；认证也抗量子）" >&2
        echo -e "  ${CYAN}0.${NC} 返回上一步" >&2
        echo -e "  ${CYAN}b.${NC} 返回主菜单" >&2
        read -r -p "选择 [1-2/0/b]，默认 1: " choice
        case "${choice:-1}" in
            1|01)
                echo "x25519"
                return 0
                ;;
            2|02)
                echo "mlkem768"
                return 0
                ;;
            0|00)
                echo "__BACK__"
                return 0
                ;;
            b|B)
                echo "__MAIN__"
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1、2、0 或 b。${NC}" >&2
                ;;
        esac
    done
}

function url_encode() {
    local value="$1"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$value" | jq -sRr @uri
    else
        local i ch encoded=""
        LC_ALL=C
        for ((i=0; i<${#value}; i++)); do
            ch=${value:i:1}
            case "$ch" in
                [a-zA-Z0-9.~_-])
                    encoded+="$ch"
                    ;;
                *)
                    printf -v ch '%%%02X' "'$ch"
                    encoded+="$ch"
                    ;;
            esac
        done
        printf '%s' "$encoded"
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
        sync_status=$(timedatectl show --property=NTPSynchronized 2>/dev/null | cut -d= -f2 || true)
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
            sync_check=$(timedatectl show --property=NTPSynchronized 2>/dev/null | cut -d= -f2 || true)
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
    if [[ -f "$SYSCTL_BBR_FILE" ]] && ! grep -q '^# BBR + FQ' "$SYSCTL_BBR_FILE"; then
        if [[ ! -f "$SYSCTL_BBR_BACKUP_FILE" ]]; then
            cp -a -- "$SYSCTL_BBR_FILE" "$SYSCTL_BBR_BACKUP_FILE" || {
                echo -e "${RED}  ✗ 无法备份已有 ${SYSCTL_BBR_FILE}，为避免覆盖用户配置，已跳过写入。${NC}"
                return 1
            }
            echo -e "${CYAN}  已备份原有 BBR 配置，卸载时会尝试恢复。${NC}"
        fi
    fi

    if ! cat > "$SYSCTL_BBR_FILE" <<EOF2
# BBR + FQ — 由 Xray 管理脚本自动写入
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF2
    then
        echo -e "${RED}  ✗ 写入 ${SYSCTL_BBR_FILE} 失败。${NC}"
        return 1
    fi

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

function is_alpine_ss_runtime_ready() {
    command -v ssserver >/dev/null 2>&1 && command -v ssservice >/dev/null 2>&1
}

function install_alpine_shadowsocks_rust_package() {
    echo -e "${YELLOW}  安装 shadowsocks-rust 运行组件...${NC}"
    apk add shadowsocks-rust mimalloc || return 1
    return 0
}

function ensure_alpine_ss_runtime_ready() {
    if is_alpine_ss_runtime_ready; then
        return 0
    fi

    echo -e "${YELLOW}  当前未检测到 shadowsocks-rust 运行组件。${NC}"
    if ask_yes_no "  是否现在继续安装 shadowsocks-rust"; then
        install_alpine_shadowsocks_rust_package || return 1
        if is_alpine_ss_runtime_ready; then
            return 0
        fi
        echo -e "${RED}  ✗ 安装后仍未检测到 ssserver / ssservice。${NC}"
        return 1
    fi

    echo -e "${RED}  已取消：SS2022 流程必须依赖 shadowsocks-rust。${NC}"
    return 1
}

function install_alpine_runtime_deps() {
    echo -e "${YELLOW}  安装 Alpine 运行依赖...${NC}"
    apk update || return 1
    apk add curl wget jq openssl coreutils procps ca-certificates iproute2 || return 1

    if is_alpine_ss_runtime_ready; then
        echo -e "${GREEN}  ✓ 已检测到 shadowsocks-rust 运行组件${NC}"
        return 0
    fi

    if install_alpine_shadowsocks_rust_package; then
        echo -e "${GREEN}  ✓ shadowsocks-rust 已安装完成${NC}"
        return 0
    fi

    echo -e "${YELLOW}  ⚠ shadowsocks-rust 安装失败。${NC}"
    if ask_yes_no "  是否继续完成其余环境准备"; then
        return 0
    fi
    return 1
}

function ensure_alpine_shanghai_timezone() {
    echo -e "${YELLOW}  正在设置 Alpine 时区为 Asia/Shanghai...${NC}"
    apk update >/dev/null 2>&1 || true
    apk add tzdata >/dev/null 2>&1 || true

    if [[ -e /usr/share/zoneinfo/Asia/Shanghai ]]; then
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime || true
        printf '%s\n' 'Asia/Shanghai' > /etc/timezone || true
        echo -e "${GREEN}  ✓ 当前时区已设置为 Asia/Shanghai${NC}"
        echo -e "${CYAN}  当前时间: $(date 2>/dev/null || true)${NC}"
        return 0
    fi

    echo -e "${YELLOW}  ⚠ 未找到 Asia/Shanghai 时区文件，跳过时区设置。${NC}"
    return 1
}

function manual_set_alpine_time() {
    local hour=""
    local minute=""
    local current_date=""
    local manual_ts=""
    local manual_log=""

    echo -e "${YELLOW}  现在可按上海时间手动输入时间。${NC}"
    echo -e "${CYAN}  当前时间: $(date 2>/dev/null || true)${NC}"

    while true; do
        read -r -p "请输入小时 [0-23]: " hour
        if [[ "$hour" =~ ^[0-9]+$ ]] && (( hour >= 0 && hour <= 23 )); then
            printf -v hour '%02d' "$hour"
            break
        fi
        echo -e "${RED}  小时必须是 0-23。${NC}"
    done

    while true; do
        read -r -p "请输入分钟 [0-59]: " minute
        if [[ "$minute" =~ ^[0-9]+$ ]] && (( minute >= 0 && minute <= 59 )); then
            printf -v minute '%02d' "$minute"
            break
        fi
        echo -e "${RED}  分钟必须是 0-59。${NC}"
    done

    current_date=$(date +%F 2>/dev/null || true)
    [[ -n "$current_date" ]] || current_date="1970-01-01"
    manual_ts="${current_date} ${hour}:${minute}:00"
    manual_log=$(mktemp /tmp/alpine-manual-time.XXXXXX.log) || {
        echo -e "${RED}  ✗ 无法创建手动校时日志文件。${NC}"
        return 1
    }
    add_tmp_file "$manual_log"

    rc-service chronyd stop >/dev/null 2>&1 || true

    if date -s "$manual_ts" >"$manual_log" 2>&1 || \
       date -s "${current_date} ${hour}:${minute}" >"$manual_log" 2>&1 || \
       { command -v busybox >/dev/null 2>&1 && busybox date -s "$manual_ts" >"$manual_log" 2>&1; }; then
        hwclock -w >/dev/null 2>&1 || true
        rc-service chronyd start >/dev/null 2>&1 || true
        echo -e "${GREEN}  ✓ 已手动设置时间为: $(date 2>/dev/null || true)${NC}"
        return 0
    fi

    cp -f -- "$manual_log" "${DATA_DIR}/last_failed_manual_time.log" 2>/dev/null || true
    echo -e "${RED}  ✗ 手动设置时间失败。${NC}"
    if grep -Eqi 'Operation not permitted|not permitted|settimeofday|can.t set date|Cannot set date' "$manual_log"; then
        echo -e "${YELLOW}  提示：这更像是当前机器 / 虚拟化环境禁止修改系统时间，不是脚本输入格式本身的问题。${NC}"
    else
        echo -e "${YELLOW}  提示：更像是当前机器上的 date / chronyd / 权限状态异常，已保留日志供排查。${NC}"
    fi
    echo -e "${YELLOW}  已保留失败日志: ${DATA_DIR}/last_failed_manual_time.log${NC}"
    rc-service chronyd start >/dev/null 2>&1 || true
    return 1
}

function check_timesync_alpine() {
    echo -e "${YELLOW}  检查 Alpine 时间同步状态...${NC}"
    ensure_alpine_shanghai_timezone || true

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

    if is_stdin_interactive; then
        echo -e "${YELLOW}  一次性临时校时也失败了。${NC}"
        if ask_yes_no "  是否按上海时间手动输入当前时间"; then
            if manual_set_alpine_time; then
                rc-service chronyd restart >/dev/null 2>&1 || true
                return 0
            fi
        fi
    else
        echo -e "${YELLOW}  当前为非交互模式，跳过手动输入时间。${NC}"
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
    cat > "$ALPINE_SS_CONFIG_FILE" <<CFG_EOF || return 1
{
  "server": "::",
  "server_port": ${port},
  "password": "$(json_escape "$password")",
  "method": "$(json_escape "$method")",
  "mode": "tcp_and_udp",
  "timeout": 300
}
CFG_EOF
    chmod 600 "$ALPINE_SS_CONFIG_FILE" || return 1
}

function write_alpine_openrc_service() {
    backup_file_if_exists "$ALPINE_SS_SERVICE_FILE" || return 1
    cat > "$ALPINE_SS_SERVICE_FILE" <<'SERVICE_EOF' || return 1
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
    chmod +x "$ALPINE_SS_SERVICE_FILE" >/dev/null 2>&1 || return 1
    validate_alpine_openrc_service_script "$ALPINE_SS_SERVICE_FILE" "SS2022"
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

    if ! validate_alpine_openrc_service_script "$ALPINE_SS_SERVICE_FILE" "SS2022"; then
        echo -e "${YELLOW}  正在重新生成 SS2022 OpenRC 服务文件...${NC}"
        write_alpine_openrc_service || { line; return 1; }
    fi

    rc-service ssserver restart >/dev/null 2>&1 || rc-service ssserver start >/dev/null 2>&1 || {
        echo -e "${RED}  ✗ SS2022 服务启动失败。${NC}"
        echo -e "${YELLOW}  正在补做一次前台验证，用于区分是配置问题还是 OpenRC / 机器环境问题...${NC}"
        validate_alpine_ssserver_foreground || true
        rc-service ssserver status || true
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
    apk add --upgrade shadowsocks-rust mimalloc curl wget jq openssl coreutils procps ca-certificates iproute2 || {
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
    center_echo "完整卸载 SS2022" "${RED}${BOLD}"
    line
    echo -e "${RED}  - 卸载 shadowsocks-rust（Alpine）${NC}"
    echo -e "${RED}  - 删除 SS2022 配置、服务文件与生成目录${NC}"
    echo -e "${RED}  - 删除 zxray 启动命令${NC}"
    echo -e "${RED}  - 删除脚本源文件、临时文件、日志与 txt 文件${NC}"
    line
    if should_auto_confirm_uninstall; then
        echo -e "${YELLOW}  检测到快捷完整卸载：已自动确认继续。${NC}"
    else
        read -r -p "输入 yes 确认完整卸载: " CONFIRM
        if [[ "$CONFIRM" != "yes" ]]; then
            echo -e "${YELLOW}已取消。${NC}"
            return 0
        fi
    fi

    cleanup_alpine_ss_artifacts
    cleanup_alpine_service_backups

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
${CYAN}[Step 2/7] 检查 Alpine 仓库与依赖${NC}"
    ensure_alpine_community_repo || return 1
    install_alpine_runtime_deps || return 1
    check_bbr || true

    echo -e "
${CYAN}[Step 3/7] 手动选择 SS2022 参数${NC}"
    local ss_method=""
    local ss_port=""
    ss_method=$(choose_ss_method) || return 1
    case "$ss_method" in
        __BACK__|__MAIN__)
            return 0
            ;;
    esac
    while true; do
        ss_port=$(read_manual_ss_port "请输入 SS2022 监听端口: ") || return 1
        ensure_alpine_install_port_available "$ss_port" "Alpine SS2022" || return 1
        break
    done

    echo -e "
${CYAN}[Step 4/7] 生成密钥与写入配置${NC}"
    ensure_alpine_ss_runtime_ready || return 1
    local ss_password=""
    ss_password=$(ssservice genkey -m "$ss_method" 2>/dev/null | tr -d '\n')
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
        echo -e "${CYAN}  建议：先执行覆盖安装选择 Alpine SS2022，或手动安装：apk add openssl coreutils${NC}"
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

    local domain_col_width=40
    local domain_len=0
    local d
    for d in "${DEST_OPTIONS[@]}"; do
        domain_len=${#d}
        if (( domain_len > domain_col_width )); then
            domain_col_width=$domain_len
        fi
    done

    for d in "${DEST_OPTIONS[@]}"; do
        local times=()
        local total=0
        local success=0
        local i

        for i in 1 2 3; do
            local t1 t2 elapsed
            t1=$(date +%s%3N 2>/dev/null || echo 0)
            if timeout 3 openssl s_client                 -connect "${d}:443"                 -servername "${d}"                 -verify_return_error                 </dev/null &>/dev/null; then
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

        local cell1="" cell2="" cell3="" avg_cell=""
        if [[ "$col1" == "超时" ]]; then cell1="   超时"; else printf -v cell1 "%7s" "$col1"; fi
        if [[ "$col2" == "超时" ]]; then cell2="   超时"; else printf -v cell2 "%7s" "$col2"; fi
        if [[ "$col3" == "超时" ]]; then cell3="   超时"; else printf -v cell3 "%7s" "$col3"; fi
        printf -v avg_cell "%8s" "$avg_str"

        if [[ $avg_val -lt $best_avg ]]; then
            best_avg=$avg_val
            BEST_DEST="$d"
            printf "  ${GREEN}%-${domain_col_width}s %s %s %s %s ★${NC}
" "$d" "$cell1" "$cell2" "$cell3" "$avg_cell"
        else
            printf "  %-${domain_col_width}s %s %s %s %s
" "$d" "$cell1" "$cell2" "$cell3" "$avg_cell"
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
    raw_msg=$(tail -n 1 "$err_file" 2>/dev/null | tr -d '\n')

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

function patch_xray_installer_missing_stop() {
    local installer="$1"

    if ! sed -i \
        -e '/^stop_xray()/,/^}/ s/error: Stopping the Xray service failed./warning: Xray service was not loaded; continuing installation./' \
        -e '/^stop_xray()/,/^}/ s/exit 1/return 0/' \
        "$installer"; then
        echo -e "${RED}  ✗ 无法修补 Xray 安装器的旧服务停止处理。${NC}"
        return 1
    fi

    if ! sed -n '/^stop_xray()/,/^}/p' "$installer" | grep -F 'return 0' >/dev/null 2>&1; then
        echo -e "${RED}  ✗ Xray 安装器结构与预期不符，未执行修补。${NC}"
        return 1
    fi
    return 0
}

function run_xray_official_install_with_recovery() {
    local runner="$1"
    local installer="$2"
    local run_log=""
    local installer_ret=1
    local retry_ret=1

    run_log=$(mktemp /tmp/xray-installer-run.XXXXXX.log 2>/dev/null) || true
    if [[ -z "$run_log" ]]; then
        echo -e "${YELLOW}  ⚠ 无法创建安装日志，将直接执行官方安装器。${NC}"
        "$runner" "$installer" install
        return $?
    fi
    add_tmp_file "$run_log"

    set +o pipefail
    "$runner" "$installer" install 2>&1 | tee "$run_log"
    installer_ret=${PIPESTATUS[0]}
    set -o pipefail
    [[ "$installer_ret" -eq 0 ]] && return 0

    if ! grep -Fq 'Unit xray.service not loaded' "$run_log"; then
        return "$installer_ret"
    fi

    echo -e "${YELLOW}  ⚠ 检测到旧版安装器停止未加载的 xray.service，准备兼容重试。${NC}"
    if ! patch_xray_installer_missing_stop "$installer"; then
        return "$installer_ret"
    fi

    : > "$run_log"
    echo -e "${CYAN}  正在跳过不存在的旧服务并重试安装...${NC}"
    set +o pipefail
    "$runner" "$installer" install 2>&1 | tee "$run_log"
    retry_ret=${PIPESTATUS[0]}
    set -o pipefail
    return "$retry_ret"
}

function download_and_run_xray_installer() {
    local action="$1"
    local installer curl_err url max_retry retry sleep_seconds curl_ret runner
    installer=$(mktemp /tmp/xray-install.XXXXXX.sh) || {
        echo -e "${RED}  ✗ 无法创建 Xray 安装临时文件。${NC}"
        return 1
    }
    curl_err=$(mktemp /tmp/xray-install-curl.XXXXXX.log) || {
        rm -f -- "$installer" >/dev/null 2>&1 || true
        echo -e "${RED}  ✗ 无法创建 Xray 安装错误日志临时文件。${NC}"
        return 1
    }
    add_tmp_file "$installer"
    add_tmp_file "$curl_err"

    if is_alpine_system; then
        url="https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh"
        runner="ash"
    else
        url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
        runner="bash"
    fi
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

    if ! grep -Eq '(^#!/.*(sh|ash|bash))|XTLS|Xray-install' "$installer"; then
        echo -e "${RED}  ✗ 下载内容校验失败，已拒绝执行。${NC}"
        echo -e "${YELLOW}    判断：获取到的内容不像官方安装脚本，可能是下载异常、网页错误页或上游临时返回了非脚本内容。${NC}"
        return 1
    fi

    chmod +x "$installer" || return 1

    case "$action" in
        install)
            run_xray_official_install_with_recovery "$runner" "$installer"
            ;;
        remove)
            "$runner" "$installer" remove --purge
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
    center_echo "启动命令: zxray"
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

function normalize_block_spacing() {
    awk '
        NR == 1 {
            print
            prev_blank = ($0 == "")
            next
        }
        {
            is_top = ($0 != "" && $0 !~ /^[[:space:]]/)
            if (is_top && !prev_blank) {
                print ""
            }
            print
            prev_blank = ($0 == "")
        }
    '
}

function write_dynamic_result_files() {
    local sub_text="$1"
    local ports_text="$2"
    local now_time
    local normalized_sub_text=""
    local normalized_ports_text=""
    now_time=$(date '+%Y-%m-%d %H:%M:%S')

    normalized_sub_text=$(printf '%b\n' "$sub_text" | normalize_block_spacing)
    if [[ -n "$ports_text" ]]; then
        normalized_ports_text=$(printf '%b\n' "$ports_text" | normalize_block_spacing)
    fi

    (
        umask 077
        {
            printf '作者    : %s\n' "$AUTHOR_NAME"
            printf '版本    : %s\n' "$SCRIPT_VERSION"
            printf '生成时间: %s\n\n' "$now_time"
            printf '%s\n' "$normalized_sub_text"
            if [[ -n "$normalized_ports_text" ]]; then
                printf '\n%s\n' "$normalized_ports_text"
            fi
        } > "$INFO_FILE"

        {
            printf '作者    : %s\n' "$AUTHOR_NAME"
            printf '版本    : %s\n' "$SCRIPT_VERSION"
            printf '生成时间: %s\n\n' "$now_time"
            printf '%s\n' "$normalized_sub_text"
        } > "$SUB_FILE"
    )

    chmod 600 "$INFO_FILE" "$SUB_FILE" >/dev/null 2>&1 || true
}


function get_install_scenario_label() {
    case "$1" in
        1) printf '%s' 'Reality 直出 / 多落地' ;;
        2) printf '%s' '单 SS 直出' ;;
        3) printf '%s' '单 Vless-Enc 直出' ;;
        4) printf '%s' 'Reality Vless-Enc SS 三入站直出' ;;
        5) printf '%s' '无 TLS 链式（SS 入站）' ;;
        6) printf '%s' '无 TLS 链式（Vless-Enc 入站）' ;;
        7) printf '%s' 'XHTTP + Reality 直出 / 多落地' ;;
        8) printf '%s' 'XHTTP + Vless-Enc 上下行分离（高风险慎用）' ;;
        *) printf '%s' '未知模板' ;;
    esac
}

function choose_unified_chain_entry() {
    local choice
    while true; do
        echo -e "  ${CYAN}1.${NC} SS 入站" >&2
        echo -e "  ${CYAN}2.${NC} Vless-Enc 入站" >&2
        echo -e "  ${CYAN}0.${NC} 返回上一步" >&2
        echo -e "  ${CYAN}b.${NC} 返回主菜单" >&2
        read -r -p "选择无 TLS 链式入口 [1-2/0/b]，默认 1: " choice
        case "${choice:-1}" in
            1|01) printf '%s' 'ss'; return 0 ;;
            2|02) printf '%s' 'vlessenc'; return 0 ;;
            0|00) printf '%s' '__BACK__'; return 0 ;;
            b|B) printf '%s' '__MAIN__'; return 0 ;;
            *) echo -e "${RED}  请输入 1、2、0 或 b。${NC}" >&2 ;;
        esac
    done
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
        echo -e "  ${CYAN}1.${NC} Reality 直出 / 多落地（0-10 个）" >&2
        echo -e "  ${CYAN}2.${NC} 单 SS 直出" >&2
        echo -e "  ${CYAN}3.${NC} 单 Vless-Enc 直出" >&2
        echo -e "  ${CYAN}4.${NC} Reality Vless-Enc SS 三入站直出" >&2
        echo -e "" >&2
        echo -e "${CYAN}  进阶链路:${NC}" >&2
        echo -e "  ${CYAN}5.${NC} XHTTP + Reality 直出 / 多落地（0-10 个）" >&2
        echo -e "  ${CYAN}6.${NC} XHTTP + Vless-Enc 上下行分离（${YELLOW}高风险慎用${NC}）" >&2
        echo -e "  ${CYAN}7.${NC} 无 TLS 链式（SS / Vless-Enc 入站 -> 任意支持的出站，保留直出）" >&2
        echo -e "  ${CYAN}0.${NC} 返回上一步" >&2
        echo -e "  ${CYAN}b.${NC} 返回主菜单" >&2
        line >&2
        read -r -p "选择 [1-7/0/b]: " choice
        case "$choice" in
            1|2|3|4) printf '%s' "$choice"; return 0 ;;
            5|05) printf '%s' '7'; return 0 ;;
            6|06) printf '%s' '8'; return 0 ;;
            7|07)
                local chain_entry=""
                chain_entry=$(choose_unified_chain_entry)
                case "$chain_entry" in
                    ss) printf '%s' '__CHAIN_SS__'; return 0 ;;
                    vlessenc) printf '%s' '__CHAIN_VLESSENC__'; return 0 ;;
                    __BACK__) printf '%s' '__BACK__'; return 0 ;;
                    __MAIN__) printf '%s' '__MAIN__'; return 0 ;;
                esac
                ;;
            0|00) printf '%s' '__BACK__'; return 0 ;;
            b|B) printf '%s' '__MAIN__'; return 0 ;;
            *) echo -e "${RED}  请输入 1-7、0 或 b。${NC}" >&2 ;;
        esac
    done
}

function choose_xhttp_split_direction() {
    local choice
    while true; do
        echo -e "  ${CYAN}1.${NC} v6 去 / v4 回（默认）" >&2
        echo -e "  ${CYAN}2.${NC} v4 去 / v6 回" >&2
        echo -e "  ${CYAN}0.${NC} 返回上一步" >&2
        echo -e "  ${CYAN}b.${NC} 返回主菜单" >&2
        read -r -p "选择 XHTTP 分离方向 [1-2/0/b]，默认 1: " choice
        case "${choice:-1}" in
            1|01)
                printf '%s' 'v6_up_v4_down'
                return 0
                ;;
            2|02)
                printf '%s' 'v4_up_v6_down'
                return 0
                ;;
            0|00)
                printf '%s' '__BACK__'
                return 0
                ;;
            b|B)
                printf '%s' '__MAIN__'
                return 0
                ;;
            *)
                echo -e "${RED}  请输入 1、2、0 或 b。${NC}" >&2
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

function compact_json_inline() {
    local json_text="$1"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json_text" | jq -c . 2>/dev/null || printf '%s' "$json_text" | tr -d '\n'
    else
        printf '%s' "$json_text" | tr -d '\n'
    fi
}

function build_xhttp_reality_full_link() {
    local uuid="$1"
    local up_host_uri="$2"
    local up_port="$3"
    local down_address="$4"
    local down_port="$5"
    local server_name="$6"
    local fingerprint="$7"
    local public_key="$8"
    local short_id="$9"
    local path="${10}"
    local share_name="${11}"
    local extra_json=""
    local extra_compact=""
    local extra_uri=""

    extra_json=$(build_xhttp_client_patch_json "$down_address" "$down_port" "reality" "$server_name" "$fingerprint" "$public_key" "$short_id" "$path") || return 1
    extra_compact=$(compact_json_inline "$extra_json")
    extra_uri=$(url_encode "$extra_compact")
    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=xhttp&path=%s&mode=auto&extra=%s#%s'         "$uuid" "$up_host_uri" "$up_port" "$server_name" "$fingerprint" "$public_key" "$short_id" "$(url_encode "$path")" "$extra_uri" "$(url_encode "$share_name")"
}

function build_xhttp_vlessenc_full_link() {
    local uuid="$1"
    local up_host_uri="$2"
    local up_port="$3"
    local down_address="$4"
    local down_port="$5"
    local enc_value="$6"
    local path="$7"
    local share_name="$8"
    local extra_json=""
    local extra_compact=""
    local extra_uri=""

    extra_json=$(build_xhttp_client_patch_json "$down_address" "$down_port" "none" "" "" "" "" "$path") || return 1
    extra_compact=$(compact_json_inline "$extra_json")
    extra_uri=$(url_encode "$extra_compact")
    printf 'vless://%s@%s:%s?encryption=%s&flow=xtls-rprx-vision&security=none&type=xhttp&path=%s&mode=auto&extra=%s#%s'         "$uuid" "$up_host_uri" "$up_port" "$(url_encode "$enc_value")" "$(url_encode "$path")" "$extra_uri" "$(url_encode "$share_name")"
}

function build_reality_gate_inbound_json() {
    local dest="$1"
    cat <<EOF
    {
      "tag": "reality-target-gate",
      "listen": "127.0.0.1",
      "port": ${REALITY_GATE_PORT},
      "protocol": "dokodemo-door",
      "settings": {
        "address": "$(json_escape "$dest")",
        "port": 443,
        "network": "tcp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["tls"],
        "routeOnly": true
      }
    },
EOF
}

function build_reality_gate_rules_json() {
    local dest="$1"
    cat <<EOF
      {
        "type": "field",
        "inboundTag": ["reality-target-gate"],
        "domain": ["full:$(json_escape "$dest")"],
        "network": "tcp",
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "inboundTag": ["reality-target-gate"],
        "network": "tcp",
        "outboundTag": "blocked"
      },
EOF
}

function precheck_reality_port_before_apply() {
    local scenario="$1"
    local port="$2"

    if [[ "$port" == "$REALITY_GATE_PORT" ]]; then
        echo -e "${RED}  端口 ${port} 已保留给 Reality 防偷 gate，不能作为对外监听端口。${NC}"
        return 1
    fi

    case "$scenario" in
        1|4|7)
            precheck_reusable_xray_port_before_apply "$REALITY_GATE_PORT" "Reality fallback gate" || return 1
            echo -e "${YELLOW}  端口预检...${NC}"

            if ! is_port_in_use "$port"; then
                echo -e "${GREEN}  ✓ Reality 目标端口 ${port} 当前空闲${NC}"
                return 0
            fi

            if is_port_in_use_by_xray "$port"; then
                stop_xray_occupying_port "$port" || {
                    show_reality_alternate_port_hint "$port"
                    return 1
                }
                echo -e "${GREEN}  ✓ Reality 目标端口 ${port} 已可继续使用${NC}"
                return 0
            fi

            echo -e "${RED}  端口 ${port} 已被非 xray 进程占用，安装已中止。${NC}"
            print_port_listener_details "$port"
            show_reality_alternate_port_hint "$port"
            echo -e "${YELLOW}  请先执行：ss -ltnup | grep :${port}${NC}"
            return 1
            ;;
    esac
    return 0
}

function precheck_reusable_xray_port_before_apply() {
    local port="$1"
    local label="$2"

    [[ -n "$port" ]] || return 0

    echo -e "${YELLOW}  端口预检...${NC}"

    if ! is_port_in_use "$port"; then
        echo -e "${GREEN}  ✓ ${label} 目标端口 ${port} 当前空闲${NC}"
        return 0
    fi

    if is_port_in_use_by_xray "$port"; then
        stop_xray_occupying_port "$port" || return 1
        echo -e "${GREEN}  ✓ ${label} 目标端口 ${port} 已可继续使用${NC}"
        return 0
    fi

    echo -e "${RED}  端口 ${port} 已被非 xray 进程占用，安装已中止。${NC}"
    print_port_listener_details "$port"
    echo -e "${YELLOW}  请先执行：ss -ltnup | grep :${port}${NC}"
    return 1
}


function install_alpine_base_deps() {
    echo -e "${YELLOW}  安装 Alpine 基础依赖...${NC}"
    apk update || return 1
    apk add curl wget jq openssl coreutils procps ca-certificates iproute2 || return 1
}

function get_alpine_xray_enc_port_from_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        if command -v jq >/dev/null 2>&1; then
            jq -r '.inbounds[]? | select(.tag=="in-enc") | .port' "$CONFIG_FILE" 2>/dev/null | head -n 1
        else
            awk -F: '/"tag"[[:space:]]*:[[:space:]]*"in-enc"/ {found=1} found && /"port"/ {gsub(/[^0-9]/, "", $2); print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true
        fi
    fi
}

function validate_alpine_openrc_service_script() {
    local service_file="$1"
    local service_label="$2"
    local first_line=""

    if [[ ! -f "$service_file" ]]; then
        echo -e "${RED}  ✗ 未找到 ${service_label} OpenRC 服务文件：${service_file}${NC}"
        return 1
    fi

    if [[ ! -x "$service_file" ]]; then
        echo -e "${RED}  ✗ ${service_label} OpenRC 服务文件不可执行：${service_file}${NC}"
        return 1
    fi

    first_line=$(head -n 1 "$service_file" 2>/dev/null || true)
    if [[ "$first_line" != "#!/sbin/openrc-run" ]]; then
        echo -e "${RED}  ✗ ${service_label} OpenRC 服务文件首行无效，必须是 #!/sbin/openrc-run：${service_file}${NC}"
        return 1
    fi

    return 0
}

function write_alpine_xray_openrc_service() {
    backup_file_if_exists "$ALPINE_XRAY_SERVICE_FILE" || return 1
    cat > "$ALPINE_XRAY_SERVICE_FILE" <<'SERVICE_EOF' || return 1
#!/sbin/openrc-run

name="xray"
description="Xray Service"

command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
}
SERVICE_EOF
    chmod +x "$ALPINE_XRAY_SERVICE_FILE" >/dev/null 2>&1 || return 1
    validate_alpine_openrc_service_script "$ALPINE_XRAY_SERVICE_FILE" "Xray"
}

function choose_alpine_vlessenc_scenario() {
    local choice
    while true; do
        line >&2
        echo -e "${CYAN}${BOLD}  第三层：选择 Alpine Vless-Enc 模板${NC}" >&2
        line >&2
        echo -e "  ${CYAN}1.${NC} 单 Vless-Enc 直出" >&2
        echo -e "  ${CYAN}2.${NC} Vless-Enc 传导链（Vless-Enc 入站 -> VLESS 系出站）" >&2
        echo -e "  ${CYAN}0.${NC} 返回上一步" >&2
        echo -e "  ${CYAN}b.${NC} 返回主菜单" >&2
        line >&2
        read -r -p "选择 [1/2/0/b]: " choice
        case "$choice" in
            1|01) printf '%s' '3'; return 0 ;;
            2|02) printf '%s' '6'; return 0 ;;
            0|00) printf '%s' '__BACK__'; return 0 ;;
            b|B) printf '%s' '__MAIN__'; return 0 ;;
            *) echo -e "${RED}  请输入 1、2、0 或 b。${NC}" >&2 ;;
        esac
    done
}

function restart_alpine_xray_service() {
    line
    echo -e "${YELLOW}  重启 Alpine Xray（Vless-Enc）服务...${NC}"
    ensure_alpine_supported || return 1

    if [[ ! -x /usr/local/bin/xray ]]; then
        echo -e "${RED}  ✗ 未找到 /usr/local/bin/xray${NC}"
        line
        return 1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}  ✗ 未找到配置文件：${CONFIG_FILE}${NC}"
        line
        return 1
    fi

    if ! /usr/local/bin/xray run -test -config "$CONFIG_FILE"; then
        echo -e "${RED}  ✗ 当前配置验证失败，已取消重启。${NC}"
        line
        return 1
    fi

    if ! validate_alpine_openrc_service_script "$ALPINE_XRAY_SERVICE_FILE" "Xray"; then
        echo -e "${YELLOW}  正在重新生成 Xray OpenRC 服务文件...${NC}"
        write_alpine_xray_openrc_service || { line; return 1; }
    fi

    rc-update add xray default >/dev/null 2>&1 || true
    rc-service xray restart >/dev/null 2>&1 || rc-service xray start >/dev/null 2>&1 || {
        echo -e "${RED}  ✗ Alpine Xray 服务启动失败。${NC}"
        rc-service xray status || true
        line
        return 1
    }

    local check_attempt=0
    while [[ $check_attempt -lt 5 ]]; do
        sleep 2
        if rc-service xray status >/dev/null 2>&1; then
            break
        fi
        check_attempt=$((check_attempt + 1))
        echo -e "${YELLOW}  等待服务启动... (${check_attempt}/5)${NC}"
    done

    if ! rc-service xray status >/dev/null 2>&1; then
        echo -e "${RED}  Alpine Xray 服务启动失败！${NC}"
        rc-service xray status || true
        echo -e "${YELLOW}  可继续手动排查：/usr/local/bin/xray run -config ${CONFIG_FILE}${NC}"
        line
        return 1
    fi

    echo -e "${GREEN}  ✓ Alpine Xray 服务已启动${NC}"

    local listen_port=""
    listen_port=$(get_alpine_xray_enc_port_from_config)
    if [[ -n "$listen_port" ]]; then
        if ss -ltnup 2>/dev/null | grep -q ":${listen_port}\b"; then
            echo -e "${GREEN}  ✓ 已检测到 ${listen_port} 端口监听${NC}"
        else
            echo -e "${YELLOW}  ⚠ 未明确检测到 ${listen_port} 端口监听，请手动检查：ss -ltnup | grep :${listen_port}${NC}"
        fi
    fi
    line
}

function update_alpine_xray_service() {
    line
    echo -e "${YELLOW}  更新 Alpine Xray（Vless-Enc）...${NC}"
    ensure_alpine_supported || return 1
    ensure_alpine_community_repo || { line; return 1; }
    install_alpine_base_deps || { line; return 1; }

    echo -e "${YELLOW}  安装 / 更新 Xray 核心程序...${NC}"
    download_and_run_xray_installer install || {
        echo -e "${RED}  ✗ Xray 更新失败，请检查网络后重试。${NC}"
        line
        return 1
    }

    if [[ ! -x /usr/local/bin/xray ]]; then
        echo -e "${RED}  ✗ 更新失败：未找到 /usr/local/bin/xray${NC}"
        line
        return 1
    fi

    echo -e "${GREEN}  ✓ $(/usr/local/bin/xray version | head -1)${NC}"

    if [[ -f "$CONFIG_FILE" ]]; then
        write_alpine_xray_openrc_service || { line; return 1; }
        restart_alpine_xray_service || return 1
        return 0
    fi
    line
}

function show_alpine_xray_status() {
    line
    center_echo "Alpine Xray（Vless-Enc）服务状态" "${CYAN}${BOLD}"
    line
    ensure_alpine_supported || return 1

    if [[ -x /usr/local/bin/xray ]]; then
        echo -e "${CYAN}  版本: $(/usr/local/bin/xray version | head -1)${NC}"
    else
        echo -e "${YELLOW}  版本: N/A${NC}"
    fi

    if [[ -x "$ALPINE_XRAY_SERVICE_FILE" ]]; then
        rc-service xray status || true
    else
        echo -e "${YELLOW}  未找到 OpenRC 服务文件：${ALPINE_XRAY_SERVICE_FILE}${NC}"
    fi

    echo ""
    local listen_port=""
    listen_port=$(get_alpine_xray_enc_port_from_config)
    if [[ -n "$listen_port" ]]; then
        center_echo "监听检查" "${CYAN}${BOLD}"
        ss -ltnup 2>/dev/null | grep ":${listen_port}\b" || echo -e "${YELLOW}  未检测到 ${listen_port} 端口监听${NC}"
        echo ""
    fi

    center_echo "日志提示" "${CYAN}${BOLD}"
    echo -e "${YELLOW}  OpenRC 默认没有 journalctl 风格统一日志。${NC}"
    echo -e "${CYAN}  如需看启动报错，可执行：${NC}"
    echo -e "${CYAN}    rc-service xray restart${NC}"
    echo -e "${CYAN}    /usr/local/bin/xray run -config ${CONFIG_FILE}${NC}"
    line
}

function edit_alpine_xray_config() {
    while true; do
        line
        center_echo "修改 Alpine Xray 配置文件" "${CYAN}${BOLD}"
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
            echo -e "${RED}  未找到配置文件，请先执行 Alpine Vless-Enc 安装。${NC}"
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
                if /usr/local/bin/xray run -test -config "$CONFIG_FILE" >/dev/null 2>&1; then
                    echo -e "${GREEN}  ✓ Xray 配置语法校验通过。${NC}"
                else
                    cp -f -- "$CONFIG_FILE" "${DATA_DIR}/last_failed_config.json" 2>/dev/null || true
                    echo -e "${RED}  ✗ 当前文件不是合法 Xray 配置，请修正后再重启服务。${NC}"
                    echo -e "${YELLOW}  已保留失败配置: ${DATA_DIR}/last_failed_config.json${NC}"
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

function cleanup_alpine_service_backups() {
    local backup_path
    for backup_path in \
        "${ALPINE_XRAY_SERVICE_FILE}.bak."* \
        "${ALPINE_SS_SERVICE_FILE}.bak."*; do
        [[ -e "$backup_path" || -L "$backup_path" ]] || continue
        remove_path_quiet "$backup_path" "$backup_path"
    done
}

function cleanup_xray_artifacts_alpine() {
    echo -e "${YELLOW}  清理 Alpine Xray 残留...${NC}"
    rc-service xray stop >/dev/null 2>&1 || true
    rc-update del xray default >/dev/null 2>&1 || true
    remove_path_quiet "$ALPINE_XRAY_SERVICE_FILE" "$ALPINE_XRAY_SERVICE_FILE"
    cleanup_xray_artifacts
}

function cleanup_alpine_ss_artifacts() {
    echo -e "${YELLOW}  清理 Alpine SS2022 残留...${NC}"
    rc-service ssserver stop >/dev/null 2>&1 || true
    rc-update del ssserver default >/dev/null 2>&1 || true
    apk del shadowsocks-rust mimalloc >/dev/null 2>&1 || true
    remove_path_quiet "$ALPINE_SS_SERVICE_FILE" "$ALPINE_SS_SERVICE_FILE"
    remove_path_quiet "$ALPINE_SS_CONFIG_DIR" "$ALPINE_SS_CONFIG_DIR"
}

function uninstall_alpine_xray_and_delete_self() {
    line
    center_echo "完整卸载 Alpine Xray" "${RED}${BOLD}"
    line
    echo -e "${RED}  - 卸载 Xray（Alpine）${NC}"
    echo -e "${RED}  - 删除 Xray 配置、服务文件与生成目录${NC}"
    echo -e "${RED}  - 删除 zxray 启动命令${NC}"
    echo -e "${RED}  - 删除脚本源文件、临时文件、日志与 txt 文件${NC}"
    line
    if should_auto_confirm_uninstall; then
        echo -e "${YELLOW}  检测到快捷完整卸载：已自动确认继续。${NC}"
    else
        read -r -p "输入 yes 确认完整卸载: " CONFIRM
        if [[ "$CONFIRM" != "yes" ]]; then
            echo -e "${YELLOW}已取消。${NC}"
            return 0
        fi
    fi

    cleanup_xray_artifacts_alpine
    cleanup_alpine_service_backups
    cleanup_doudou_runtime

    echo -e "${GREEN}  ✓ 卸载与清理已完成。${NC}"
    line
    exit 0
}

function install_alpine_xray_vlessenc() {
    line
    echo -e "${GREEN}${BOLD}  Alpine 专用 Xray（仅 Vless-Enc）安装${NC}"
    line
    ensure_alpine_supported || return 1

    echo -e "\n${CYAN}[Step 1/6] 基础环境${NC}"
    ensure_alpine_community_repo || return 1
    check_bbr || true

    local INSTALL_MODE="auto"
    local SCENARIO=""
    local TEMPLATE_LABEL=""
    local FREEDOM_DOMAIN_STRATEGY="UseIPv4"
    local FREEDOM_DESC="IPv4 优先"
    local ENC_PORT_SOURCE="auto"
    local MANUAL_ENC_PORT=""
    local ENC_RTT_MODE="0rtt"
    local ENC_SHAPE_MODE="xorpub"
    local ENC_TICKET_WINDOW="600s"
    local ENC_AUTH_METHOD="x25519"
    local -a LANDING_LINKS=()
    local -a LANDING_LABELS=()
    local -a LANDING_JSONS=()
    local -a LANDING_TAGS=()

    while true; do
        echo -e "\n${CYAN}[Step 2/6] 第二层：安装模式${NC}"
        while true; do
            echo -e "  ${CYAN}1.${NC} 自动模式"
            echo -e "  ${CYAN}2.${NC} 手动模式"
            echo -e "  ${CYAN}0.${NC} 返回主菜单"
            read -r -p "选择 [1-2/0]，默认 1: " INSTALL_MODE_CHOICE
            case "${INSTALL_MODE_CHOICE:-1}" in
                1|01) INSTALL_MODE="auto"; break ;;
                2|02) INSTALL_MODE="manual"; break ;;
                0|00) return 0 ;;
                *) echo -e "${RED}  请输入 1、2 或 0。${NC}" ;;
            esac
        done

        while true; do
            echo -e "\n${CYAN}[Step 3/6] 第三层：模板选择${NC}"
            SCENARIO=$(choose_alpine_vlessenc_scenario)
            case "$SCENARIO" in
                __BACK__)
                    break
                    ;;
                __MAIN__)
                    return 0
                    ;;
            esac

            while true; do
                TEMPLATE_LABEL=$(get_install_scenario_label "$SCENARIO")
                FREEDOM_DOMAIN_STRATEGY="UseIPv4"
                FREEDOM_DESC="IPv4 优先"
                ENC_PORT_SOURCE="auto"
                MANUAL_ENC_PORT=""
                ENC_RTT_MODE="0rtt"
                ENC_SHAPE_MODE="xorpub"
                ENC_TICKET_WINDOW="600s"
                ENC_AUTH_METHOD="x25519"
                LANDING_LINKS=()
                LANDING_LABELS=()
                LANDING_JSONS=()
                LANDING_TAGS=()

                echo -e "${GREEN}  已选：${TEMPLATE_LABEL}${NC}"
                echo -e "${YELLOW}  说明：该 Alpine Xray 流程仅提供 Vless-Enc，不包含 Reality，也不提供 padding / delay 选项。${NC}"
                echo -e "${YELLOW}  说明：01 安装为覆盖安装，会生成新的完整配置并替换当前 Xray 配置；旧配置会先自动备份。${NC}"

                if [[ "$INSTALL_MODE" == "auto" ]]; then
                    echo -e "${CYAN}  自动模式将使用本模板默认值：${NC}"
                    echo -e "${CYAN}    - Vless-Enc：xorpub / 0rtt / x25519 认证${NC}"
                    echo -e "${CYAN}    - Vless-Enc 端口：随机高位端口${NC}"
                    if [[ "$SCENARIO" == "3" ]]; then
                        echo -e "${CYAN}    - 出口：freedom / ${FREEDOM_DESC}${NC}"
                    else
                        echo -e "${CYAN}    - 出口：VLESS / Reality / Vless-Enc${NC}"
                    fi
                fi

                if [[ "$INSTALL_MODE" == "manual" ]]; then
                    echo ""
                    if ask_yes_no "  是否手动选择直连出站的 IPv4 策略（y=手动选择，n=使用默认配置：IPv4 优先）"; then
                        FREEDOM_DOMAIN_STRATEGY=$(choose_freedom_domain_strategy)
                        case "$FREEDOM_DOMAIN_STRATEGY" in
                            __BACK__)
                                continue
                                ;;
                            __MAIN__)
                                return 0
                                ;;
                        esac
                        [[ "$FREEDOM_DOMAIN_STRATEGY" == "ForceIPv4" ]] && FREEDOM_DESC="仅 IPv4"
                    fi

                    echo ""
                    if ask_yes_no "  是否手动指定 Vless-Enc 端口（y=手动指定，n=使用默认配置：随机高位端口）"; then
                        MANUAL_ENC_PORT=$(read_manual_ss_port "请输入 Vless-Enc 端口: ")
                        ENC_PORT_SOURCE="manual"
                    fi
                    echo ""
                    echo -e "${CYAN}  Vless-Enc 握手模式：${NC}"
                    echo -e "${CYAN}  - 0rtt：更偏性能；1rtt：更偏保守${NC}"
                    ENC_RTT_MODE=$(choose_vlessenc_rtt_mode)
                    case "$ENC_RTT_MODE" in
                        __BACK__)
                            continue
                            ;;
                        __MAIN__)
                            return 0
                            ;;
                    esac
                    echo ""
                    echo -e "${CYAN}  Vless-Enc 包形态：${NC}"
                    echo -e "${CYAN}  - xorpub / native / random：默认推荐 xorpub${NC}"
                    ENC_SHAPE_MODE=$(choose_vlessenc_shape_mode)
                    case "$ENC_SHAPE_MODE" in
                        __BACK__)
                            continue
                            ;;
                        __MAIN__)
                            return 0
                            ;;
                    esac
                    echo ""
                    echo -e "${CYAN}  Vless-Enc 认证方式：${NC}"
                    echo -e "${CYAN}  - x25519 更短；mlkem768 更长且认证也抗量子${NC}"
                    ENC_AUTH_METHOD=$(choose_vlessenc_auth_method)
                    case "$ENC_AUTH_METHOD" in
                        __BACK__)
                            continue
                            ;;
                        __MAIN__)
                            return 0
                            ;;
                    esac
                fi

                if [[ "$SCENARIO" == "6" ]]; then
                    echo ""
                    echo -e "${CYAN}  当前模板为 Vless-Enc 传导链，需要输入 1 个落地目标链接。${NC}"
                    while true; do
                        local one_link=""
                        read -r -p "请输入落地链接: " one_link
                        one_link=$(printf '%s' "$one_link" | tr -d ' ')
                        if [[ -n "$one_link" ]]; then
                            LANDING_LINKS=("$one_link")
                            break
                        fi
                        echo -e "${RED}  落地链接不能为空。${NC}"
                    done
                fi

                break 3
            done
        done
    done

    echo -e "\n${CYAN}[Step 4/6] 安装依赖与 Xray 核心${NC}"
    render_install_context "$TEMPLATE_LABEL" "$INSTALL_MODE"
    install_alpine_base_deps || {
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

    echo -e "\n${CYAN}[Step 5/6] 生成密钥、端口与传导参数${NC}"
    render_install_context "$TEMPLATE_LABEL" "$INSTALL_MODE"

    local PORT=""
    local UUID=""
    local LOCAL_ENC_PORT=""
    local VLESSENC_PAIR_RAW="" VLESS_ENC_DECRYPTION_BASE="" VLESS_ENC_ENCRYPTION_BASE=""
    local VLESS_ENC_DECRYPTION="" VLESS_ENC_ENCRYPTION=""

    UUID=$(/usr/local/bin/xray uuid 2>/dev/null || true)
    [[ -n "$UUID" ]] || { echo -e "${RED}  ✗ 生成 Vless-Enc UUID 失败，安装已中止。${NC}"; return 1; }

    if [[ "$ENC_PORT_SOURCE" == "manual" ]]; then
        ensure_alpine_install_port_available "$MANUAL_ENC_PORT" "Alpine Vless-Enc" || return 1
        LOCAL_ENC_PORT="$MANUAL_ENC_PORT"
    else
        LOCAL_ENC_PORT=$(pick_random_free_port_excluding) || { echo -e "${RED}  ✗ 无法为 Vless-Enc 选出可用的随机高位端口。${NC}"; return 1; }
    fi

    VLESSENC_PAIR_RAW=$(get_vlessenc_pair_from_xray "$ENC_AUTH_METHOD" || true)
    [[ -n "$VLESSENC_PAIR_RAW" ]] || { echo -e "${RED}  ✗ 调用 xray vlessenc 生成 Vless-Enc 参数失败。${NC}"; return 1; }
    VLESS_ENC_DECRYPTION_BASE=${VLESSENC_PAIR_RAW%%$'\t'*}
    VLESS_ENC_ENCRYPTION_BASE=${VLESSENC_PAIR_RAW#*$'\t'}
    [[ -n "$VLESS_ENC_DECRYPTION_BASE" && -n "$VLESS_ENC_ENCRYPTION_BASE" ]] || { echo -e "${RED}  ✗ 解析 xray vlessenc 输出失败。${NC}"; return 1; }
    VLESS_ENC_DECRYPTION=$(rewrite_vlessenc_block2_block3 "$VLESS_ENC_DECRYPTION_BASE" "$ENC_SHAPE_MODE" "$ENC_TICKET_WINDOW") || { echo -e "${RED}  ✗ 重写服务端 Vless-Enc 参数失败。${NC}"; return 1; }
    VLESS_ENC_ENCRYPTION=$(rewrite_vlessenc_block2_block3 "$VLESS_ENC_ENCRYPTION_BASE" "$ENC_SHAPE_MODE" "$ENC_RTT_MODE") || { echo -e "${RED}  ✗ 重写客户端 Vless-Enc 参数失败。${NC}"; return 1; }

    if [[ "$SCENARIO" == "6" ]]; then
        build_outbound_from_link "${LANDING_LINKS[0]}" "landing" || { echo -e "${RED}  ✗ 解析落地 / 传导链接失败，请检查格式。${NC}"; return 1; }
        print_parsed_outbound_preview
        LANDING_JSONS=("$PARSED_OUTBOUND_JSON")
        LANDING_LABELS=("$PARSED_LINK_LABEL")
        LANDING_TAGS=("landing")
    fi

    echo -e "${GREEN}  ✓ 端口、密钥与模板参数已准备完成${NC}"

    echo -e "\n${CYAN}[Step 6/6] 写入配置并启动服务${NC}"
    render_install_context "$TEMPLATE_LABEL" "$INSTALL_MODE"
    ensure_runtime_layout
    mkdir -p "$CONFIG_DIR"
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
    local VLESS_ENC_LINK_V6=""
    local VLESS_ENC_LINK=""
    local VLESS_ENC_ENCRYPTION_URI=""
    local TEMP_CONFIG=""

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

    VLESS_ENC_ENCRYPTION_URI=$(url_encode "$VLESS_ENC_ENCRYPTION")
    VLESS_ENC_LINK="vless://${UUID}@${SERVER_IP_URI}:${LOCAL_ENC_PORT}?encryption=${VLESS_ENC_ENCRYPTION_URI}&flow=xtls-rprx-vision&headerType=none&type=tcp#Vless-Enc-zxray"
    if [[ -n "$SERVER_IP_URI_V6" ]]; then
        VLESS_ENC_LINK_V6="vless://${UUID}@${SERVER_IP_URI_V6}:${LOCAL_ENC_PORT}?encryption=${VLESS_ENC_ENCRYPTION_URI}&flow=xtls-rprx-vision&headerType=none&type=tcp#Vless-Enc-IPv6-zxray"
    fi

    case "$SCENARIO" in
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
提示:
  - 若当前为 NAT / 内网转发环境，请确认入口端口已放通，或已正确配置端口转发，若有外部 IP，请将订阅中的 IP 一并改为该外部 IP。
EOF
)
            if [[ -n "$VLESS_ENC_LINK_V6" ]]; then
                SUBS_TEXT+=$(cat <<EOF
Vless-Enc（直出 / IPv6）:
  ${VLESS_ENC_LINK_V6}
EOF
)
            fi
            PORTS_TEXT=$(cat <<EOF
端口:
  Vless-Enc:   ${LOCAL_ENC_PORT}
出站说明:
  直连策略:    ${FREEDOM_DESC}
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
提示:
  - 若当前为 NAT / 内网转发环境，请确认入口端口已放通，或已正确配置端口转发。
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
EOF
)
            PORTS_TEXT=$(cat <<EOF
端口:
  Vless-Enc:   ${LOCAL_ENC_PORT}
出站说明:
  传导方向:    Vless-Enc 入站 -> VLESS / Reality / Vless-Enc 出站
  传导目标:    ${LANDING_LABELS[0]}
EOF
)
            ;;
        *)
            echo -e "${RED}  未知 Alpine Vless-Enc 模板：${SCENARIO}${NC}"
            return 1
            ;;
    esac

    TEMP_CONFIG=$(mktemp /tmp/xray-alpine-config.XXXXXX.json) || {
        echo -e "${RED}  ✗ 无法创建临时配置文件。${NC}"
        return 1
    }
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
    chmod 600 "$CONFIG_FILE" || return 1
    write_alpine_xray_openrc_service || return 1
    rc-update add xray default >/dev/null 2>&1 || true

    rc-service xray restart >/dev/null 2>&1 || rc-service xray start >/dev/null 2>&1 || {
        echo -e "${RED}  Alpine Xray 服务启动失败！${NC}"
        rc-service xray status || true
        return 1
    }

    local check_attempt=0
    while [[ $check_attempt -lt 5 ]]; do
        sleep 2
        if rc-service xray status >/dev/null 2>&1; then
            break
        fi
        check_attempt=$((check_attempt + 1))
        echo -e "${YELLOW}  等待服务启动... (${check_attempt}/5)${NC}"
    done

    if ! rc-service xray status >/dev/null 2>&1; then
        echo -e "${RED}  Alpine Xray 服务启动失败！${NC}"
        rc-service xray status || true
        echo -e "${YELLOW}  可继续手动排查：/usr/local/bin/xray run -config ${CONFIG_FILE}${NC}"
        return 1
    fi
    echo -e "${GREEN}  ✓ Alpine Xray 服务已启动${NC}"

    if ss -ltnup 2>/dev/null | grep -q ":${LOCAL_ENC_PORT}\b"; then
        echo -e "${GREEN}  ✓ 已检测到 ${LOCAL_ENC_PORT} 端口监听${NC}"
    else
        echo -e "${YELLOW}  ⚠ 未明确检测到 ${LOCAL_ENC_PORT} 端口监听，请手动检查：ss -ltnup | grep :${LOCAL_ENC_PORT}${NC}"
    fi

    write_dynamic_result_files "$SUBS_TEXT" "$PORTS_TEXT"
    write_install_runtime_kind "alpine-xray-vlessenc"
    render_saved_node_info "配置完成" || { echo -e "${RED}  节点信息写入失败，请检查 ${INFO_FILE}${NC}"; return 1; }
}

function install_alpine_service_entry() {
    ensure_alpine_supported || return 1
    while true; do
        line
        center_echo "Alpine 覆盖安装" "${CYAN}${BOLD}"
        line
        echo -e "  ${CYAN}1.${NC} Alpine 专用 Xray（仅 Vless-Enc，无 Reality，无 padding）"
        echo -e "  ${CYAN}2.${NC} Alpine 专用 SS2022（shadowsocks-rust）"
        echo -e "  ${CYAN}0.${NC} 返回主菜单"
        line
        read -r -p "选择 [0/1/2]: " ALPINE_INSTALL_CHOICE
        case "$ALPINE_INSTALL_CHOICE" in
            1|01)
                install_alpine_xray_vlessenc
                return $?
                ;;
            2|02)
                install_alpine_ss2022
                return $?
                ;;
            0|00)
                return 0
                ;;
            *)
                echo -e "${RED}无效输入，请重新选择。${NC}"
                sleep 1
                ;;
        esac
    done
}

function install_xray() {
    line
    echo -e "${GREEN}${BOLD}  Xray 覆盖安装${NC}"
    line

    echo -e "\n${CYAN}[Step 1/7] 系统环境预检${NC}"
    ensure_systemd_supported || return 1
    check_bbr || true

    local INSTALL_MODE="auto"
    local SCENARIO=""
    local TEMPLATE_LABEL=""
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
    local CHAIN_UNIFIED="0"
    REALITY_GATE_RULES_JSON=""

    while true; do
        echo -e "
${CYAN}[Step 2/7] 第二层：安装模式${NC}"
        if is_quick_install_noninteractive; then
            echo -e "${YELLOW}  检测到非交互快速安装：安装模式自动使用默认值（自动模式）。${NC}"
            INSTALL_MODE="auto"
        else
            while true; do
                echo -e "  ${CYAN}1.${NC} 自动模式"
                echo -e "  ${CYAN}2.${NC} 手动模式"
                echo -e "  ${CYAN}0.${NC} 返回主菜单"
                read -r -p "选择 [1-2/0]，默认 1: " INSTALL_MODE_CHOICE
                case "${INSTALL_MODE_CHOICE:-1}" in
                    1|01) INSTALL_MODE="auto"; break ;;
                    2|02) INSTALL_MODE="manual"; break ;;
                    0|00) return 0 ;;
                    *) echo -e "${RED}  请输入 1、2 或 0。${NC}" ;;
                esac
            done
        fi

        while true; do
            echo -e "
${CYAN}[Step 3/7] 第三层：模板选择${NC}"
            if is_quick_install_noninteractive; then
                if [[ -n "$QUICK_SCENARIO" ]]; then
                    SCENARIO="$QUICK_SCENARIO"
                    echo -e "${YELLOW}  检测到非交互快速安装：安装模板自动使用指定值（$(printf '%02d' "$SCENARIO") $(get_install_scenario_label "$SCENARIO")）。${NC}"
                else
                    SCENARIO="1"
                    echo -e "${YELLOW}  检测到非交互快速安装：安装模板自动使用默认值（01 Reality 直出 / 多落地，非交互模式默认 0 个落地）。${NC}"
                fi
            else
                SCENARIO=$(choose_install_scenario)
                case "$SCENARIO" in
                    __BACK__)
                        break
                        ;;
                    __MAIN__)
                        return 0
                        ;;
                    __CHAIN_SS__)
                        SCENARIO="5"
                        CHAIN_UNIFIED="1"
                        ;;
                    __CHAIN_VLESSENC__)
                        SCENARIO="6"
                        CHAIN_UNIFIED="1"
                        ;;
                esac
            fi

            while true; do
                TEMPLATE_LABEL=$(get_install_scenario_label "$SCENARIO")
                FREEDOM_DOMAIN_STRATEGY="UseIPv4"
                REALITY_PORT="$DEFAULT_PORT"
                SNI_SOURCE="auto"
                MANUAL_DEST=""
                DEST=""
                SS_PORT_SOURCE="auto"
                MANUAL_SS_PORT=""
                ENC_PORT_SOURCE="auto"
                MANUAL_ENC_PORT=""
                ENC_RTT_MODE="0rtt"
                ENC_SHAPE_MODE="xorpub"
                ENC_TICKET_WINDOW="600s"
                ENC_AUTH_METHOD="x25519"
                ENC_PADDING_PROFILE="off"
                ENC_PADDING_PROFILE_DESC="$(get_vlessenc_padding_profile_desc off)"
                ENC_PADDING_CLIENT=""
                ENC_PADDING_SERVER=""
                NEED_LANDING="0"
                LANDING_LINK=""
                LANDING_EXPECT="any"
                FREEDOM_DESC="IPv4 优先"
                SS_METHOD_DESC="2022-blake3-aes-128-gcm"
                LOCAL_SS_METHOD="2022-blake3-aes-128-gcm"
                REALITY_LANDING_COUNT=0
                LANDING_LINKS=()
                REALITY_LANDING_UUIDS=()
                LANDING_LABELS=()
                LANDING_JSONS=()
                LANDING_TAGS=()
                XHTTP_SPLIT_DIRECTION="v6_up_v4_down"
                XHTTP_SPLIT_DESC="$(get_xhttp_split_direction_desc v6_up_v4_down)"
                XHTTP_PATH="$(generate_xhttp_path)"
                XHTTP_SECURITY=""
                XHTTP_WARNING_TEXT=""
                XHTTP_MODE_ENABLED="0"
                XHTTP_REQ_V4=""
                XHTTP_REQ_V6=""
                REALITY_GATE_RULES_JSON=""
                if [[ "$SCENARIO" != "5" && "$SCENARIO" != "6" ]]; then
                    CHAIN_UNIFIED="0"
                fi

                echo -e "${GREEN}  已选：${TEMPLATE_LABEL}${NC}"

                case "$SCENARIO" in
                    1)
                        echo -e "${CYAN}  说明：Reality 专用模板支持 0-10 个落地出口。0 代表纯直出；1-10 代表在直出之外增加对应数量的落地入口。${NC}"
                        echo -e "${CYAN}  这些入口共用同一个 Reality 监听端口，通过不同用户 / UUID 区分直出与各个落地出口。${NC}"
                        if is_quick_install_noninteractive; then
                            REALITY_LANDING_COUNT="0"
                            echo -e "${YELLOW}  非交互快速安装默认使用纯直出，不添加 Reality 落地。${NC}"
                        else
                            REALITY_LANDING_COUNT=$(choose_reality_landing_count)
                        fi
                        case "$REALITY_LANDING_COUNT" in
                            __BACK__)
                                break
                                ;;
                            __MAIN__)
                                return 0
                                ;;
                        esac
                        if (( REALITY_LANDING_COUNT > 0 )); then
                            NEED_LANDING="1"
                            LANDING_EXPECT="any"
                        fi
                        ;;
                    5)
                        NEED_LANDING="1"
                        if [[ "$CHAIN_UNIFIED" == "1" ]]; then
                            LANDING_EXPECT="any"
                        else
                            LANDING_EXPECT="ss"
                        fi
                        ;;
                    6)
                        NEED_LANDING="1"
                        if [[ "$CHAIN_UNIFIED" == "1" ]]; then
                            LANDING_EXPECT="any"
                        else
                            LANDING_EXPECT="vless"
                        fi
                        ;;
                    7)
                        XHTTP_MODE_ENABLED="1"
                        XHTTP_SECURITY="reality"
                        echo -e "${CYAN}  说明：该模板使用 XHTTP + Reality，并通过 downloadSettings 做去程 / 回程分离。${NC}"
                        echo -e "${CYAN}  这些入口共用同一个 XHTTP + Reality 监听端口，支持 0-10 个落地，通过不同用户 / UUID 区分直出与各个落地出口。${NC}"
                        if is_quick_install_noninteractive; then
                            REALITY_LANDING_COUNT="0"
                            echo -e "${YELLOW}  非交互快速安装默认使用纯直出，不添加 XHTTP + Reality 落地。${NC}"
                        else
                            REALITY_LANDING_COUNT=$(choose_reality_landing_count)
                        fi
                        case "$REALITY_LANDING_COUNT" in
                            __BACK__)
                                break
                                ;;
                            __MAIN__)
                                return 0
                                ;;
                        esac
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
                            echo -e "${CYAN}    - 入口：SS 入站${NC}"
                            echo -e "${CYAN}    - 出口：任意支持的 SS / VLESS / Reality 出站${NC}"
                            echo -e "${CYAN}    - 保留 direct 直出出站${NC}"
                            ;;
                        6)
                            echo -e "${CYAN}    - Vless-Enc：xorpub / 0rtt / x25519 认证${NC}"
                            echo -e "${CYAN}    - Vless-Enc padding / delay：${ENC_PADDING_PROFILE_DESC}${NC}"
                            echo -e "${CYAN}    - 入口：Vless-Enc 入站${NC}"
                            echo -e "${CYAN}    - 出口：任意支持的 SS / VLESS / Reality 出站${NC}"
                            echo -e "${CYAN}    - 保留 direct 直出出站${NC}"
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
                        case "$FREEDOM_DOMAIN_STRATEGY" in
                            __BACK__)
                                continue
                                ;;
                            __MAIN__)
                                return 0
                                ;;
                        esac
                        [[ "$FREEDOM_DOMAIN_STRATEGY" == "ForceIPv4" ]] && FREEDOM_DESC="仅 IPv4"
                    fi

                    if [[ "$SCENARIO" == "1" || "$SCENARIO" == "4" || "$SCENARIO" == "7" ]]; then
                        echo ""
                        echo -e "${CYAN}  当前模板包含 Reality 入站，因此需要设置 Reality 端口与 SNI。${NC}"
                        echo -e "${CYAN}  Reality 端口：${NC}"
                        REALITY_PORT=$(choose_reality_port)
                        case "$REALITY_PORT" in
                            __BACK__)
                                continue
                                ;;
                            __MAIN__)
                                return 0
                                ;;
                        esac
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
                        case "$LOCAL_SS_METHOD" in
                            __BACK__)
                                continue
                                ;;
                            __MAIN__)
                                return 0
                                ;;
                        esac
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
                        case "$ENC_RTT_MODE" in
                            __BACK__)
                                continue
                                ;;
                            __MAIN__)
                                return 0
                                ;;
                        esac
                        echo ""
                        echo -e "${CYAN}  Vless-Enc 包形态：${NC}"
                        echo -e "${CYAN}  - xorpub / native / random：默认推荐 xorpub${NC}"
                        ENC_SHAPE_MODE=$(choose_vlessenc_shape_mode)
                        case "$ENC_SHAPE_MODE" in
                            __BACK__)
                                continue
                                ;;
                            __MAIN__)
                                return 0
                                ;;
                        esac
                        echo ""
                        echo -e "${CYAN}  Vless-Enc 认证方式：${NC}"
                        echo -e "${CYAN}  - x25519 更短；mlkem768 更长且认证也抗量子${NC}"
                        ENC_AUTH_METHOD=$(choose_vlessenc_auth_method)
                        case "$ENC_AUTH_METHOD" in
                            __BACK__)
                                continue
                                ;;
                            __MAIN__)
                                return 0
                                ;;
                        esac
                        echo ""
                        echo -e "${CYAN}  Vless-Enc 实验性 padding / delay：${NC}"
                        echo -e "${CYAN}  - 本质：padding 改单次包长范围，delay 改发包间隔；两端规则可以不同。${NC}"
                        echo -e "${CYAN}  - 温和档主要做轻量长度 / 节奏扰动；激进档会加入更强抖动，但更容易带来时延、吞吐和兼容性波动。${NC}"
                        echo -e "${CYAN}  - 手动自定义时：客户端规则写入分享链接 encryption，服务端规则写入入站 decryption。${NC}"
                        ENC_PADDING_PROFILE=$(choose_vlessenc_padding_profile)
                        case "$ENC_PADDING_PROFILE" in
                            __BACK__)
                                continue
                                ;;
                            __MAIN__)
                                return 0
                                ;;
                        esac
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
                        case "$XHTTP_SPLIT_DIRECTION" in
                            __BACK__)
                                continue
                                ;;
                            __MAIN__)
                                return 0
                                ;;
                        esac
                        XHTTP_SPLIT_DESC=$(get_xhttp_split_direction_desc "$XHTTP_SPLIT_DIRECTION")
                        echo -e "${CYAN}  客户端建议：v2rayN + Xray 内核。其他客户端本脚本不支持自动适配。${NC}"
                        if ask_yes_no "  是否手动指定 XHTTP path（y=手动输入，n=使用默认随机 path）"; then
                            XHTTP_PATH=$(read_manual_xhttp_path "请输入 XHTTP path: ")
                        fi
                    fi
                fi

                break 3
            done
        done
    done

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
            any) echo -e "${CYAN}  原因：无 TLS 链式允许 ss:// 或 vless:// 出站目标（包含 Vless-Enc / Reality 参数）。${NC}" ;;
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
                any)
                    case "$LANDING_LINK" in
                        ss://*|vless://*) ;;
                        *) echo -e "${RED}  请输入 ss:// 或 vless:// 链接。${NC}"; continue ;;
                    esac
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
        if [[ -z "${UUID:-}" ]]; then
            UUID=$(/usr/local/bin/xray uuid 2>/dev/null || true)
            [[ -n "$UUID" ]] || { echo -e "${RED}  ✗ 生成 Vless-Enc UUID 失败，安装已中止。${NC}"; return 1; }
        fi
    fi

    if [[ "$SCENARIO" == "2" || "$SCENARIO" == "4" || "$SCENARIO" == "5" ]]; then
        if [[ "$SS_PORT_SOURCE" == "manual" ]]; then
            while is_port_in_use_by_non_xray "$MANUAL_SS_PORT" || [[ "$MANUAL_SS_PORT" == "$PORT" ]]; do
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
            while is_port_in_use_by_non_xray "$MANUAL_ENC_PORT" || [[ "$MANUAL_ENC_PORT" == "$PORT" || "$MANUAL_ENC_PORT" == "$LOCAL_SS_PORT" ]]; do
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

    precheck_reality_port_before_apply "$SCENARIO" "$PORT" || return 1
    precheck_reusable_xray_port_before_apply "$LOCAL_SS_PORT" "SS2022" || return 1
    precheck_reusable_xray_port_before_apply "$LOCAL_ENC_PORT" "Vless-Enc" || return 1

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
            VLESS_LINK="vless://${REALITY_DIRECT_UUID}@${SERVER_IP_URI}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=firefox&type=raw&flow=xtls-rprx-vision&sni=${DEST}&sid=${SHORT_ID}#Reality-直出-zxray"
            if [[ -n "$SERVER_IP_URI_V6" ]]; then
                REALITY_LINK_V6="vless://${REALITY_DIRECT_UUID}@${SERVER_IP_URI_V6}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=firefox&type=raw&flow=xtls-rprx-vision&sni=${DEST}&sid=${SHORT_ID}#Reality-直出-IPv6-zxray"
            fi
        else
            VLESS_LINK="vless://${UUID}@${SERVER_IP_URI}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=firefox&type=raw&flow=xtls-rprx-vision&sni=${DEST}&sid=${SHORT_ID}#Reality-zxray"
            if [[ -n "$SERVER_IP_URI_V6" ]]; then
                REALITY_LINK_V6="vless://${UUID}@${SERVER_IP_URI_V6}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=firefox&type=raw&flow=xtls-rprx-vision&sni=${DEST}&sid=${SHORT_ID}#Reality-IPv6-zxray"
            fi
        fi
    fi
    if [[ "$SCENARIO" == "3" || "$SCENARIO" == "4" || "$SCENARIO" == "6" ]]; then
        VLESS_ENC_ENCRYPTION_URI=$(url_encode "$VLESS_ENC_ENCRYPTION")
        VLESS_ENC_LINK="vless://${UUID}@${SERVER_IP_URI}:${LOCAL_ENC_PORT}?encryption=${VLESS_ENC_ENCRYPTION_URI}&flow=xtls-rprx-vision&headerType=none&type=tcp#Vless-Enc-zxray"
        if [[ -n "$SERVER_IP_URI_V6" ]]; then
            VLESS_ENC_LINK_V6="vless://${UUID}@${SERVER_IP_URI_V6}:${LOCAL_ENC_PORT}?encryption=${VLESS_ENC_ENCRYPTION_URI}&flow=xtls-rprx-vision&headerType=none&type=tcp#Vless-Enc-IPv6-zxray"
        fi
    fi
    if [[ "$SCENARIO" == "2" || "$SCENARIO" == "4" || "$SCENARIO" == "5" ]]; then
        local SS_USERINFO
        SS_USERINFO=$(base64_encode_urlsafe_nopad "${LOCAL_SS_METHOD}:${LOCAL_SS_PWD}")
        SS_NODE_LINK="ss://${SS_USERINFO}@${SERVER_IP_URI}:${LOCAL_SS_PORT}#SS-zxray"
        if [[ -n "$SERVER_IP_URI_V6" ]]; then
            SS_NODE_LINK_V6="ss://${SS_USERINFO}@${SERVER_IP_URI_V6}:${LOCAL_SS_PORT}#SS-IPv6-zxray"
        fi
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
            REALITY_GATE_RULES_JSON=$(build_reality_gate_rules_json "$DEST")
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
                    REALITY_LANDING_LINKS+=("vless://${REALITY_LANDING_UUIDS[$((idx-1))]}@${SERVER_IP_URI}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=firefox&type=raw&flow=xtls-rprx-vision&sni=${DEST}&sid=${SHORT_ID}#Reality-落地${idx}-zxray")
                    if [[ -n "$SERVER_IP_URI_V6" ]]; then
                        REALITY_LANDING_LINKS_V6+=("vless://${REALITY_LANDING_UUIDS[$((idx-1))]}@${SERVER_IP_URI_V6}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=firefox&type=raw&flow=xtls-rprx-vision&sni=${DEST}&sid=${SHORT_ID}#Reality-落地${idx}-IPv6-zxray")
                    fi
                done
            fi
            INBOUNDS_JSON=$(cat <<EOF
$(build_reality_gate_inbound_json "$DEST")    {
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
          "dest": "127.0.0.1:${REALITY_GATE_PORT}",
          "serverNames": ["${DEST}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"],
          "limitFallbackUpload": {
            "afterBytes": 8192,
            "bytesPerSec": 1024,
            "burstBytesPerSec": 0
          },
          "limitFallbackDownload": {
            "afterBytes": 32768,
            "bytesPerSec": 2048,
            "burstBytesPerSec": 0
          }
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
            ALLOW_RULES_JSON="${REALITY_GATE_RULES_JSON}${REALITY_RULES_JSON}"
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
            REALITY_GATE_RULES_JSON=$(build_reality_gate_rules_json "$DEST")
            INBOUNDS_JSON=$(cat <<EOF
$(build_reality_gate_inbound_json "$DEST")    {
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
          "dest": "127.0.0.1:${REALITY_GATE_PORT}",
          "serverNames": ["${DEST}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"],
          "limitFallbackUpload": {
            "afterBytes": 8192,
            "bytesPerSec": 1024,
            "burstBytesPerSec": 0
          },
          "limitFallbackDownload": {
            "afterBytes": 32768,
            "bytesPerSec": 2048,
            "burstBytesPerSec": 0
          }
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
            ALLOW_RULES_JSON=$(cat <<EOF
${REALITY_GATE_RULES_JSON}
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
            XHTTP_ENTRY_LINKS+=("$(build_xhttp_reality_full_link "${REALITY_DIRECT_UUID}" "${XHTTP_UP_IP_URI}" "${PORT}" "${XHTTP_DOWN_IP_RAW}" "${PORT}" "${DEST}" "firefox" "${PUBLIC_KEY}" "${SHORT_ID}" "${XHTTP_PATH}" "XHTTP-Reality-$(get_xhttp_split_direction_share_name "$XHTTP_SPLIT_DIRECTION")-直出-zxray")")
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
                    XHTTP_ENTRY_LINKS+=("$(build_xhttp_reality_full_link "${REALITY_LANDING_UUIDS[$((idx-1))]}" "${XHTTP_UP_IP_URI}" "${PORT}" "${XHTTP_DOWN_IP_RAW}" "${PORT}" "${DEST}" "firefox" "${PUBLIC_KEY}" "${SHORT_ID}" "${XHTTP_PATH}" "XHTTP-Reality-$(get_xhttp_split_direction_share_name "$XHTTP_SPLIT_DIRECTION")-落地${idx}-zxray")")
                    XHTTP_PATCH_LABELS+=("XHTTP + Reality 落地入口 ${idx}")
                    XHTTP_PATCH_FILES+=("${XHTTP_PATCH_DIR}/xhttp_reality_landing${idx}_patch.json")
                    write_xhttp_client_patch_file "${XHTTP_PATCH_DIR}/xhttp_reality_landing${idx}_patch.json" "$XHTTP_DOWN_IP_RAW" "$PORT" "reality" "${DEST}" "firefox" "$PUBLIC_KEY" "$SHORT_ID" "$XHTTP_PATH"
                    XHTTP_PATCH_JSONS+=("$XHTTP_PATCH_LAST_JSON")
                done
            fi
            REALITY_GATE_RULES_JSON=$(build_reality_gate_rules_json "$DEST")
            INBOUNDS_JSON=$(cat <<EOF
$(build_reality_gate_inbound_json "$DEST")    {
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
          "dest": "127.0.0.1:${REALITY_GATE_PORT}",
          "serverNames": ["${DEST}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"],
          "limitFallbackUpload": {
            "afterBytes": 8192,
            "bytesPerSec": 1024,
            "burstBytesPerSec": 0
          },
          "limitFallbackDownload": {
            "afterBytes": 32768,
            "bytesPerSec": 2048,
            "burstBytesPerSec": 0
          }
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
            ALLOW_RULES_JSON="${REALITY_GATE_RULES_JSON}${XHTTP_REALITY_RULES_JSON}"
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
EOF
)
                if [[ $idx2 -lt $((${#XHTTP_ENTRY_LINKS[@]}-1)) ]]; then
                    SUBS_TEXT+="

"
                fi
            done
            SUBS_TEXT+=$(cat <<EOF

说明:
  - 现已直接生成可导入的完整链接；extra= 参数内已内嵌 XHTTP downloadSettings。
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
  客户端链接:  已内嵌 extra 参数
EOF
)
            ;;
        8)
            VLESS_ENC_ENCRYPTION_URI=$(url_encode "$VLESS_ENC_ENCRYPTION")
            XHTTP_ENTRY_LINKS+=("$(build_xhttp_vlessenc_full_link "${UUID}" "${XHTTP_UP_IP_URI}" "${LOCAL_ENC_PORT}" "${XHTTP_DOWN_IP_RAW}" "${LOCAL_ENC_PORT}" "${VLESS_ENC_ENCRYPTION}" "${XHTTP_PATH}" "XHTTP-Vless-Enc-$(get_xhttp_split_direction_share_name "$XHTTP_SPLIT_DIRECTION")-实验-zxray")")
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

说明:
  - 警告：该模板无 TLS / 无 Reality，仅适合实验研究，不建议在高风险公网环境使用。
  - 现已直接生成可导入的完整链接；extra= 参数内已内嵌 XHTTP downloadSettings。
  - 推荐客户端: v2rayN + Xray 内核。其他客户端本脚本不支持自动适配。
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
  客户端链接:  已内嵌 extra 参数
EOF
)
            ;;
    esac

    local TEMP_CONFIG
    TEMP_CONFIG=$(mktemp /tmp/xray_config.XXXXXX.json) || {
        echo -e "${RED}  ✗ 无法创建临时配置文件。${NC}"
        return 1
    }
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
    chmod 600 "$CONFIG_FILE" || return 1

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
        echo -e "${RED}  Xray 服务启动失败！${NC}"
        echo -e "${YELLOW}  说明：这里不是连续重启 5 次，而是单次 restart 后连续 5 次检查仍未进入 active。${NC}"
        systemctl status xray --no-pager -l 2>/dev/null | sed -n '1,25p' || true
        echo -e "${YELLOW}  请继续查看完整日志：journalctl -u xray -n 50 --no-pager${NC}"
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
        echo -e "${YELLOW}  检测到当前为 Alpine / OpenRC，进入 Alpine 安装方案。${NC}"
        install_alpine_service_entry
        return $?
    fi
    install_xray
}

function run_quick_install_entry() {
    if is_alpine_system; then
        install_alpine_service_entry
        return $?
    fi
    install_xray
}

function update_restart_menu() {
    while true; do
        line
        center_echo "更新 / 重启当前服务" "${CYAN}${BOLD}"
        line
        echo -e "  ${CYAN}1.${NC} 更新核心 / 组件并按当前逻辑处理服务"
        echo -e "  ${CYAN}2.${NC} 仅重启当前服务"
        echo -e "  ${CYAN}0.${NC} 返回主菜单"
        line
        read -r -p "选择 [0/1/2]: " UPDATE_RESTART_CHOICE
        case "$UPDATE_RESTART_CHOICE" in
            1|01) update_current_service; return $? ;;
            2|02) restart_current_service; return $? ;;
            0|00) return 0 ;;
            *) echo -e "${RED}无效输入，请重新选择。${NC}"; sleep 1 ;;
        esac
    done
}

function update_current_service() {
    local runtime_kind=""
    runtime_kind=$(get_install_runtime_kind 2>/dev/null || true)
    case "$runtime_kind" in
        alpine-ss2022)
            update_alpine_ssservice
            ;;
        alpine-xray-vlessenc)
            update_alpine_xray_service
            ;;
        xray|"")
            if is_alpine_system; then
                echo -e "${YELLOW}当前为 Alpine / OpenRC，请先执行覆盖安装选择 Alpine 方案。${NC}"
                return 1
            fi
            update_xray
            ;;
    esac
}

function restart_current_service() {
    local runtime_kind=""
    runtime_kind=$(get_install_runtime_kind 2>/dev/null || true)
    case "$runtime_kind" in
        alpine-ss2022)
            restart_alpine_ssservice
            ;;
        alpine-xray-vlessenc)
            restart_alpine_xray_service
            ;;
        xray|"")
            if is_alpine_system; then
                echo -e "${YELLOW}当前为 Alpine / OpenRC，请先执行覆盖安装选择 Alpine 方案。${NC}"
                return 1
            fi
            restart_xray
            ;;
    esac
}

function show_runtime_status() {
    local runtime_kind=""
    runtime_kind=$(get_install_runtime_kind 2>/dev/null || true)
    case "$runtime_kind" in
        alpine-ss2022)
            show_alpine_ss_status
            ;;
        alpine-xray-vlessenc)
            show_alpine_xray_status
            ;;
        xray|"")
            if is_alpine_system; then
                echo -e "${YELLOW}当前为 Alpine / OpenRC，请先执行覆盖安装选择 Alpine 方案。${NC}"
                return 1
            fi
            show_status
            ;;
    esac
}

function edit_runtime_config() {
    local runtime_kind=""
    runtime_kind=$(get_install_runtime_kind 2>/dev/null || true)
    case "$runtime_kind" in
        alpine-ss2022)
            edit_alpine_ss_config
            ;;
        alpine-xray-vlessenc)
            edit_alpine_xray_config
            ;;
        xray|"")
            if is_alpine_system; then
                echo -e "${YELLOW}当前为 Alpine / OpenRC，请先执行覆盖安装选择 Alpine 方案。${NC}"
                return 1
            fi
            edit_config
            ;;
    esac
}

function should_auto_confirm_uninstall() {
    [[ "$QUICK_UNINSTALL" == "1" ]]
}

function uninstall_alpine_all_and_delete_self() {
    line
    center_echo "完整卸载 Alpine Xray / SS2022" "${RED}${BOLD}"
    line
    echo -e "${RED}  - 卸载 Alpine Xray 与 shadowsocks-rust${NC}"
    echo -e "${RED}  - 删除配置、服务文件、脚本源文件与生成目录${NC}"
    echo -e "${RED}  - 删除 zxray 启动命令${NC}"
    echo -e "${RED}  - 删除临时文件、日志与生成的 txt 文件${NC}"
    line
    if should_auto_confirm_uninstall; then
        echo -e "${YELLOW}  检测到快捷完整卸载：已自动确认继续。${NC}"
    else
        read -r -p "输入 yes 确认完整卸载: " CONFIRM
        if [[ "$CONFIRM" != "yes" ]]; then
            echo -e "${YELLOW}已取消。${NC}"
            return 0
        fi
    fi

    cleanup_xray_artifacts_alpine
    cleanup_alpine_ss_artifacts
    cleanup_alpine_service_backups
    cleanup_doudou_runtime

    echo -e "${GREEN}  ✓ 卸载与清理已完成。${NC}"
    line
    exit 0
}

function uninstall_current_service_and_delete_self() {
    local runtime_kind=""
    runtime_kind=$(get_install_runtime_kind 2>/dev/null || true)
    case "$runtime_kind" in
        alpine-ss2022|alpine-xray-vlessenc)
            uninstall_alpine_all_and_delete_self
            ;;
        xray|"")
            if is_alpine_system; then
                uninstall_alpine_all_and_delete_self
            fi
            uninstall_xray_and_delete_self
            ;;
    esac
}

function update_xray() {
    ensure_systemd_supported || return 1
    line
    echo -e "${YELLOW}  更新 Xray 核心程序...${NC}"

    local update_log
    local update_ret
    update_log=$(mktemp /tmp/xray-update.XXXXXX.log) || {
        echo -e "${RED}  ✗ 无法创建 Xray 更新日志临时文件。${NC}"
        line
        return 1
    }
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

function cleanup_legacy_quick_paths() {
    local legacy_path
    local -a legacy_paths=(
        "/usr/local/bin/zxray"
        "/usr/local/bin/zdd"
        "/usr/local/bin/doudou"
        "/usr/local/bin/xray-manager"
        "/usr/bin/zxray"
        "/usr/bin/zdd"
        "/usr/bin/doudou"
        "/usr/bin/xray-manager"
        "/usr/sbin/zxray"
        "/usr/sbin/zdd"
        "/usr/sbin/doudou"
        "/usr/sbin/xray-manager"
        "/root/bin/zxray"
        "/root/bin/zdd"
        "/root/bin/doudou"
        "/root/bin/xray-manager"
        "/root/.local/bin/zxray"
        "/root/.local/bin/zdd"
        "/root/.local/bin/doudou"
        "/root/.local/bin/xray-manager"
    )

    for legacy_path in "${legacy_paths[@]}"; do
        remove_path_quiet "$legacy_path" "$legacy_path"
    done
}

function canonicalize_path() {
    local path="$1"
    local dir=""
    local base=""

    if command -v readlink >/dev/null 2>&1; then
        readlink -f -- "$path" 2>/dev/null && return 0
    fi

    dir=$(dirname -- "$path" 2>/dev/null || true)
    base=$(basename -- "$path" 2>/dev/null || true)
    [[ -n "$dir" && -n "$base" ]] || return 1
    (
        cd -- "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base"
    ) && return 0
    return 1
}

function remove_current_script_source_if_safe() {
    local source_path=""
    local real_path=""

    source_path=$(resolve_self_source_path 2>/dev/null || true)
    [[ -n "$source_path" ]] || return 0

    case "$source_path" in
        /proc/*|/dev/*)
            return 0
            ;;
    esac

    real_path=$(canonicalize_path "$source_path" 2>/dev/null || true)
    [[ -n "$real_path" ]] || real_path="$source_path"

    case "$real_path" in
        "$SELF_SCRIPT_PATH"|/usr/local/lib/doudou/*|/usr/local/lib/zxray/*|/tmp/doudou-entry.*.sh|/root/xray-manager*.sh|/root/zxray*.sh|/root/zdd-xray*.sh|/root/doudou-xray*.sh)
            remove_path_quiet "$real_path" "$real_path"
            ;;
    esac
}

function remove_recorded_source_if_safe() {
    local source_path=""
    local expected_sha=""
    local actual_sha=""
    local owner_uid=""
    local -a record_lines=()

    [[ -f "$SOURCE_RECORD_FILE" ]] || return 0
    mapfile -t record_lines < "$SOURCE_RECORD_FILE" 2>/dev/null || return 0
    [[ ${#record_lines[@]} -eq 2 ]] || return 0

    source_path="${record_lines[0]}"
    expected_sha="${record_lines[1],,}"
    [[ -n "$source_path" && "$source_path" != *$'\n'* && "$source_path" != *$'\r'* ]] || return 0
    [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || return 0

    case "$source_path" in
        /proc/*|/dev/*|"$SELF_SCRIPT_PATH"|/usr/local/lib/doudou/*|/usr/local/lib/zxray/*)
            return 0
            ;;
    esac
    [[ -f "$source_path" && ! -L "$source_path" ]] || return 0

    owner_uid=$(stat -Lc '%u' -- "$source_path" 2>/dev/null || true)
    [[ "$owner_uid" == "0" ]] || return 0
    command -v sha256sum >/dev/null 2>&1 || return 0
    actual_sha=$(sha256sum -- "$source_path" 2>/dev/null | awk 'NR==1 {print tolower($1)}')
    [[ "$actual_sha" == "$expected_sha" ]] || {
        echo -e "${YELLOW}  ⚠ 原始脚本内容已变化，为避免误删，保留：${source_path}${NC}"
        return 0
    }

    if rm -f -- "$source_path"; then
        echo -e "${GREEN}  ✓ 已删除原始安装脚本：${source_path}${NC}"
    else
        echo -e "${YELLOW}  ⚠ 原始安装脚本删除失败：${source_path}${NC}"
    fi
}

function source_file_is_xray_manager() {
    local source_path="$1"
    [[ -f "$source_path" && ! -L "$source_path" ]] || return 1
    grep -Fq 'DATA_DIR="/usr/local/share/doudou-xray"' "$source_path" 2>/dev/null \
        && grep -Fq 'QUICK_BIN="/usr/local/bin/zxray"' "$source_path" 2>/dev/null \
        && grep -Fq 'function cleanup_doudou_runtime' "$source_path" 2>/dev/null
}

function remove_legacy_root_script_sources() {
    local source_path
    local owner_uid=""
    local recorded_source=""

    if [[ -f "$SOURCE_RECORD_FILE" ]]; then
        recorded_source=$(head -n 1 "$SOURCE_RECORD_FILE" 2>/dev/null || true)
    fi

    for source_path in /root/*.sh; do
        [[ -e "$source_path" || -L "$source_path" ]] || continue
        [[ "$source_path" != "$SELF_SCRIPT_PATH" ]] || continue
        [[ -z "$recorded_source" || "$source_path" != "$recorded_source" ]] || continue
        source_file_is_xray_manager "$source_path" || continue
        owner_uid=$(stat -c '%u' -- "$source_path" 2>/dev/null || true)
        [[ "$owner_uid" == "0" ]] || continue
        if rm -f -- "$source_path"; then
            echo -e "${GREEN}  ✓ 已删除旧的 root 脚本源文件：${source_path}${NC}"
        fi
    done
}

function cleanup_script_temp_artifacts() {
    local temp_path
    local -a temp_paths=(
        /tmp/doudou-entry.*.sh
        /tmp/doudou-self-update.*.sh
        /tmp/xray-install.*.sh
        /tmp/xray-install-curl.*.log
        /tmp/xray-update.*.log
        /tmp/xray_config.*.json
        /tmp/xray-alpine-config.*.json
        /tmp/ssserver-foreground.*.log
        /tmp/alpine-manual-time.*.log
    )

    for temp_path in "${temp_paths[@]}"; do
        [[ -e "$temp_path" || -L "$temp_path" ]] || continue
        remove_path_quiet "$temp_path" "$temp_path"
    done
}

function cleanup_bbr_config() {
    if [[ -f "$SYSCTL_BBR_BACKUP_FILE" ]]; then
        if mv -f -- "$SYSCTL_BBR_BACKUP_FILE" "$SYSCTL_BBR_FILE"; then
            echo -e "${GREEN}  ✓ 已恢复原有 BBR 配置: ${SYSCTL_BBR_FILE}${NC}"
        else
            echo -e "${YELLOW}  ⚠ 原有 BBR 配置恢复失败，已保留备份: ${SYSCTL_BBR_BACKUP_FILE}${NC}"
        fi
        return 0
    fi

    if [[ -f "$SYSCTL_BBR_FILE" ]] && grep -q '^# BBR + FQ' "$SYSCTL_BBR_FILE"; then
        remove_path_quiet "$SYSCTL_BBR_FILE" "$SYSCTL_BBR_FILE"
    fi
}

function cleanup_doudou_runtime() {
    echo -e "${YELLOW}  清理脚本、原始源文件与临时残留...${NC}"

    remove_path_quiet "$INFO_FILE" "$INFO_FILE"
    remove_path_quiet "$SUB_FILE" "$SUB_FILE"
    remove_path_quiet "$SERVICE_KIND_FILE" "$SERVICE_KIND_FILE"
    remove_path_quiet "$ALPINE_RESOLV_BACKUP" "$ALPINE_RESOLV_BACKUP"
    remove_path_quiet "$SNI_POOL_FILE" "$SNI_POOL_FILE"
    cleanup_bbr_config
    cleanup_legacy_quick_paths
    remove_recorded_source_if_safe
    remove_current_script_source_if_safe
    remove_legacy_root_script_sources
    cleanup_script_temp_artifacts
    remove_path_quiet "$SELF_DIR" "$SELF_DIR"
    remove_path_quiet "$DATA_DIR" "$DATA_DIR"
}

function cleanup_script_only_runtime() {
    echo -e "${YELLOW}  清理脚本、原始源文件与临时残留...${NC}"

    remove_path_quiet "$INFO_FILE" "$INFO_FILE"
    remove_path_quiet "$SUB_FILE" "$SUB_FILE"
    remove_path_quiet "$SERVICE_KIND_FILE" "$SERVICE_KIND_FILE"
    remove_path_quiet "$ALPINE_RESOLV_BACKUP" "$ALPINE_RESOLV_BACKUP"
    remove_path_quiet "$SNI_POOL_FILE" "$SNI_POOL_FILE"
    cleanup_bbr_config
    cleanup_legacy_quick_paths
    remove_recorded_source_if_safe
    remove_current_script_source_if_safe
    remove_legacy_root_script_sources
    cleanup_script_temp_artifacts
    remove_path_quiet "$SELF_DIR" "$SELF_DIR"
    remove_path_quiet "$DATA_DIR" "$DATA_DIR"
}

function uninstall_script_only() {
    line
    center_echo "仅卸载脚本文件" "${RED}${BOLD}"
    line
    echo -e "${RED}  - 删除 zxray 启动命令${NC}"
    echo -e "${RED}  - 删除脚本源文件、存储目录与临时残留${NC}"
    echo -e "${RED}  - 保留当前服务、配置与 Xray / SS-Rust 运行文件${NC}"
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
    center_echo "完整卸载 Xray" "${RED}${BOLD}"
    line
    echo -e "${RED}  - 卸载 Xray${NC}"
    echo -e "${RED}  - 删除配置、服务文件、脚本源文件与生成目录${NC}"
    echo -e "${RED}  - 删除 zxray 启动命令${NC}"
    echo -e "${RED}  - 删除临时文件、日志与生成的 txt 文件${NC}"
    line
    if should_auto_confirm_uninstall; then
        echo -e "${YELLOW}  检测到快捷完整卸载：已自动确认继续。${NC}"
    else
        read -r -p "输入 yes 确认完整卸载: " CONFIRM
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
        center_echo "卸载脚本、Xray、SS-Rust" "${RED}${BOLD}"
        line
        echo -e "  ${CYAN}1.${NC} 仅卸载脚本文件"
        echo -e "  ${CYAN}2.${NC} 完整卸载脚本、Xray、SS-Rust"
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

function get_xray_binary_path() {
    if [[ -x /usr/local/bin/xray ]]; then
        printf '%s\n' '/usr/local/bin/xray'
        return 0
    fi

    if command -v xray >/dev/null 2>&1; then
        command -v xray
        return 0
    fi

    return 1
}

function is_xray_running_now() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet xray 2>/dev/null && return 0
    fi

    pgrep -x xray >/dev/null 2>&1
}

function get_xray_running_badge() {
    if is_xray_running_now; then
        printf '%b运行中%b' "$GREEN" "$NC"
    else
        printf '%b未运行%b' "$RED" "$NC"
    fi
}

function get_xray_version_badge() {
    local xray_bin=""
    local version_line=""

    xray_bin=$(get_xray_binary_path 2>/dev/null || true)
    if [[ -z "$xray_bin" ]]; then
        printf '%bN/A%b' "$YELLOW" "$NC"
        return 0
    fi

    version_line=$("$xray_bin" version 2>/dev/null | awk 'NR==1 {print $1, $2; exit}')
    if [[ -z "$version_line" ]]; then
        printf '%bN/A%b' "$YELLOW" "$NC"
        return 0
    fi

    printf '%b%s%b' "$CYAN" "$version_line" "$NC"
}

function show_main_header() {
    line
    center_echo "Xray Manager ${SCRIPT_VERSION}" "${BRIGHT_YELLOW}${BOLD}"
    center_echo "启动命令: zxray"
    line
}

if [[ "$QUICK_INSTALL" == "1" ]]; then
    run_quick_install_entry
    exit $?
fi

if [[ "$QUICK_UNINSTALL" == "1" ]]; then
    uninstall_current_service_and_delete_self
    exit $?
fi

if [[ "$QUICK_UPDATE" == "1" ]]; then
    if [[ "${DOUDOU_SELF_UPDATED:-0}" == "1" ]]; then
        update_current_service
    else
        self_update_and_update_xray
    fi
    exit $?
fi

while true; do
    clear_screen
    show_main_header
    echo -e "  ${CYAN}1.${NC} 覆盖安装"
    echo -e "  ${CYAN}2.${NC} 更新/重启 Xray"
    echo -e "  ${CYAN}3.${NC} 查看订阅链接"
    echo -e "  ${CYAN}4.${NC} 完整卸载"
    echo -e "  ${CYAN}5.${NC} 退出脚本"
    line
    read -r -p "选择: " CHOICE

    case "$CHOICE" in
        "")
            continue
            ;;
        1|01) install_default_flow    ;;
        2|02) update_restart_menu     ;;
        3|03) show_info               ;;
        4|04) uninstall_current_service_and_delete_self ;;
        5|05)
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
