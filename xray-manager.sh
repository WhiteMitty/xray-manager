#!/bin/sh

if [ -z "${BASH_VERSION:-}" ]; then
    if [ ! -f "$0" ]; then
        echo "请先把脚本下载为文件，再运行：sh xray-manager.sh" >&2
        exit 1
    fi
    if ! command -v bash >/dev/null 2>&1; then
        if [ "$(id -u)" = 0 ] && command -v apk >/dev/null 2>&1; then
            apk add --no-cache bash curl ca-certificates >/dev/null || exit 1
        else
            echo "请先安装 bash，再运行：sh xray-manager.sh" >&2
            exit 1
        fi
    fi
    exec bash "$0" "$@"
fi
set +o posix

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "需要 Bash 4.4 或更新版本。" >&2
    exit 1
fi

case "${BASH_SOURCE[0]:-}" in
    ''|/dev/stdin|/dev/fd/*|/proc/self/fd/*|/proc/[0-9]*/fd/*)
        echo "请先把脚本下载为文件，再运行：sh xray-manager.sh" >&2
        exit 1
        ;;
esac

set -Eeuo pipefail
umask 077

readonly SCRIPT_VERSION="0.2.0"
readonly SCRIPT_MARKER="XRAY_MANAGER_DOUDOU"
readonly SCRIPT_REMOTE_URL="https://raw.githubusercontent.com/WhiteMitty/xray-manager/main/xray-manager.sh"
readonly XRAY_MIN_VERSION="26.3.27"
readonly STATE_SCHEMA=3
readonly SERVICE_USER="zxray"
readonly MANAGED_TAG="# Managed by Xray Manager"
readonly SCHEMES=(reality-raw reality-xhttp reality-split ss enc dual triple enc-split)
readonly DEFAULT_SNI_POOL=(c.6sc.co www.amazon.com drivers.amd.com a0.awsstatic.com d1.awsstatic.com
    s0.awsstatic.com gateway.icloud.com m.media-amazon.com addons.mozilla.org tag.demandbase.com
    t0.m.awsstatic.com images-na.ssl-images-amazon.com)

init_paths() {
    ROOT=${1:-}
    DATA_DIR=$ROOT/usr/local/share/doudou-xray
    SELF_DIR=$ROOT/usr/local/lib/doudou
    SELF_SCRIPT_PATH=$SELF_DIR/xray_manager.sh
    QUICK_BIN=$ROOT/usr/local/bin/zxray
    STATE=$DATA_DIR/state.json
    CONFIG_DIR=$ROOT/usr/local/etc/xray
    CONFIG_FILE=$CONFIG_DIR/config.json
    XRAY_BIN=$ROOT/usr/local/bin/xray
    XRAY_ASSET_DIR=$ROOT/usr/local/share/xray
    SS_BIN=$SELF_DIR/ssserver
    SS_CONFIG=$DATA_DIR/ssserver.json
    SS_ACL=$DATA_DIR/ssserver.acl
    NGINX_DIR=$DATA_DIR/nginx
    NGINX_RUN=$ROOT/run/zxray-nginx
    NODES_JSON=$DATA_DIR/nodes.json
    INFO_FILE=$DATA_DIR/xray_node_info.txt
    SUB_FILE=$DATA_DIR/xray_subscription.txt
    SUB_B64=$DATA_DIR/xray_subscription.base64
    SNI_POOL_FILE=$DATA_DIR/.xray_sni_pool
    TX=$ROOT/usr/local/share/doudou-xray-transaction
    STAGE_BASE=$ROOT/usr/local/share/doudou-xray-stage
    LOCK_FILE=$ROOT/run/lock/doudou-xray-manager.lock
    SYSCTL_FILE=$ROOT/etc/sysctl.d/99-zxray-bbr.conf
    SYSTEMD_DIR=$ROOT/etc/systemd/system
    OPENRC_DIR=$ROOT/etc/init.d
    MANAGED_PATHS=(
        "$DATA_DIR" "$SELF_DIR" "$CONFIG_DIR" "$XRAY_BIN" "$XRAY_ASSET_DIR"
        "$SYSTEMD_DIR/xray.service" "$SYSTEMD_DIR/zxray-ss.service" "$SYSTEMD_DIR/zxray-nginx.service"
        "$OPENRC_DIR/xray" "$OPENRC_DIR/zxray-ss" "$OPENRC_DIR/zxray-nginx"
        "$ROOT/etc/logrotate.d/zxray" "$QUICK_BIN" "$SYSCTL_FILE"
    )
    MANAGED_SERVICES=(xray zxray-ss zxray-nginx)
}
init_paths

OS_FAMILY='' INIT='' PKG=''
ACTION=menu ASSUME_YES=0 FORCE=0 CLI_SCHEME='' CLI_CORE_TAG=''
ASSUME_YES_FLAG=()
STAGE='' TX_ACTIVE=0 KEEP_TX=0 ACTION_PID='' CHILD_RUNNING=0
INPUT_FD=0 SOURCE_PATH='' DRAFT='' CHECK_PID=''
STEP_NO=0 STEP_TOTAL=0 STEP_OPEN=0 STEP_LOG=''
CHILD_RC=0 SUB_RC=0 TOP_RC=0 STATE_READY=0
MODE=new PREVIEW_RESULT=1
PREVIEW_NOTES=()
NET_V4='' NET_V6=''
SNI_BEST_MS=0
PARSE_ERR=''
SERVICE_USER_CREATED=0
NGINX_MODULE_LINE='' NGINX_REJECT_TLS=1
USE_XRAY='' USE_XRAY_ASSET='' USE_SS=''
NEW_XRAY=0 NEW_SS=0
UI_W=60 LABEL_W=10
C_RED='' C_GREEN='' C_YELLOW='' C_HI='' C_RESET=''

ui_setup_locale() {
    local loc
    for loc in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
        if LC_ALL=$loc bash -c 's="端口"; [[ ${#s} == 2 ]]' 2>/dev/null; then
            export LC_ALL=$loc
            return 0
        fi
    done
    export LC_ALL=C.UTF-8
}

ui_setup() {
    ui_setup_locale
    local cols=''
    if [[ -t 1 ]]; then
        cols=$(tput cols 2>/dev/null || true)
        [[ $cols =~ ^[0-9]+$ ]] || cols=$(stty size 2>/dev/null | awk '{print $2}' || true)
    fi
    if [[ $cols =~ ^[0-9]+$ ]]; then
        UI_W=$(( cols < 60 ? cols : 60 ))
        (( UI_W >= 40 )) || UI_W=40
    fi
    if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
        C_RED=$'\e[31m'
        C_GREEN=$'\e[32m'
        C_YELLOW=$'\e[33m'
        C_HI=$'\e[1;93m'
        C_RESET=$'\e[0m'
    fi
}

byte_len() { local LC_ALL=C; printf -v "$2" '%d' "${#1}"; }

str_width() {
    local __sw_s=$1 __sw_c __sw_b
    __sw_c=${#__sw_s}
    byte_len "$__sw_s" __sw_b
    printf -v "$2" '%d' $(( __sw_c + (__sw_b - __sw_c) / 2 ))
}

pad_to() {
    local __pt_s=$1 __pt_w=$2 __pt_cur
    str_width "$__pt_s" __pt_cur
    if (( __pt_cur < __pt_w )); then
        printf -v "$3" '%s%*s' "$__pt_s" $(( __pt_w - __pt_cur )) ''
    else
        printf -v "$3" '%s ' "$__pt_s"
    fi
}

fit_width() {
    local __fw_s=$1 __fw_max=$2 __fw_cur __fw_out __fw_head __fw_tail __fw_i __fw_ch __fw_w __fw_acc
    str_width "$__fw_s" __fw_cur
    if (( __fw_cur <= __fw_max )); then
        printf -v "$3" '%s' "$__fw_s"
        return 0
    fi
    if (( __fw_max < 8 )); then
        printf -v "$3" '%s' "${__fw_s:0:__fw_max}"
        return 0
    fi
    __fw_head=$(( (__fw_max - 3) * 3 / 5 ))
    __fw_tail=$(( __fw_max - 3 - __fw_head ))
    __fw_out='' __fw_acc=0
    for (( __fw_i = 0; __fw_i < ${#__fw_s}; __fw_i++ )); do
        __fw_ch=${__fw_s:__fw_i:1}
        str_width "$__fw_ch" __fw_w
        (( __fw_acc + __fw_w <= __fw_head )) || break
        __fw_out+=$__fw_ch
        __fw_acc=$(( __fw_acc + __fw_w ))
    done
    local __fw_back='' __fw_bacc=0
    for (( __fw_i = ${#__fw_s} - 1; __fw_i >= 0; __fw_i-- )); do
        __fw_ch=${__fw_s:__fw_i:1}
        str_width "$__fw_ch" __fw_w
        (( __fw_bacc + __fw_w <= __fw_tail )) || break
        __fw_back=$__fw_ch$__fw_back
        __fw_bacc=$(( __fw_bacc + __fw_w ))
    done
    printf -v "$3" '%s...%s' "$__fw_out" "$__fw_back"
}

ui_rule() {
    local l
    printf -v l '%*s' "$UI_W" ''
    printf '%s\n' "${l// /-}"
}

ui_line() { printf '  %s\n' "$*"; }
ui_blank() { printf '\n'; }
ui_ok() { printf '  %s%s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
ui_warn() { printf '  %s%s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
ui_err() { printf '  %s%s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
die() { ui_err "$*"; return 1; }
fatal() { ui_err "$*"; exit 1; }

ui_title() {
    local text=$1 color=${2:-}
    ui_rule
    if [[ -n $color ]]; then
        printf '  %s%s%s\n' "$color" "$text" "$C_RESET"
    else
        printf '  %s\n' "$text"
    fi
    ui_rule
}

ui_item() {
    local key=$1 label=$2 value=${3:-} padded avail fitted
    if [[ -z $value ]]; then
        printf '  %s  %s\n' "$key" "$label"
        return 0
    fi
    pad_to "$label" "$LABEL_W" padded
    avail=$(( UI_W - 5 - LABEL_W ))
    fit_width "$value" "$avail" fitted
    printf '  %s  %s%s\n' "$key" "$padded" "$fitted"
}

ui_kv() {
    local label=$1 value=${2:-} padded avail fitted
    pad_to "$label" "$LABEL_W" padded
    avail=$(( UI_W - 2 - LABEL_W ))
    fit_width "$value" "$avail" fitted
    printf '  %s%s\n' "$padded" "$fitted"
}

ui_section() {
    ui_blank
    printf '  %s%s%s\n' "$C_HI" "$1" "$C_RESET"
}

ui_footer() {
    ui_rule
    if [[ -n $ACTION_PID ]]; then printf '  %s   b 主页\n' "$*"; else printf '  %s\n' "$*"; fi
}

ui_step() {
    local label=$1 w dots
    STEP_NO=$(( STEP_NO + 1 ))
    str_width "$label" w
    dots=$(( 28 - w - 1 ))
    (( dots >= 3 )) || dots=3
    local d
    printf -v d '%*s' "$dots" ''
    printf '  [%d/%d] %s %s ' "$STEP_NO" "$STEP_TOTAL" "$label" "${d// /.}"
    STEP_OPEN=1
}
ui_step_done() {
    (( STEP_OPEN )) || return 0
    printf '%s完成%s\n' "$C_GREEN" "$C_RESET"
    STEP_OPEN=0
}
ui_step_fail() {
    (( STEP_OPEN )) || return 0
    printf '%s失败%s\n' "$C_RED" "$C_RESET"
    STEP_OPEN=0
}
ui_step_skip() {
    (( STEP_OPEN )) || return 0
    printf '%s\n' "${1:-跳过}"
    STEP_OPEN=0
}

ui_clear() {
    if [[ -t 1 ]]; then
        printf '\e[H\e[2J'
    fi
}


input_setup() {
    if [[ -t 0 ]]; then
        INPUT_FD=0
    elif [[ -r /dev/tty && -w /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; then
        exec 3<> /dev/tty
        INPUT_FD=3
    else
        INPUT_FD=0
    fi
}

input_is_tty() { [[ -t $INPUT_FD ]]; }

ui_flush() {
    input_is_tty || return 0
    while read -r -s -t 0 -u "$INPUT_FD" 2>/dev/null; do
        read -r -s -n 256 -t 0.05 -u "$INPUT_FD" || break
    done
    return 0
}

input_eof() {
    printf '\n'
    if [[ -n $ACTION_PID ]]; then
        exit 130
    fi
    exit 0
}

go_home_if_b() {
    if [[ $1 == b || $1 == B ]] && [[ -n $ACTION_PID ]]; then exit 130; fi
    return 0
}

read_line() {
    local __rl_p=$1 __rl_v=''
    ui_flush
    printf '  %s' "$__rl_p"
    IFS= read -r -u "$INPUT_FD" __rl_v || input_eof
    input_is_tty || printf '%s\n' "$__rl_v"
    __rl_v=${__rl_v#"${__rl_v%%[![:space:]]*}"}
    __rl_v=${__rl_v%"${__rl_v##*[![:space:]]}"}
    go_home_if_b "$__rl_v"
    printf -v "$2" '%s' "$__rl_v"
}

ask_yes() {
    local a
    (( ASSUME_YES )) && return 0
    while :; do
        read_line "$1 [Y/n]：" a
        case $a in
            ''|y|Y) return 0 ;;
            n|N) return 1 ;;
        esac
        ui_warn '请输入 y 或 n。'
    done
}

ask_no() {
    local a
    (( ASSUME_YES )) && return 0
    while :; do
        read_line "$1 [y/N]：" a
        case $a in
            y|Y) return 0 ;;
            ''|n|N) return 1 ;;
        esac
        ui_warn '请输入 y 或 n。'
    done
}

ask_number() {
    local __an_pr=$1 __an_min=$2 __an_max=$3 __an_def=${4:-} __an_n
    while :; do
        if [[ -n $__an_def ]]; then
            read_line "$__an_pr（$__an_min-$__an_max，回车默认 $__an_def）：" __an_n
            [[ -n $__an_n ]] || __an_n=$__an_def
        else
            read_line "$__an_pr（$__an_min-$__an_max）：" __an_n
        fi
        if [[ $__an_n =~ ^[0-9]{1,9}$ ]] && (( 10#$__an_n >= __an_min && 10#$__an_n <= __an_max )); then
            printf -v "$5" '%d' $(( 10#$__an_n ))
            return 0
        fi
        ui_warn "请输入 $__an_min-$__an_max 之间的整数。"
    done
}

ask_choice() {
    local __ac_var=$1 __ac_def=$2 __ac_i __ac_k
    shift 2
    local -a __ac_opts=("$@")
    for __ac_i in "${!__ac_opts[@]}"; do
        ui_item "$((__ac_i + 1))" "${__ac_opts[$__ac_i]}"
    done
    while :; do
        read_line "请选择（回车默认 $__ac_def，0 返回）：" __ac_k
        [[ -n $__ac_k ]] || __ac_k=$__ac_def
        if [[ $__ac_k == 0 ]]; then
            printf -v "$__ac_var" '%s' ''
            return 0
        fi
        if [[ $__ac_k =~ ^[1-9]$ ]] && (( __ac_k <= ${#__ac_opts[@]} )); then
            printf -v "$__ac_var" '%s' "$__ac_k"
            return 0
        fi
        ui_warn '请选择列表中的编号。'
    done
}

index_of() {
    local __ix_var=$1 __ix_cur=$2 __ix_i=0 __ix_n=1 __ix_v
    shift 2
    for __ix_v in "$@"; do
        __ix_i=$(( __ix_i + 1 ))
        if [[ $__ix_v == "$__ix_cur" ]]; then __ix_n=$__ix_i; break; fi
    done
    printf -v "$__ix_var" '%d' "$__ix_n"
}

ui_pause() {
    local k
    read_line '回车返回：' k
}


have() { command -v "$1" >/dev/null 2>&1; }

ver_ge() {
    local a=${1#v} b=${2#v}
    [[ $(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1) == "$b" ]]
}

rand_hex() { openssl rand -hex "$1"; }
rand_b64() { openssl rand -base64 "$1" | tr -d '\n'; }
new_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        local h
        h=$(rand_hex 16)
        printf '%s-%s-4%s-%x%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" $(( (16#${h:16:1} & 3) | 8 )) "${h:17:3}" "${h:20:12}"
    fi
}

random_path() { printf '/%s/' "$(rand_hex 6)"; }

url_encode() { printf '%s' "$1" | jq -sRr @uri; }

b64url_nopad() { printf '%s' "$1" | base64 | tr -d '\r\n=' | tr '+/' '-_'; }

b64_oneline() { base64 | tr -d '\r\n'; }

sha256_of() { sha256sum "$1" | awk '{print $1}'; }


valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

valid_domain() {
    local d=$1 label
    [[ ${#d} -le 253 && $d == *.* && $d != *[!a-zA-Z0-9.-]* ]] || return 1
    [[ $d != *. && $d != .* && $d != *..* ]] || return 1
    local -a labels=()
    IFS=. read -r -a labels <<< "$d"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 && $label != -* && $label != *- ]] || return 1
    done
    [[ ${labels[-1]} != *[0-9]* || ${labels[-1]} == *[a-zA-Z]* ]]
}

valid_ipv4() {
    [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local o
    local -a octets=()
    IFS=. read -r -a octets <<< "$1"
    for o in "${octets[@]}"; do
        (( 10#$o <= 255 )) || return 1
    done
}

valid_ipv6() {
    local a=$1 part count=0
    [[ $a == *:* && $a != *[!0-9a-fA-F:]* && ${#a} -le 39 && $a != *:::* ]] || return 1
    if [[ $a == *::* ]]; then
        local rest=${a#*::}
        [[ $rest != *::* ]] || return 1
    else
        [[ $a != :* && $a != *: ]] || return 1
    fi
    local -a parts=()
    IFS=: read -r -a parts <<< "$a"
    for part in "${parts[@]}"; do
        [[ -n $part ]] || continue
        (( ${#part} <= 4 )) || return 1
        count=$(( count + 1 ))
    done
    if [[ $a == *::* ]]; then (( count < 8 )); else (( count == 8 )); fi
}

valid_host() { valid_ipv4 "$1" || valid_ipv6 "$1" || valid_domain "$1"; }

uri_host() {
    if [[ $1 == *:* && $1 != \[*\] ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}


atomic_install() {
    local src=$1 dest=$2 mode=${3:-600} tmp
    mkdir -p -- "$(dirname -- "$dest")"
    tmp=$(mktemp "$dest.new.XXXXXX")
    if ! cp -- "$src" "$tmp" || ! chmod "$mode" "$tmp" || ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        die "无法写入 $dest"
    fi
}

atomic_write() {
    local dest=$1 mode=${2:-600} tmp
    mkdir -p -- "$(dirname -- "$dest")"
    tmp=$(mktemp "$dest.new.XXXXXX")
    if ! cat > "$tmp" || ! chmod "$mode" "$tmp" || ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        die "无法写入 $dest"
    fi
}

is_managed_file() { [[ -f $1 ]] && grep -q "^$MANAGED_TAG" "$1" 2>/dev/null; }

human_bytes() {
    local b=$1
    if (( b >= 1048576 && b % 1048576 == 0 )); then printf '%dM' $(( b / 1048576 ))
    elif (( b >= 1024 && b % 1024 == 0 )); then printf '%dK' $(( b / 1024 ))
    else printf '%d' "$b"; fi
}


detect_system() {
    local id='' like=''
    if [[ -r $ROOT/etc/os-release ]]; then
        id=$(awk -F= '$1=="ID"{gsub(/"/,"",$2);print $2;exit}' "$ROOT/etc/os-release")
        like=$(awk -F= '$1=="ID_LIKE"{gsub(/"/,"",$2);print $2;exit}' "$ROOT/etc/os-release")
    fi
    case " $id $like " in
        *" alpine "*) OS_FAMILY=alpine PKG=apk ;;
        *" debian "*|*" ubuntu "*) OS_FAMILY=debian PKG=apt ;;
        *" rhel "*|*" centos "*|*" fedora "*|*" rocky "*|*" almalinux "*|*" ol "*)
            OS_FAMILY=rhel
            if have dnf; then PKG=dnf; else PKG=yum; fi ;;
        *" arch "*|*" manjaro "*) OS_FAMILY=arch PKG=pacman ;;
        *) ui_err "暂不支持 ${id:-此系统}。"; die '支持：Debian、Ubuntu、Alpine、RHEL 系、Arch。'; return 1 ;;
    esac
    if [[ -d $ROOT/run/systemd/system ]]; then
        INIT=systemd
    elif have rc-service && [[ $OS_FAMILY == alpine ]]; then
        INIT=openrc
    else
        die '需要 systemd，或 Alpine 上的 OpenRC。'
        return 1
    fi
}

pkg_install() {
    case $PKG in
        apk) apk add --no-cache "$@" 3>&- 9>&- ;;
        apt) DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq "$@" 3>&- 9>&- ;;
        dnf) dnf install -y -q "$@" 3>&- 9>&- ;;
        yum) yum install -y -q "$@" 3>&- 9>&- ;;
        pacman) pacman -S --noconfirm --needed "$@" 3>&- 9>&- ;;
    esac
}

pkg_refresh() {
    case $PKG in
        apt) apt-get -o DPkg::Lock::Timeout=180 update -qq 3>&- 9>&- ;;
        pacman) pacman -Sy --noconfirm 3>&- 9>&- ;;
        *) : ;;
    esac
}

pkg_remove() {
    (( $# )) || return 0
    case $PKG in
        apk) apk del "$@" 3>&- 9>&- ;;
        apt) DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 purge -y -qq "$@" 3>&- 9>&- ;;
        dnf) dnf remove -y -q "$@" 3>&- 9>&- ;;
        yum) yum remove -y -q "$@" 3>&- 9>&- ;;
        pacman) pacman -Rns --noconfirm "$@" 3>&- 9>&- ;;
    esac
}

pkg_installed() {
    case $PKG in
        apk) apk info -e "$1" >/dev/null 2>&1 ;;
        apt) [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true) == installed ]] ;;
        dnf|yum) rpm -q "$1" >/dev/null 2>&1 ;;
        pacman) pacman -Q "$1" >/dev/null 2>&1 ;;
    esac
}

ensure_deps() {
    local -a need=() c
    local -A pkg_of=()
    case $PKG in
        apk) pkg_of=([curl]=curl [jq]=jq [openssl]=openssl [unzip]=unzip [tar]=tar [xz]=xz [sha256sum]=coreutils
                [timeout]=coreutils [shuf]=coreutils [flock]=util-linux [ss]=iproute2 [pgrep]=procps [base64]=coreutils
                [date]=coreutils [setcap]=libcap-setcap [bash]=bash) ;;
        apt) pkg_of=([curl]=curl [jq]=jq [openssl]=openssl [unzip]=unzip [tar]=tar [xz]=xz-utils [sha256sum]=coreutils
                [timeout]=coreutils [shuf]=coreutils [flock]=util-linux [ss]=iproute2 [pgrep]=procps [base64]=coreutils
                [date]=coreutils [bash]=bash) ;;
        dnf|yum) pkg_of=([curl]=curl [jq]=jq [openssl]=openssl [unzip]=unzip [tar]=tar [xz]=xz [sha256sum]=coreutils
                [timeout]=coreutils [shuf]=coreutils [flock]=util-linux [ss]=iproute [pgrep]=procps-ng [base64]=coreutils
                [date]=coreutils [bash]=bash) ;;
        pacman) pkg_of=([curl]=curl [jq]=jq [openssl]=openssl [unzip]=unzip [tar]=tar [xz]=xz [sha256sum]=coreutils
                [timeout]=coreutils [shuf]=coreutils [flock]=util-linux [ss]=iproute2 [pgrep]=procps-ng [base64]=coreutils
                [date]=coreutils [bash]=bash) ;;
    esac
    for c in "${!pkg_of[@]}"; do
        [[ $c == setcap && $INIT != openrc ]] && continue
        have "$c" || need+=("${pkg_of[$c]}")
    done
    if [[ $PKG == apk ]] && ! date +%N 2>/dev/null | grep -qE '^[0-9]+$'; then need+=(coreutils); fi
    (( ${#need[@]} )) || return 0
    mapfile -t need < <(printf '%s\n' "${need[@]}" | sort -u)
    ui_line "准备基础依赖：${need[*]}"
    pkg_refresh >/dev/null 2>&1 || true
    if ! pkg_install "${need[@]}" >/dev/null 2>&1; then
        die "依赖安装失败：${need[*]}。请检查软件源后重试。"
        return 1
    fi
}


svc_exists() {
    if [[ $INIT == openrc ]]; then [[ -f $OPENRC_DIR/$1 ]]
    else [[ $(systemctl show "$1" -p LoadState --value 2>/dev/null || true) == loaded ]]; fi
}
svc_active() {
    if [[ $INIT == openrc ]]; then rc-service "$1" status >/dev/null 2>&1
    else systemctl is-active --quiet "$1" 2>/dev/null; fi
}
svc_enabled() {
    if [[ $INIT == openrc ]]; then [[ -e $ROOT/etc/runlevels/default/$1 ]]
    else systemctl is-enabled --quiet "$1" 2>/dev/null; fi
}
svc_do() {
    local action=$1 name=$2
    if [[ $INIT == openrc ]]; then
        case $action in
            enable) rc-update add "$name" default >/dev/null 2>>"${STEP_LOG:-/dev/null}" 3>&- 9>&- ;;
            disable) rc-update del "$name" default >/dev/null 2>>"${STEP_LOG:-/dev/null}" 3>&- 9>&- ;;
            *) rc-service "$name" "$action" >/dev/null 2>>"${STEP_LOG:-/dev/null}" 3>&- 9>&- ;;
        esac
    else
        systemctl "$action" "$name" >/dev/null 2>>"${STEP_LOG:-/dev/null}" 3>&- 9>&-
    fi
}
svc_stop_disable() {
    svc_exists "$1" || return 0
    if svc_active "$1"; then svc_do stop "$1" || true; fi
    if svc_enabled "$1"; then svc_do disable "$1" || true; fi
    return 0
}
svc_reload_units() {
    if [[ $INIT == systemd ]]; then systemctl daemon-reload; fi
}

write_service() {
    local name=$1 cmd=$2 args=$3 desc=$4 user=$5 lowport=$6 env=${7:-} rw=${8:-} run=${9:-}
    if [[ $INIT == systemd ]]; then
        {
            printf '%s\n' "$MANAGED_TAG"
            printf '[Unit]\nDescription=%s\nAfter=network-online.target\nWants=network-online.target\n\n' "$desc"
            printf '[Service]\nType=simple\n'
            if [[ -n $run ]]; then printf 'RuntimeDirectory=%s\nRuntimeDirectoryMode=0755\nRuntimeDirectoryPreserve=no\n' "$run"; fi
            if [[ $user != root ]]; then printf 'User=%s\nGroup=%s\n' "$user" "$user"; fi
            if [[ -n $env ]]; then printf 'Environment=%s\n' "$env"; fi
            printf 'ExecStart=%s %s\n' "$cmd" "$args"
            printf 'Restart=on-failure\nRestartSec=3\nLimitNOFILE=1048576\n'
            if [[ $user != root ]]; then
                if (( lowport )); then
                    printf 'AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE\n'
                else
                    printf 'CapabilityBoundingSet=\n'
                fi
                printf 'NoNewPrivileges=true\n'
            fi
            printf 'ProtectSystem=full\nProtectHome=true\nPrivateTmp=true\n'
            if [[ -n $rw ]]; then printf 'ReadWritePaths=%s\n' "$rw"; fi
            printf '\n'
            printf '[Install]\nWantedBy=multi-user.target\n'
        } > "$SYSTEMD_DIR/$name.service"
        chmod 644 "$SYSTEMD_DIR/$name.service"
    else
        {
            printf '#!/sbin/openrc-run\n%s\n' "$MANAGED_TAG"
            printf 'name="%s"\n' "$desc"
            printf 'supervisor="supervise-daemon"\n'
            printf 'command="%s"\n' "$cmd"
            printf 'command_args="%s"\n' "$args"
            if [[ $user != root ]]; then printf 'command_user="%s:%s"\n' "$user" "$user"; fi
            if [[ -n $env ]]; then printf 'supervise_daemon_args="--env %s"\n' "$env"; fi
            printf 'pidfile="/run/%s.pid"\n' "$name"
            printf 'rc_ulimit="-n 1048576"\n'
            printf 'respawn_delay=3\nrespawn_max=5\nrespawn_period=60\n'
            printf 'output_log="%s/log/%s.log"\nerror_log="%s/log/%s.log"\n' "$DATA_DIR" "$name" "$DATA_DIR" "$name"
            printf '\ndepend() {\n    need net\n    after firewall\n}\n'
            if [[ -n $run ]]; then printf '\nstart_pre() {\n    checkpath --directory --mode 0755 /run/%s\n}\n' "$run"; fi
        } > "$OPENRC_DIR/$name"
        chmod 755 "$OPENRC_DIR/$name"
        sh -n "$OPENRC_DIR/$name"
    fi
}

grant_lowport() {
    local bin=$1 want=$2
    [[ $INIT == openrc ]] || return 0
    if (( want )); then
        have setcap || pkg_install libcap-setcap >/dev/null 2>&1 || true
        have setcap || { die '缺少 setcap，服务无法以非 root 身份用低端口。'; return 1; }
        setcap 'cap_net_bind_service=+ep' "$bin"
    elif have setcap; then
        setcap -r "$bin" 2>/dev/null || true
    fi
    return 0
}


user_exists() { id "$1" >/dev/null 2>&1; }

ensure_service_user() {
    user_exists "$SERVICE_USER" && return 0
    local nologin=/usr/sbin/nologin
    [[ -x $nologin ]] || nologin=/sbin/nologin
    [[ -x $nologin ]] || nologin=/bin/false
    if have useradd; then
        useradd --system --no-create-home --home-dir /nonexistent --shell "$nologin" --user-group "$SERVICE_USER"
    elif have adduser; then
        addgroup -S "$SERVICE_USER" 2>/dev/null || true
        adduser -S -D -H -h /nonexistent -s "$nologin" -G "$SERVICE_USER" "$SERVICE_USER"
    else
        die '无法创建运行用户（缺少 useradd/adduser）。'
        return 1
    fi
    if [[ -n $TX && -d $TX ]]; then touch "$TX/created-user"; fi
    SERVICE_USER_CREATED=1
}

remove_service_user() {
    user_exists "$SERVICE_USER" || return 0
    if have userdel; then userdel "$SERVICE_USER" 2>/dev/null || true
    elif have deluser; then deluser "$SERVICE_USER" 2>/dev/null || true; fi
    if getent group "$SERVICE_USER" >/dev/null 2>&1; then
        if have groupdel; then groupdel "$SERVICE_USER" 2>/dev/null || true
        elif have delgroup; then delgroup "$SERVICE_USER" 2>/dev/null || true; fi
    fi
    return 0
}

selinux_enforcing() {
    have getenforce && [[ $(getenforce 2>/dev/null || true) == Enforcing ]]
}

install_bin() {
    atomic_install "$1" "$2" 755
    if have getenforce && [[ $(getenforce 2>/dev/null || true) != Disabled ]] && have chcon; then
        chcon -t bin_t -- "$2" 2>/dev/null || true
    fi
}


acquire_lock() {
    mkdir -p -- "$(dirname -- "$LOCK_FILE")"
    exec 9> "$LOCK_FILE"
    if ! flock -n 9; then
        fatal '另一个 Xray Manager 正在运行，请等它结束后再试。'
    fi
}


svc_state_line() {
    local s=$1 a=0 e=0
    if svc_active "$s"; then a=1; fi
    if svc_enabled "$s"; then e=1; fi
    printf '%s %s %s\n' "$s" "$a" "$e"
}

tx_begin() {
    if [[ -e $TX ]]; then
        ui_err '发现未完成的操作，请重新运行脚本先恢复。'
        ui_line "快照：$TX"
        return 1
    fi
    mkdir -p "$TX/backup"
    chmod 700 "$TX"
    local i p s
    for i in "${!MANAGED_PATHS[@]}"; do
        p=${MANAGED_PATHS[$i]}
        if [[ -e $p || -L $p ]]; then cp -a -- "$p" "$TX/backup/$i"; fi
    done
    : > "$TX/services"
    for s in "${MANAGED_SERVICES[@]}"; do
        if svc_exists "$s"; then svc_state_line "$s" >> "$TX/services"; fi
    done
    sysctl -n net.ipv4.tcp_congestion_control > "$TX/cc" 2>/dev/null || :
    sysctl -n net.core.default_qdisc > "$TX/qdisc" 2>/dev/null || :
    : > "$TX/new-packages"
    printf '%s\n' "$INIT" > "$TX/init"
    touch "$TX/ready"
    TX_ACTIVE=1
}

tx_rollback() {
    [[ -f $TX/ready ]] || { rm -rf -- "$TX"; TX_ACTIVE=0; return 0; }
    ui_warn '正在恢复到操作前的状态...'
    local i p s active enabled failed=0
    for s in "${MANAGED_SERVICES[@]}"; do
        if svc_exists "$s"; then
            svc_do stop "$s" >/dev/null 2>&1 || true
            svc_do disable "$s" >/dev/null 2>&1 || true
        fi
    done
    for i in "${!MANAGED_PATHS[@]}"; do
        p=${MANAGED_PATHS[$i]}
        rm -rf -- "$p" || failed=1
        if [[ -e $TX/backup/$i || -L $TX/backup/$i ]]; then
            mkdir -p -- "$(dirname -- "$p")"
            cp -a -- "$TX/backup/$i" "$p" || failed=1
        fi
    done
    svc_reload_units || failed=1
    while read -r s active enabled; do
        [[ -n $s ]] || continue
        if [[ $enabled == 1 ]]; then svc_do enable "$s" >/dev/null 2>&1 || failed=1; fi
        if [[ $active == 1 ]]; then svc_do start "$s" >/dev/null 2>&1 || failed=1; fi
    done < "$TX/services"
    if [[ -s $TX/cc ]]; then sysctl -q -w "net.ipv4.tcp_congestion_control=$(cat "$TX/cc")" >/dev/null 2>&1 || true; fi
    if [[ -s $TX/qdisc ]]; then sysctl -q -w "net.core.default_qdisc=$(cat "$TX/qdisc")" >/dev/null 2>&1 || true; fi
    if [[ -s $TX/new-packages ]]; then
        local -a pkgs=()
        mapfile -t pkgs < "$TX/new-packages"
        pkg_remove "${pkgs[@]}" >/dev/null 2>&1 || failed=1
    fi
    if [[ -f $TX/created-user ]]; then remove_service_user; fi
    if (( failed )); then
        KEEP_TX=1
        ui_err '恢复没有完全成功，重新运行脚本可再次尝试。'
        ui_line "快照：$TX"
        return 1
    fi
    rm -rf -- "$TX"
    TX_ACTIVE=0
    if state_ok; then ui_line '已恢复到操作前的状态，原有节点仍可使用。'; else ui_line '已恢复到操作前的状态。'; fi
}

tx_commit() {
    rm -rf -- "$TX"
    TX_ACTIVE=0
}

tx_recover_if_needed() {
    [[ -d $TX ]] || return 0
    if [[ ! -f $TX/ready ]]; then
        rm -rf -- "$TX"
        return 0
    fi
    [[ $(cat "$TX/init" 2>/dev/null) == "$INIT" ]] || fatal '未完成事务的服务类型与当前系统不符，请手动检查。'
    ui_warn '检测到上次操作中断留下的快照。'
    if ! ask_yes '先恢复到上次操作前的状态'; then
        fatal '必须先完成恢复，才能进行新的操作。'
    fi
    TX_ACTIVE=1
    tx_rollback || fatal '恢复失败。'
}

clean_stale_stages() {
    local d
    for d in "$STAGE_BASE".*; do
        [[ -d $d ]] && rm -rf -- "$d"
    done
    return 0
}


on_action_error() {
    local code=$1 line=$2 func=${3:-} cmd=${4:-}
    [[ $BASHPID == "${ACTION_PID:-$BASHPID}" ]] || exit "$code"
    trap - ERR INT TERM HUP
    set +e
    if (( STEP_OPEN )); then ui_step_fail; fi
    if (( code == 143 )); then
        ui_err '操作被终止。'
    elif (( code != 130 )); then
        ui_err "操作没有完成（${func:-main} 第 $line 行，状态 $code）。"
        [[ -z $cmd ]] || printf '        %s\n' "$cmd" >&2
        show_step_log
    fi
    [[ -z $CHECK_PID ]] || kill "$CHECK_PID" 2>/dev/null || true
    if (( TX_ACTIVE )); then tx_rollback; fi
    [[ -z $STAGE ]] || rm -rf -- "$STAGE"
    exit "$code"
}

on_action_exit() {
    local rc=$?
    [[ $BASHPID == "${ACTION_PID:-$BASHPID}" ]] || exit "$rc"
    trap - EXIT
    set +e
    if (( STEP_OPEN )); then ui_step_fail; fi
    if (( TX_ACTIVE && ! KEEP_TX )); then tx_rollback; fi
    [[ -z $CHECK_PID ]] || kill "$CHECK_PID" 2>/dev/null || true
    [[ -z $STAGE ]] || rm -rf -- "$STAGE"
    exit "$rc"
}

show_step_log() {
    [[ -n $STEP_LOG && -s $STEP_LOG ]] || return 0
    local l
    while IFS= read -r l; do
        printf '        %s\n' "$l" >&2
    done < <(tail -n 12 "$STEP_LOG")
}

run_action() (
    set -Eeuo pipefail
    ACTION_PID=$BASHPID
    trap 'on_action_error $? $LINENO "${FUNCNAME[0]:-}" "$BASH_COMMAND"' ERR
    trap 'on_action_error 130 $LINENO' INT
    trap 'on_action_error 143 $LINENO' TERM HUP
    trap on_action_exit EXIT
    mkdir -p -- "$(dirname -- "$STAGE_BASE")"
    STAGE=$(mktemp -d "$STAGE_BASE.XXXXXXXX")
    STEP_LOG=$STAGE/step.log
    : > "$STEP_LOG"
    "$@"
)

run_child() {
    trap - ERR
    set +e
    CHILD_RUNNING=1
    run_action "$@"
    CHILD_RC=$?
    CHILD_RUNNING=0
    set -e
    if [[ -n $ACTION_PID ]]; then trap 'on_action_error $? $LINENO "${FUNCNAME[0]:-}" "$BASH_COMMAND"' ERR; fi
    return 0
}


fetch() {
    local url=$1 dest=$2
    [[ $url == https://* ]] || { die '下载地址必须是 HTTPS。'; return 1; }
    if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fLsS --retry 2 --retry-delay 2 \
        --connect-timeout 10 --max-time 600 --speed-limit 1024 --speed-time 30 -o "$dest.part" "$url" >> "$STEP_LOG" 2>&1; then
        rm -f -- "$dest.part"
        die "下载失败：$url"
        return 1
    fi
    [[ -s $dest.part ]] || { rm -f -- "$dest.part"; die "下载结果为空：$url"; return 1; }
    mv -f -- "$dest.part" "$dest"
}

latest_tag() {
    local repo=$1 url tag
    url=$(curl --proto '=https' -fsSLI -o /dev/null -w '%{url_effective}' --connect-timeout 10 --max-time 30 \
        "https://github.com/$repo/releases/latest" 2>>"$STEP_LOG" || true)
    tag=${url##*/releases/tag/}
    tag=${tag//%2F//}
    tag=${tag//%2f//}
    if [[ -z $url || $tag == "$url" || -z $tag ]]; then
        tag=$(curl --proto '=https' -fsSL --connect-timeout 10 --max-time 30 \
            "https://api.github.com/repos/$repo/releases/latest" 2>>"$STEP_LOG" | jq -r '.tag_name // empty' || true)
    fi
    [[ $tag =~ ^[A-Za-z0-9._/-]+$ ]] || { die "无法获取 $repo 的最新版本号。"; return 1; }
    printf '%s' "$tag"
}

latest_tag_quiet() {
    local t
    t=$(latest_tag "$1" 2>/dev/null) || return 1
    printf '%s' "$t"
}

normalize_tag() {
    local t=$1
    [[ $t =~ ^[0-9] ]] && t=v$t
    printf '%s' "$t"
}

arch_of() {
    case $(uname -m) in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l|armv7) printf 'arm' ;;
        armv6l) printf 'armv6' ;;
        i386|i686) printf '386' ;;
        s390x) printf 's390x' ;;
        riscv64) printf 'riscv64' ;;
        *) printf 'unknown' ;;
    esac
}


xray_version_of() { "$1" version 2>/dev/null | awk 'NR==1{print $2}'; }

download_xray() {
    local tag=$1 out=$2 asset digest base
    case $(arch_of) in
        amd64) asset=Xray-linux-64.zip ;;
        arm64) asset=Xray-linux-arm64-v8a.zip ;;
        arm) asset=Xray-linux-arm32-v7a.zip ;;
        armv6) asset=Xray-linux-arm32-v6.zip ;;
        386) asset=Xray-linux-32.zip ;;
        s390x) asset=Xray-linux-s390x.zip ;;
        riscv64) asset=Xray-linux-riscv64.zip ;;
        *) die "Xray 暂不支持此架构：$(uname -m)"; return 1 ;;
    esac
    if [[ $tag == latest ]]; then base=https://github.com/XTLS/Xray-core/releases/latest/download
    else base=https://github.com/XTLS/Xray-core/releases/download/$tag; fi
    mkdir -p "$out"
    fetch "$base/$asset" "$out/$asset"
    fetch "$base/$asset.dgst" "$out/$asset.dgst"
    digest=$(awk -F'= *' '/^SHA2-256/{print $2; exit}' "$out/$asset.dgst" | tr -d '[:space:]')
    [[ $digest =~ ^[0-9a-fA-F]{64}$ ]] || { die 'Xray 校验文件格式异常。'; return 1; }
    [[ $(sha256_of "$out/$asset") == "${digest,,}" ]] || { die 'Xray 安装包 SHA-256 校验失败。'; return 1; }
    unzip -p "$out/$asset" xray > "$out/xray"
    unzip -p "$out/$asset" geoip.dat > "$out/geoip.dat"
    unzip -p "$out/$asset" geosite.dat > "$out/geosite.dat"
    chmod 755 "$out/xray"
    rm -f -- "$out/$asset" "$out/$asset.dgst"
    local v
    v=$(xray_version_of "$out/xray")
    [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { die '无法识别下载的 Xray 版本。'; return 1; }
    ver_ge "$v" "$XRAY_MIN_VERSION" || { die "需要 Xray $XRAY_MIN_VERSION 或更新版本，当前为 $v。"; return 1; }
    printf 'v%s' "$v" > "$out/xray.version"
}


ss_triple() {
    case $(arch_of) in
        amd64) printf 'x86_64-unknown-linux-musl' ;;
        arm64) printf 'aarch64-unknown-linux-musl' ;;
        arm) printf 'armv7-unknown-linux-musleabihf' ;;
        armv6) printf 'arm-unknown-linux-musleabihf' ;;
        386) printf 'i686-unknown-linux-musl' ;;
        riscv64) printf 'riscv64gc-unknown-linux-musl' ;;
        *) return 1 ;;
    esac
}
ss_arch_supported() { ss_triple >/dev/null 2>&1; }

ss_version_of() { "$1" --version 2>/dev/null | awk '{print $2; exit}'; }

download_ss() {
    local tag=$1 out=$2 triple asset base digest member
    triple=$(ss_triple) || { die "shadowsocks-rust 暂不支持此架构：$(uname -m)"; return 1; }
    if [[ $tag == latest ]]; then tag=$(latest_tag shadowsocks/shadowsocks-rust); fi
    asset="shadowsocks-${tag}.${triple}.tar.xz"
    base=https://github.com/shadowsocks/shadowsocks-rust/releases/download/$tag
    mkdir -p "$out"
    fetch "$base/$asset" "$out/$asset"
    fetch "$base/$asset.sha256" "$out/$asset.sha256"
    digest=$(awk '{print $1; exit}' "$out/$asset.sha256")
    [[ $digest =~ ^[0-9a-fA-F]{64}$ ]] || { die 'shadowsocks-rust 校验文件格式异常。'; return 1; }
    [[ $(sha256_of "$out/$asset") == "${digest,,}" ]] || { die 'shadowsocks-rust 安装包校验失败。'; return 1; }
    member=$(tar -tJf "$out/$asset" | awk '$0=="ssserver" || $0=="./ssserver"{print; exit}')
    [[ -n $member ]] || { die '安装包中缺少 ssserver。'; return 1; }
    tar -xOJf "$out/$asset" "$member" > "$out/ssserver"
    chmod 755 "$out/ssserver"
    rm -f -- "$out/$asset" "$out/$asset.sha256"
    "$out/ssserver" --version >/dev/null 2>&1 || { die 'ssserver 无法运行。'; return 1; }
    printf '%s' "$tag" > "$out/ss.version"
}


script_version_of() {
    [[ -f $1 ]] || return 0
    awk -F'"' '/^readonly SCRIPT_VERSION=/{print $2; exit}' "$1" 2>/dev/null || true
}

download_script() {
    local out=$1
    fetch "$SCRIPT_REMOTE_URL" "$out"
    bash -n "$out" 2>>"$STEP_LOG" || { die '下载的脚本语法检查未通过。'; return 1; }
    grep -q "$SCRIPT_MARKER" "$out" || { die '下载的文件不是本脚本。'; return 1; }
    [[ -n $(script_version_of "$out") ]] || { die '无法识别下载的脚本版本。'; return 1; }
}


detect_public_ips() {
    local u
    NET_V4='' NET_V6=''
    for u in https://api.ipify.org https://ipv4.icanhazip.com https://v4.ident.me; do
        NET_V4=$(curl -4 -fsS --connect-timeout 3 --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]' || true)
        if valid_ipv4 "$NET_V4"; then break; fi
        NET_V4=''
    done
    if has_ipv6_stack; then
        for u in https://api64.ipify.org https://ipv6.icanhazip.com https://v6.ident.me; do
            NET_V6=$(curl -6 -fsS --connect-timeout 3 --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]' || true)
            if [[ $NET_V6 == *:* ]] && valid_ipv6 "$NET_V6"; then break; fi
            NET_V6=''
        done
    fi
    return 0
}

has_ipv6_stack() {
    [[ -e /proc/net/if_inet6 && $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1) == 0 ]]
}


listeners() {
    local flag=-ltnp
    [[ $1 == udp ]] && flag=-lunp
    ss -H "$flag" 2>/dev/null | awk -v p="$2" '{n = split($4, a, ":"); if (a[n] == p) print}'
}

pid_is_owned() {
    local pid=$1 exe cmd
    [[ -r /proc/$pid/cmdline ]] || return 1
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    case $exe in
        "$XRAY_BIN"|"$SS_BIN") return 0 ;;
    esac
    [[ $cmd == *nginx* && $cmd == *"$NGINX_DIR/nginx.conf"* ]] && return 0
    if [[ $cmd == 'nginx: worker process'* || $cmd == 'nginx: cache '* ]]; then
        local ppid
        ppid=$(awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)
        if [[ $ppid =~ ^[0-9]+$ ]] && (( ppid > 1 && ppid != pid )) && pid_is_owned "$ppid"; then return 0; fi
    fi
    [[ $cmd == *"$SS_BIN"* || $cmd == *"$XRAY_BIN "* ]] && return 0
    return 1
}

port_taken() {
    local proto=$1 port=$2 rows row pids pid
    rows=$(listeners "$proto" "$port")
    [[ -n $rows ]] || return 1
    while IFS= read -r row; do
        pids=$(grep -oE 'pid=[0-9]+' <<< "$row" | cut -d= -f2 || true)
        [[ -n $pids ]] || return 0
        while read -r pid; do
            pid_is_owned "$pid" || return 0
        done <<< "$pids"
    done <<< "$rows"
    return 1
}

port_owner_name() {
    local rows
    rows=$(listeners "$1" "$2")
    grep -oE 'users:\(\("[^"]+"' <<< "$rows" | head -n 1 | cut -d'"' -f2 || true
}
port_owner_label() {
    local n
    n=$(port_owner_name "$1" "$2")
    printf '%s' "${n:0:16}"
    [[ -n $n ]] || printf '其他程序'
}

port_listening() { [[ -n $(listeners "$1" "$2") ]]; }

random_free_port() {
    local p i
    for (( i = 0; i < 200; i++ )); do
        p=$(shuf -i 20000-60000 -n 1)
        if ! port_listening tcp "$p" && ! port_listening udp "$p" && ! port_in_draft "$p"; then
            printf '%s' "$p"
            return 0
        fi
    done
    die '找不到可用的随机端口。'
}


sni_pool() {
    local d
    local -a pool=()
    if [[ -f $SNI_POOL_FILE ]]; then
        while IFS= read -r d; do
            d=${d%%#*}
            d=${d//[[:space:]]/}
            [[ -n $d ]] || continue
            if valid_domain "$d"; then pool+=("${d,,}"); fi
        done < "$SNI_POOL_FILE"
    fi
    (( ${#pool[@]} )) || pool=("${DEFAULT_SNI_POOL[@]}")
    printf '%s\n' "${pool[@]}"
}

sni_probe() {
    local d=$1 log=$2
    timeout 5 openssl s_client -connect "$d:443" -servername "$d" -tls1_3 -alpn h2 \
        -verify_hostname "$d" -verify_return_error </dev/null > "$log" 2>&1 &&
        grep -q 'ALPN protocol: h2' "$log"
}

now_ms() {
    if [[ -n ${EPOCHREALTIME:-} ]]; then
        local t=${EPOCHREALTIME/./}
        printf '%s' $(( 10#$t / 1000 ))
    else
        date +%s%3N
    fi
}

sni_auto_select() {
    local __sa_out=$1 __sa_d __sa_i __sa_t1 __sa_t2 __sa_ok __sa_best='' __sa_bscore=999999999 __sa_score __sa_ms __sa_n=0 __sa_total
    local -a __sa_pool=() __sa_times=() __sa_sorted=()
    mapfile -t __sa_pool < <(sni_pool)
    __sa_total=${#__sa_pool[@]}
    local __sa_log=$STAGE/sni-probe.log
    for __sa_d in "${__sa_pool[@]}"; do
        __sa_n=$(( __sa_n + 1 ))
        if [[ -t 1 ]]; then printf '\r  SNI 测速 %d/%d：%-32s' "$__sa_n" "$__sa_total" "$__sa_d"; fi
        __sa_times=() __sa_ok=0
        for __sa_i in 1 2 3; do
            __sa_t1=$(now_ms)
            if sni_probe "$__sa_d" "$__sa_log"; then
                __sa_t2=$(now_ms)
                __sa_times+=("$(( __sa_t2 - __sa_t1 ))")
                __sa_ok=$(( __sa_ok + 1 ))
            fi
        done
        (( __sa_ok >= 2 )) || continue
        mapfile -t __sa_sorted < <(printf '%s\n' "${__sa_times[@]}" | sort -n)
        if (( __sa_ok == 3 )); then __sa_score=${__sa_sorted[1]}; else __sa_score=$(( (__sa_sorted[0] + __sa_sorted[1]) / 2 )); fi
        __sa_ms=$__sa_score
        __sa_score=$(( (3 - __sa_ok) * 1000000 + __sa_score ))
        if (( __sa_score < __sa_bscore )); then
            __sa_bscore=$__sa_score
            __sa_best=$__sa_d
            SNI_BEST_MS=$__sa_ms
        fi
    done
    if [[ -t 1 ]]; then printf '\r%*s\r' "$UI_W" ''; fi
    [[ -n $__sa_best ]] || return 1
    printf -v "$__sa_out" '%s' "$__sa_best"
}


uri_decode() {
    local data=$1 out='' ch hex i=0
    while (( i < ${#data} )); do
        ch=${data:i:1}
        if [[ $ch == % ]]; then
            hex=${data:i+1:2}
            [[ $hex =~ ^[0-9A-Fa-f]{2}$ && $hex != 00 ]] || return 1
            printf -v ch '%b' "\\x$hex"
            out+=$ch
            i=$(( i + 3 ))
            continue
        fi
        out+=$ch
        i=$(( i + 1 ))
    done
    printf '%s' "$out"
}

query_get() {
    local query=$1 key=$2 pair k
    local -a pairs=()
    IFS='&' read -r -a pairs <<< "$query"
    for pair in "${pairs[@]}"; do
        k=${pair%%=*}
        if [[ $k == "$key" ]]; then
            local v=${pair#*=}
            [[ $pair == *=* ]] || v=''
            uri_decode "${v//+/ }"
            return 0
        fi
    done
    return 1
}

b64_decode_relaxed() {
    local s=${1//-/+}
    s=${s//_//}
    case $(( ${#s} % 4 )) in
        2) s+='==' ;;
        3) s+='=' ;;
        1) return 1 ;;
    esac
    printf '%s' "$s" | base64 -d 2>/dev/null
}

normalize_link() { printf '%s' "$1" | tr -d '\r[:space:]'; }

parse_hostport() {
    local hp=$1
    if [[ $hp =~ ^\[(.*)\]:([0-9]+)$ ]]; then
        PARSED_HOST=${BASH_REMATCH[1]}
        PARSED_PORT=${BASH_REMATCH[2]}
    elif [[ $hp =~ ^([^:]+):([0-9]+)$ ]]; then
        PARSED_HOST=${BASH_REMATCH[1]}
        PARSED_PORT=${BASH_REMATCH[2]}
    else
        PARSE_ERR='地址或端口格式不正确'
        return 1
    fi
    valid_host "$PARSED_HOST" || { PARSE_ERR='地址格式不正确'; return 1; }
    valid_port "$PARSED_PORT" || { PARSE_ERR='端口需在 1-65535 之间'; return 1; }
    PARSED_PORT=$(( 10#$PARSED_PORT ))
}

parse_ss_link() {
    local link=$1 body main frag query creds hostport left right decoded
    body=${link#ss://}
    main=${body%%#*}
    frag=''
    [[ $body == *#* ]] && frag=${body#*#}
    if [[ $main == *\?* ]]; then
        PARSE_ERR='不支持带插件参数的 SS 链接'
        return 1
    fi
    main=${main%/}
    if [[ $main == *@* ]]; then
        left=${main%@*}
        right=${main##*@}
        left=$(uri_decode "$left") || { PARSE_ERR='百分号编码不正确'; return 1; }
        if [[ $left == *:* ]]; then creds=$left
        else creds=$(b64_decode_relaxed "$left") || { PARSE_ERR='用户信息无法解码'; return 1; }; fi
        hostport=$(uri_decode "$right") || { PARSE_ERR='百分号编码不正确'; return 1; }
    else
        decoded=$(b64_decode_relaxed "$(uri_decode "$main")") || { PARSE_ERR='链接无法解码'; return 1; }
        creds=${decoded%@*}
        hostport=${decoded##*@}
    fi
    [[ $creds == *:* && -n ${creds%%:*} && -n ${creds#*:} ]] || { PARSE_ERR='缺少加密方式或密码'; return 1; }
    parse_hostport "$hostport" || return 1
    local method=${creds%%:*} password=${creds#*:}
    PARSED_KIND=ss
    PARSED_LABEL=$(uri_decode "$frag" 2>/dev/null || true)
    [[ -n $PARSED_LABEL ]] || PARSED_LABEL='SS 落地'
    PARSED_OUTBOUND_JSON=$(jq -cn --arg h "$PARSED_HOST" --argjson p "$PARSED_PORT" --arg m "$method" --arg pw "$password" \
        '{protocol:"shadowsocks",settings:{servers:[{address:$h,port:$p,method:$m,password:$pw}]}}')
}

parse_vless_link() {
    local link=$1 body main frag id rest hostport query key pair canonical seen='|'
    local security encryption flow net sni pbk sid fp spx header
    body=${link#vless://}
    main=${body%%#*}
    frag=''
    [[ $body == *#* ]] && frag=${body#*#}
    id=${main%%@*}
    rest=${main#*@}
    [[ -n $id && $rest != "$main" ]] || { PARSE_ERR='缺少用户 ID'; return 1; }
    if [[ $rest == *\?* ]]; then hostport=${rest%%\?*}; query=${rest#*\?}; else hostport=$rest; query=''; fi
    hostport=${hostport%/}
    id=$(uri_decode "$id") || { PARSE_ERR='百分号编码不正确'; return 1; }
    hostport=$(uri_decode "$hostport") || { PARSE_ERR='百分号编码不正确'; return 1; }
    parse_hostport "$hostport" || return 1
    local -a pairs=()
    [[ -z $query ]] || IFS='&' read -r -a pairs <<< "$query"
    for pair in "${pairs[@]}"; do
        key=${pair%%=*}
        case $key in
            serverName) canonical=sni ;; publicKey) canonical=pbk ;; shortId) canonical=sid ;;
            fingerprint) canonical=fp ;; spiderX) canonical=spx ;; *) canonical=$key ;;
        esac
        if [[ $seen == *"|$canonical|"* ]]; then PARSE_ERR="参数重复：$key"; return 1; fi
        seen+="$canonical|"
        case $key in
            security|encryption|flow|type|sni|serverName|pbk|publicKey|sid|shortId|fp|fingerprint|spx|spiderX|headerType) ;;
            *) PARSE_ERR="暂不支持的参数：$key"; return 1 ;;
        esac
        local v=${pair#*=}
        uri_decode "$v" >/dev/null || { PARSE_ERR='百分号编码不正确'; return 1; }
    done
    security=$(query_get "$query" security || true)
    encryption=$(query_get "$query" encryption || true)
    flow=$(query_get "$query" flow || true)
    net=$(query_get "$query" type || true)
    sni=$(query_get "$query" sni || query_get "$query" serverName || true)
    pbk=$(query_get "$query" pbk || query_get "$query" publicKey || true)
    sid=$(query_get "$query" sid || query_get "$query" shortId || true)
    fp=$(query_get "$query" fp || query_get "$query" fingerprint || true)
    spx=$(query_get "$query" spx || query_get "$query" spiderX || true)
    header=$(query_get "$query" headerType || true)
    [[ -n $net && $net != raw ]] || net=tcp
    [[ $net == tcp ]] || { PARSE_ERR="只支持 TCP 类型的 VLESS 落地（当前 $net）"; return 1; }
    case $security in ''|none|reality) ;; *) PARSE_ERR="只支持 none 或 reality（当前 $security）"; return 1 ;; esac
    if [[ $security == reality && -n $encryption && $encryption != none ]]; then
        PARSE_ERR='不支持同时带 REALITY 和 VLESS-ENC 的落地'
        return 1
    fi
    [[ -z $header || $header == none ]] || { PARSE_ERR='只支持 headerType=none'; return 1; }
    [[ -z $spx || $spx == / ]] || { PARSE_ERR='无法保留自定义 spiderX'; return 1; }
    if [[ $security != reality && -n "$sni$pbk$sid$fp$spx" ]]; then
        PARSE_ERR='非 REALITY 链接带了 REALITY 参数'
        return 1
    fi
    [[ -n $encryption ]] || encryption=none
    local stream
    if [[ $security == reality ]]; then
        [[ -n $sni && -n $pbk ]] || { PARSE_ERR='REALITY 落地缺少 sni 或 pbk'; return 1; }
        [[ -n $fp ]] || fp=firefox
        stream=$(jq -cn --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg fp "$fp" \
            '{network:"raw", security:"reality",
              realitySettings:({serverName:$sni, publicKey:$pbk, fingerprint:$fp, spiderX:"/"}
                + (if $sid == "" then {} else {shortId:$sid} end))}')
    else
        stream='{"network":"raw"}'
    fi
    PARSED_KIND=vless
    PARSED_LABEL=$(uri_decode "$frag" 2>/dev/null || true)
    [[ -n $PARSED_LABEL ]] || PARSED_LABEL='VLESS 落地'
    PARSED_OUTBOUND_JSON=$(jq -cn --arg h "$PARSED_HOST" --argjson p "$PARSED_PORT" --arg id "$id" --arg enc "$encryption" \
        --arg flow "$flow" --argjson stream "$stream" \
        '{protocol:"vless",
          settings:{vnext:[{address:$h, port:$p,
            users:[({id:$id, encryption:$enc} + (if $flow == "" then {} else {flow:$flow} end))]}]},
          streamSettings:$stream}')
}

parse_landing_link() {
    PARSED_OUTBOUND_JSON='' PARSED_HOST='' PARSED_PORT='' PARSED_KIND='' PARSED_LABEL='' PARSE_ERR=''
    local link
    link=$(normalize_link "$1")
    case $link in
        ss://*) parse_ss_link "$link" ;;
        vless://*) parse_vless_link "$link" ;;
        *) PARSE_ERR='只支持 ss:// 或 vless:// 链接'; return 1 ;;
    esac
}


scheme_label() {
    case $1 in
        reality-raw) printf 'REALITY / RAW + Vision' ;;
        reality-xhttp) printf 'REALITY / XHTTP 单路 + XMUX' ;;
        reality-split) printf 'REALITY / XHTTP 上下行分离' ;;
        ss) printf 'SS2022' ;;
        enc) printf 'VLESS-ENC' ;;
        dual) printf 'SS2022 + VLESS-ENC' ;;
        triple) printf 'REALITY + SS2022 + VLESS-ENC' ;;
        enc-split) printf 'XHTTP + VLESS-ENC 上下行分离' ;;
        *) printf '%s' "$1" ;;
    esac
}

scheme_has_reality() { [[ $1 == reality-* || $1 == triple ]]; }
scheme_has_ss() { [[ $1 == ss || $1 == dual || $1 == triple ]]; }
scheme_has_enc_inbound() { [[ $1 == enc || $1 == dual || $1 == triple || $1 == enc-split ]]; }
scheme_is_split() { [[ $1 == reality-split || $1 == enc-split ]]; }
scheme_transport() {
    case $1 in
        reality-xhttp|reality-split|enc-split) printf 'xhttp' ;;
        *) printf 'raw' ;;
    esac
}


st() { jq -r "($1) // empty | if type == \"string\" or type == \"number\" then . else tojson end" "$DRAFT"; }
stj() { jq -c "$1" "$DRAFT"; }
st_filter() {
    local tmp
    tmp=$(mktemp "$DRAFT.XXXXXX")
    if jq "$@" "$DRAFT" > "$tmp"; then
        mv -f -- "$tmp" "$DRAFT"
    else
        rm -f -- "$tmp"
        die '内部错误：更新配置草稿失败。'
    fi
}
st_set() { st_filter --argjson v "$2" "$1 = \$v"; }
st_sets() { st_filter --arg v "$2" "$1 = \$v"; }

load_state_draft() {
    DRAFT=$STAGE/draft.json
    cp -f -- "$STATE" "$DRAFT"
}

scheme() { st .scheme; }

needs_nginx() {
    scheme_has_reality "$(scheme)" && [[ $(st .reality.guard) == nginx ]]
}
ss_core() {
    [[ $(scheme) == ss ]] || { printf 'xray'; return 0; }
    local n mode
    n=$(jq '.landings | length' "$DRAFT")
    mode=$(st .outbound)
    if (( n == 0 )) && ss_arch_supported && [[ $mode == v4first || $mode == v6first ]]; then
        printf 'ss-rust'
    else
        printf 'xray'
    fi
}

needs_xray() { ! needs_ss_rust; }
needs_ss_rust() { [[ $(scheme) == ss && $(ss_core) == ss-rust ]]; }

port_in_draft() {
    [[ -n $DRAFT && -f $DRAFT ]] || return 1
    jq -e --argjson p "$1" '[.reality.port, .reality.internal, .reality.gate, .enc.port, .ss.port,
        (.users[]? | .port // 0)] | index($p) != null' "$DRAFT" >/dev/null 2>&1
}

public_ports() {
    local s
    s=$(scheme)
    if scheme_has_reality "$s"; then printf 'tcp %s REALITY\n' "$(st .reality.port)"; fi
    if scheme_has_enc_inbound "$s"; then printf 'tcp %s VLESS-ENC\n' "$(st .enc.port)"; fi
    if scheme_has_ss "$s"; then
        printf 'tcp %s SS2022\n' "$(st .ss.port)"
        printf 'udp %s SS2022\n' "$(st .ss.port)"
    fi
    jq -r '.users[] | select(.port != null and .port > 0) | "tcp \(.port) \(.name)"' "$DRAFT"
    if [[ $s == ss ]]; then jq -r '.users[] | select(.port != null and .port > 0) | "udp \(.port) \(.name)"' "$DRAFT"; fi
}


draft_new() {
    local s=$1
    PREVIEW_NOTES=()
    jq -n --arg s "$s" --arg v4 "$NET_V4" --arg v6 "$NET_V6" --argjson schema "$STATE_SCHEMA" '{
        schema: $schema, scheme: $s, script: "", installed_at: "",
        net: {host: (if $v4 != "" then $v4 elif $v6 != "" then $v6 else "" end), v4: $v4, v6: $v6, manual: 0},
        outbound: (if $v4 == "" and $v6 != "" then "v6first" else "v4first" end),
        bbr: 1,
        core: {xray: "latest", ss: "latest"},
        reality: {port: 0, internal: 0, gate: 0, sni: "", sni_auto: 1, private_key: "", public_key: "", short_id: "",
                  fp: "firefox", guard: "nginx", limit: "orig", limit_custom: {ua: 8192, ur: 1024, da: 32768, dr: 2048},
                  conn_ip: 256, conn_total: 4096},
        xhttp: {path: "", xmux: null, enc: 0, split: "v6_up_v4_down"},
        enc: {port: 0, rtt: "0rtt", shape: "random", auth: "x25519", ticket: "600s", pad: "off",
              pad_client: "", pad_server: "", server_key: "", client_key: ""},
        ss: {port: 0, method: "2022-blake3-aes-128-gcm", password: ""},
        users: [{name: "direct", id: "", out: "direct"}],
        landings: [],
        meta: {nginx_packages: [], nginx_hash: "", created_user: 0, selinux_note: 0}
    }' > "$DRAFT"
    local p
    if scheme_has_reality "$s"; then
        p=443
        if port_taken tcp 443; then
            p=$(random_free_port)
            note_add "TCP 443 已被 $(port_owner_label tcp 443) 占用，改用随机端口。"
        fi
        st_set .reality.port "$p"
        if selinux_enforcing; then
            st_sets .reality.guard xray
            st_set .meta.selinux_note 1
        fi
    fi
    if scheme_has_ss "$s"; then st_set .ss.port "$(random_free_port)"; fi
    if scheme_has_enc_inbound "$s"; then st_set .enc.port "$(random_free_port)"; fi
    if [[ $(scheme_transport "$s") == xhttp ]]; then st_sets .xhttp.path "$(random_path)"; fi
    if [[ $s == enc-split ]]; then
        st_filter '.enc.rtt = "1rtt" | .enc.shape = "random" | .enc.auth = "mlkem768" | .enc.pad = "aggressive"'
    fi
    return 0
}

finalize_identity() {
    local xray=$1 s out i n id
    s=$(scheme)
    n=$(jq '.users | length' "$DRAFT")
    for (( i = 0; i < n; i++ )); do
        id=$(jq -r ".users[$i].id" "$DRAFT")
        [[ -z $id ]] || continue
        if [[ $s == ss ]] && [[ $(jq -r ".users[$i].name" "$DRAFT") != direct ]]; then
            id=$(ss_new_password)
        else
            id=$(new_uuid)
        fi
        st_filter --arg v "$id" ".users[$i].id = \$v"
    done
    if scheme_has_reality "$s"; then
        if [[ -z $(st .reality.private_key) ]]; then
            out=$("$xray" x25519)
            st_sets .reality.private_key "$(awk '/PrivateKey:|Private key:/{print $NF; exit}' <<< "$out")"
            st_sets .reality.public_key "$(awk '/Password \(PublicKey\):|Password:|Public key:/{print $NF; exit}' <<< "$out")"
        elif [[ -z $(st .reality.public_key) ]]; then
            out=$("$xray" x25519 -i "$(st .reality.private_key)")
            st_sets .reality.public_key "$(awk '/Password \(PublicKey\):|Password:|Public key:/{print $NF; exit}' <<< "$out")"
        fi
        [[ -n $(st .reality.public_key) ]] || { die '无法生成 REALITY 密钥。'; return 1; }
        [[ -n $(st .reality.short_id) ]] || st_sets .reality.short_id "$(rand_hex 8)"
        if [[ $(st .reality.guard) == nginx ]]; then
            [[ $(st .reality.internal) != 0 ]] || st_set .reality.internal "$(random_free_port)"
        else
            [[ $(st .reality.gate) != 0 ]] || st_set .reality.gate "$(random_free_port)"
        fi
    fi
    if needs_enc_keys; then
        if [[ -z $(st .enc.server_key) || -z $(st .enc.client_key) ]]; then
            local want line_dec line_enc
            out=$("$xray" vlessenc)
            if [[ $(st .enc.auth) == mlkem768 ]]; then want='Authentication: ML-KEM-768'; else want='Authentication: X25519'; fi
            line_dec=$(awk -v w="$want" 'index($0,w){f=1;next} f && /"decryption":/{sub(/.*"decryption": *"/,""); sub(/".*/,""); print; exit}' <<< "$out")
            line_enc=$(awk -v w="$want" 'index($0,w){f=1;next} f && /"encryption":/{sub(/.*"encryption": *"/,""); sub(/".*/,""); print; exit}' <<< "$out")
            [[ -n $line_dec && -n $line_enc ]] || { die '无法生成 VLESS-ENC 密钥。'; return 1; }
            st_sets .enc.server_key "${line_dec##*.}"
            st_sets .enc.client_key "${line_enc##*.}"
        fi
    fi
    if scheme_has_ss "$s" && [[ -z $(st .ss.password) ]]; then st_sets .ss.password "$(ss_new_password)"; fi
    return 0
}

ss_new_password() {
    if [[ $(st .ss.method) == *256* ]]; then rand_b64 32; else rand_b64 16; fi
}

needs_enc_keys() {
    local s
    s=$(scheme)
    scheme_has_enc_inbound "$s" && return 0
    [[ $s == reality-xhttp && $(st .xhttp.enc) == 1 ]]
}

enc_padding_preset() {
    case $1:$2 in
        gentle:client) printf '100-96-768.60-0-80.40-0-1600' ;;
        gentle:server) printf '100-128-1024.70-0-96.45-0-2048' ;;
        aggressive:client) printf '100-128-1024.75-0-96.55-0-2400.35-24-320' ;;
        aggressive:server) printf '100-160-1536.80-0-128.60-0-3200.40-32-480' ;;
        *) printf '' ;;
    esac
}
enc_string() {
    local side=$1 pad mid key
    case $(st .enc.pad) in
        off) pad='' ;;
        custom) if [[ $side == server ]]; then pad=$(st .enc.pad_server); else pad=$(st .enc.pad_client); fi ;;
        *) pad=$(enc_padding_preset "$(st .enc.pad)" "$side") ;;
    esac
    if [[ $side == server ]]; then mid=$(st .enc.ticket); key=$(st .enc.server_key)
    else mid=$(st .enc.rtt); key=$(st .enc.client_key); fi
    if [[ -n $pad ]]; then
        printf 'mlkem768x25519plus.%s.%s.%s.%s' "$(st .enc.shape)" "$mid" "$pad" "$key"
    else
        printf 'mlkem768x25519plus.%s.%s.%s' "$(st .enc.shape)" "$mid" "$key"
    fi
}

valid_padding() {
    local p=$1 seg idx=0 prob min max total=0
    [[ -n $p && $p != *[[:space:]]* ]] || return 1
    local -a segs=()
    IFS=. read -r -a segs <<< "$p"
    for seg in "${segs[@]}"; do
        [[ $seg =~ ^([0-9]{1,3})-([0-9]{1,5})-([0-9]{1,5})$ ]] || return 1
        prob=$(( 10#${BASH_REMATCH[1]} )); min=$(( 10#${BASH_REMATCH[2]} )); max=$(( 10#${BASH_REMATCH[3]} ))
        (( prob <= 100 && max >= min )) || return 1
        if (( idx == 0 )); then (( prob == 100 && min >= 35 && max >= 35 )) || return 1; fi
        if (( idx % 2 == 0 )); then total=$(( total + max )); fi
        idx=$(( idx + 1 ))
    done
    (( total <= 65553 ))
}

outbound_label() {
    case $1 in
        v4first) printf 'v4 优先' ;; v6first) printf 'v6 优先' ;;
        v4only) printf '仅 v4' ;; v6only) printf '仅 v6' ;;
    esac
}
outbound_xray_strategy() {
    case $1 in
        v4first) printf 'UseIPv4v6' ;; v6first) printf 'UseIPv6v4' ;;
        v4only) printf 'ForceIPv4' ;; v6only) printf 'ForceIPv6' ;;
    esac
}
limit_values() {
    case $(st .reality.limit) in
        orig) printf '8192 1024 32768 2048' ;;
        std) printf '262144 32768 1048576 65536' ;;
        custom) jq -r '.reality.limit_custom | "\(.ua) \(.ur) \(.da) \(.dr)"' "$DRAFT" ;;
    esac
}
limit_label() {
    case $(st .reality.limit) in
        orig) printf '原版' ;; std) printf '标准' ;; custom) printf '自定义' ;;
    esac
}

limit_text() {
    local -a lv=()
    read -r -a lv <<< "$(limit_values)"
    printf '上行 %s 后 %s/s，下行 %s 后 %s/s' "$(human_bytes "${lv[0]}")" "$(human_bytes "${lv[1]}")" \
        "$(human_bytes "${lv[2]}")" "$(human_bytes "${lv[3]}")"
}

note_add() { PREVIEW_NOTES+=("$1"); }


choose_scheme() {
    local __cs_var=$1 __cs_def=${2:-1} __cs_k i
    ui_clear
    ui_title '选择方案'
    local -a fam=(REALITY REALITY REALITY SS2022 VLESS-ENC 双协议 三协议 实验)
    local -a desc=('RAW + Vision' 'XHTTP 单路 + XMUX' 'XHTTP 上下行分离（需双栈）' 'shadowsocks-rust'
        'RAW + Vision' 'SS2022 + VLESS-ENC' 'REALITY + SS2022 + VLESS-ENC' 'XHTTP + VLESS-ENC 上下行分离')
    local padded
    for i in "${!SCHEMES[@]}"; do
        pad_to "${fam[$i]}" 11 padded
        printf '  %d  %s%s\n' $(( i + 1 )) "$padded" "${desc[$i]}"
    done
    ui_footer "回车默认 $__cs_def   0 返回"
    while :; do
        read_line '请选择：' __cs_k
        [[ -n $__cs_k ]] || __cs_k=$__cs_def
        if [[ $__cs_k == 0 ]]; then printf -v "$__cs_var" '%s' ''; return 0; fi
        if [[ $__cs_k =~ ^[1-8]$ ]]; then
            printf -v "$__cs_var" '%s' "${SCHEMES[$((__cs_k - 1))]}"
            return 0
        fi
        ui_warn '请选择 1-8。'
    done
}

scheme_index() {
    local i
    for i in "${!SCHEMES[@]}"; do
        if [[ ${SCHEMES[$i]} == "$1" ]]; then printf '%d' $(( i + 1 )); return 0; fi
    done
    printf '1'
}


preview_items() {
    case $(scheme) in
        reality-raw) printf '%s\n' port sni landings addr guard other ;;
        reality-xhttp) printf '%s\n' port sni xhttp landings addr guard other ;;
        reality-split) printf '%s\n' port sni split landings addr guard other ;;
        ss) printf '%s\n' port ssm landings addr other ;;
        enc) printf '%s\n' port encp landings addr other ;;
        dual) printf '%s\n' port ssm encp addr other ;;
        triple) printf '%s\n' port sni ssm encp addr guard other ;;
        enc-split) printf '%s\n' port split encp addr other ;;
    esac
}

item_label() {
    case $1 in
        port) printf '端口' ;; sni) printf 'SNI' ;; xhttp|split) printf 'XHTTP' ;; landings) printf '出口' ;;
        addr) printf '地址' ;; guard) printf '防护' ;; ssm) printf 'SS2022' ;; encp) printf 'VLESS-ENC' ;;
        other) printf '其他' ;;
    esac
}

item_value() {
    local s v n
    s=$(scheme)
    case $1 in
        port)
            local -a parts=()
            if scheme_has_reality "$s"; then parts+=("REALITY $(st .reality.port)"); fi
            if scheme_has_ss "$s"; then parts+=("SS $(st .ss.port)"); fi
            if scheme_has_enc_inbound "$s"; then parts+=("ENC $(st .enc.port)"); fi
            if (( ${#parts[@]} == 1 )); then v=${parts[0]##* }; else v=$(IFS=,; printf '%s' "${parts[*]}"); v=${v//,/，}; fi
            n=$(jq '[.users[] | select(.port != null and .port > 0)] | length' "$DRAFT")
            if (( n > 0 )); then v+="，落地另开 $n 个"; fi
            printf '%s' "$v" ;;
        sni)
            v=$(st .reality.sni)
            [[ -n $v ]] || { printf '未选择'; return 0; }
            local note sw
            if [[ $(st .reality.sni_auto) == 1 && $SNI_BEST_MS -gt 0 ]]; then note="（自动，$SNI_BEST_MS ms）"
            elif [[ $(st .reality.sni_auto) == 1 ]]; then note='（自动）'
            else note='（手动）'; fi
            str_width "$note" sw
            fit_width "$v" $(( UI_W - 5 - LABEL_W - sw )) v
            printf '%s%s' "$v" "$note" ;;
        xhttp)
            v="路径 $(st .xhttp.path)，XMUX "
            if [[ $(stj .xhttp.xmux) == null ]]; then v+='默认'; else v+='自定义'; fi
            if [[ $(st .xhttp.enc) == 1 ]]; then v+='，ENC 开'; else v+='，ENC 关'; fi
            printf '%s' "$v" ;;
        split)
            if [[ $(st .xhttp.split) == v6_up_v4_down ]]; then v='v6 上行 / v4 下行'; else v='v4 上行 / v6 下行'; fi
            printf '路径 %s，%s' "$(st .xhttp.path)" "$v" ;;
        landings)
            n=$(jq '.landings | length' "$DRAFT")
            if (( n == 0 )); then printf '仅直出'; else printf '直出 + %d 个落地' "$n"; fi ;;
        addr)
            if scheme_is_split "$s"; then
                printf 'v4 %s，v6 %s' "$(st .net.v4)" "$(st .net.v6)"
            else
                v=$(st .net.host)
                [[ -n $v ]] || v='未填写'
                if [[ $v == "$(st .net.v4)" && -n $(st .net.v6) ]]; then v+='，附 IPv6'; fi
                printf '%s' "$v"
            fi ;;
        guard)
            if [[ $(st .reality.guard) == nginx ]]; then
                printf 'Nginx，限速%s，连接 %s/%s' "$(limit_label)" "$(st .reality.conn_ip)" "$(st .reality.conn_total)"
            else
                printf 'Xray 内置过滤，限速%s' "$(limit_label)"
            fi ;;
        ssm) v=$(st .ss.method); printf '%s' "${v#2022-blake3-}" ;;
        encp)
            v="$(st .enc.rtt)，$(st .enc.shape)，$(st .enc.auth)"
            case $(st .enc.pad) in gentle) v+='，温和' ;; aggressive) v+='，激进' ;; custom) v+='，自定义' ;; esac
            printf '%s' "$v" ;;
        other)
            local -a o=("$(outbound_label "$(st .outbound)")")
            if [[ $(st .bbr) == 1 ]]; then o+=('BBR'); else o+=('BBR 关'); fi
            if scheme_has_reality "$s"; then o+=("$(st .reality.fp)"); fi
            o+=("$(other_core_text)")
            v=$(IFS=,; printf '%s' "${o[*]}")
            printf '%s' "${v//,/，}" ;;
    esac
}

core_label() {
    local v iv=''
    v=$(st ".core.$1")
    if [[ $MODE == modify ]]; then iv=$(installed_version "$1"); fi
    if [[ -n $iv ]]; then printf '%s' "$iv"
    elif [[ $v == latest ]]; then printf '最新'
    else printf '%s' "$v"; fi
}

preview_loop() {
    local k i key
    local -a items=()
    while :; do
        mapfile -t items < <(preview_items)
        ui_clear
        if [[ $MODE == modify ]]; then ui_title "当前配置：$(scheme_label "$(scheme)")"
        else ui_title "预览：$(scheme_label "$(scheme)")"; fi
        for i in "${!items[@]}"; do
            ui_item "$(( i + 1 ))" "$(item_label "${items[$i]}")" "$(item_value "${items[$i]}")"
        done
        for i in "${!PREVIEW_NOTES[@]}"; do ui_warn "${PREVIEW_NOTES[$i]}"; done
        if [[ $MODE == modify ]]; then ui_footer "y 应用修改   1-${#items[@]} 修改   c 换方案   0 返回"
        else ui_footer "y 开始安装   1-${#items[@]} 修改   0 返回"; fi
        read_line '请选择：' k
        case $k in
            y|Y)
                if scheme_has_reality "$(scheme)" && [[ -z $(st .reality.sni) ]]; then
                    ui_warn '需要先选择 SNI。'
                    edit_sni
                    continue
                fi
                if scheme_is_split "$(scheme)"; then
                    if [[ -z $(st .net.v4) || -z $(st .net.v6) ]]; then
                        ui_warn '需要先填写本机的 IPv4 和 IPv6 地址。'
                        edit_addr
                        continue
                    fi
                elif [[ -z $(st .net.host) ]]; then
                    ui_warn '需要先填写节点地址。'
                    edit_addr
                    continue
                fi
                PREVIEW_RESULT=0
                return 0 ;;
            0) PREVIEW_RESULT=1; return 0 ;;
            c|C) if [[ $MODE == modify ]]; then PREVIEW_RESULT=2; return 0; fi ;;
            [1-9])
                if (( k <= ${#items[@]} )); then
                    key=${items[$((k - 1))]}
                    PREVIEW_NOTES=()
                    "edit_$key"
                fi ;;
        esac
    done
}

confirm_identity_change() {
    [[ $MODE == modify ]] || return 0
    ask_no "$1，客户端需要重新导入。继续"
}


ask_port() {
    local __ap_pr=$1 __ap_cur=$2 __ap_proto=$3 __ap_p
    while :; do
        read_line "$__ap_pr（回车保持 $__ap_cur，r 随机）：" __ap_p
        [[ -n $__ap_p ]] || { printf -v "$4" '%s' "$__ap_cur"; return 0; }
        if [[ $__ap_p == r || $__ap_p == R ]]; then __ap_p=$(random_free_port); fi
        if ! valid_port "$__ap_p"; then ui_warn '端口需在 1-65535 之间。'; continue; fi
        __ap_p=$(( 10#$__ap_p ))
        if [[ $__ap_p != "$__ap_cur" ]] && port_in_draft "$__ap_p"; then ui_warn "端口 $__ap_p 已被本方案的其他入口使用。"; continue; fi
        local __ap_x __ap_busy=''
        for __ap_x in tcp udp; do
            [[ $__ap_proto == both || $__ap_proto == "$__ap_x" ]] || continue
            if port_taken "$__ap_x" "$__ap_p"; then __ap_busy=$__ap_x; break; fi
        done
        if [[ -n $__ap_busy ]]; then
            ui_warn "端口 $__ap_p/${__ap_busy^^} 已被 $(port_owner_label "$__ap_busy" "$__ap_p") 占用。"
            continue
        fi
        printf -v "$4" '%s' "$__ap_p"
        return 0
    done
}

edit_port() {
    local s k p
    s=$(scheme)
    local -a keys=() labels=()
    if scheme_has_reality "$s"; then keys+=(.reality.port); labels+=('REALITY'); fi
    if scheme_has_ss "$s"; then keys+=(.ss.port); labels+=('SS2022'); fi
    if scheme_has_enc_inbound "$s"; then keys+=(.enc.port); labels+=('VLESS-ENC'); fi
    local n
    n=$(jq '.users | length' "$DRAFT")
    local i
    for (( i = 0; i < n; i++ )); do
        if [[ $(jq -r ".users[$i].port // 0" "$DRAFT") != 0 ]]; then
            keys+=(".users[$i].port")
            labels+=("$(jq -r ".users[$i].name" "$DRAFT" | sed 's/landing/落地 /')")
        fi
    done
    local idx=0
    if (( ${#keys[@]} > 1 )); then
        ui_section '修改端口'
        for i in "${!keys[@]}"; do
            ui_item "$(( i + 1 ))" "${labels[$i]}" "$(st "${keys[$i]}")"
        done
        read_line '修改哪一个（编号，回车返回）：' k
        [[ $k =~ ^[0-9]+$ ]] && (( k >= 1 && k <= ${#keys[@]} )) || return 0
        idx=$(( k - 1 ))
    fi
    if [[ $MODE == modify ]]; then ui_warn '修改端口后，该入口的客户端需要改端口。'; fi
    local proto=tcp
    [[ ${keys[$idx]} != .ss.port && ${keys[$idx]} != .users* ]] || proto=both
    ask_port "${labels[$idx]} 端口" "$(st "${keys[$idx]}")" "$proto" p
    st_set "${keys[$idx]}" "$p"
}


edit_sni() {
    local c d
    ui_section '修改 SNI'
    ask_choice c 1 '自动测速选择' '手动输入'
    case $c in
        1)
            if ! confirm_identity_change '更换 SNI'; then return 0; fi
            if sni_auto_select d; then
                st_sets .reality.sni "$d"
                st_set .reality.sni_auto 1
            else
                ui_warn '没有通过检测的 SNI，请手动输入。'
                ui_pause
            fi ;;
        2)
            if ! confirm_identity_change '更换 SNI'; then return 0; fi
            while :; do
                read_line 'SNI 域名（回车取消）：' d
                [[ -n $d ]] || return 0
                d=${d,,}
                if ! valid_domain "$d"; then ui_warn '请输入纯域名，不含协议、端口和路径。'; continue; fi
                ui_line '检测 TLS 1.3、h2 和证书...'
                if sni_probe "$d" "$STAGE/sni-manual.log"; then
                    st_sets .reality.sni "$d"
                    st_set .reality.sni_auto 0
                    return 0
                fi
                ui_warn '该域名没有通过 TLS 1.3 / h2 / 证书检查，请换一个。'
            done ;;
    esac
}


ask_path() {
    local p
    while :; do
        read_line "路径（以 / 开头，回车保持 $(st .xhttp.path)）：" p
        [[ -n $p ]] || return 0
        if [[ $p =~ ^/[A-Za-z0-9._/-]{1,64}$ ]]; then
            st_sets .xhttp.path "$p"
            return 0
        fi
        ui_warn '路径只能包含字母、数字、点、下划线、横线和斜杠。'
    done
}

edit_xhttp() {
    local c v
    while :; do
        ui_section '修改 XHTTP'
        ui_item 1 '路径' "$(st .xhttp.path)"
        if [[ $(stj .xhttp.xmux) == null ]]; then v='客户端内核默认'; else v=$(stj .xhttp.xmux | tr -d '{}"'); fi
        ui_item 2 'XMUX' "$v"
        if [[ $(st .xhttp.enc) == 1 ]]; then v='开'; else v='关'; fi
        ui_item 3 'VLESS-ENC' "$v"
        if [[ $(st .xhttp.enc) == 1 ]]; then ui_item 4 '加密参数' "$(item_value encp)"; fi
        read_line '修改哪一项（0 返回）：' c
        case $c in
            1) if confirm_identity_change '修改路径'; then ask_path; fi ;;
            2) edit_xmux ;;
            3)
                if confirm_identity_change '切换 VLESS-ENC'; then
                    if [[ $(st .xhttp.enc) == 1 ]]; then st_set .xhttp.enc 0; else st_set .xhttp.enc 1; fi
                fi ;;
            4) if [[ $(st .xhttp.enc) == 1 ]]; then edit_encp; fi ;;
            '') continue ;;
            *) return 0 ;;
        esac
    done
}

edit_xmux() {
    local c r s cur
    cur=$(xmux_mode_index)
    ui_section '修改 XMUX'
    ui_line 'XMUX 在客户端生效，参数通过链接的 extra 传给客户端。'
    ask_choice c "$cur" '客户端内核默认（推荐）' '按每条连接的并发数' '按底层连接数'
    case $c in
        1) st_set .xhttp.xmux null ;;
        2|3)
            while :; do
                if [[ $c == 2 ]]; then read_line '每条连接的并发数区间（如 16-32）：' r
                else read_line '底层连接数区间（如 2-4）：' r; fi
                [[ $r =~ ^[0-9]{1,4}(-[0-9]{1,4})?$ ]] && break
                ui_warn '格式为数字或区间，如 16-32。'
            done
            while :; do
                read_line '每条连接复用时长区间，秒（回车默认 1800-3000）：' s
                [[ -n $s ]] || s=1800-3000
                [[ $s =~ ^[0-9]{1,6}(-[0-9]{1,6})?$ ]] && break
                ui_warn '格式为数字或区间，如 1800-3000。'
            done
            if [[ $c == 2 ]]; then
                st_set .xhttp.xmux "$(jq -cn --arg r "$r" --arg s "$s" '{maxConcurrency:$r, hMaxReusableSecs:$s}')"
            else
                st_set .xhttp.xmux "$(jq -cn --arg r "$r" --arg s "$s" '{maxConnections:$r, hMaxReusableSecs:$s}')"
            fi ;;
    esac
}

xmux_mode_index() {
    jq -r '.xhttp.xmux | if . == null or . == {} then 1 elif has("maxConcurrency") then 2 else 3 end' "$DRAFT"
}

edit_split() {
    local c v
    while :; do
        ui_section '修改 XHTTP'
        ui_item 1 '路径' "$(st .xhttp.path)"
        if [[ $(st .xhttp.split) == v6_up_v4_down ]]; then v='v6 上行 / v4 下行'; else v='v4 上行 / v6 下行'; fi
        ui_item 2 '方向' "$v"
        read_line '修改哪一项（0 返回）：' c
        case $c in
            1) if confirm_identity_change '修改路径'; then ask_path; fi ;;
            2)
                if [[ $(st .xhttp.split) == v6_up_v4_down ]]; then st_sets .xhttp.split v4_up_v6_down
                else st_sets .xhttp.split v6_up_v4_down; fi ;;
            '') continue ;;
            *) return 0 ;;
        esac
    done
}


next_landing_index() {
    jq '[.landings[].tag | ltrimstr("landing") | tonumber] | (max // 0) + 1' "$DRAFT"
}

edit_landings() {
    local c n i link idx
    while :; do
        n=$(jq '.landings | length' "$DRAFT")
        ui_section '修改出口'
        if (( n == 0 )); then ui_line '当前仅直出。'; fi
        for (( i = 0; i < n; i++ )); do
            ui_kv "$(jq -r ".landings[$i].tag" "$DRAFT" | sed 's/landing/落地 /')" \
                "$(jq -r ".landings[$i] | \"\(.kind) \(.host):\(.port)\"" "$DRAFT")"
        done
        ui_footer 'a 添加落地   d 删除落地   0 返回'
        read_line '请选择：' c
        case $c in
            a|A)
                if (( n >= 10 )); then ui_warn '最多 10 个落地。'; continue; fi
                while :; do
                    read_line '落地链接（ss:// 或 vless://，回车取消）：' link
                    [[ -n $link ]] || break
                    if parse_landing_link "$link"; then
                        add_landing "$(normalize_link "$link")"
                        ui_ok "已添加：$PARSED_KIND $PARSED_HOST:$PARSED_PORT"
                        break
                    fi
                    ui_warn "无法使用：$PARSE_ERR"
                done ;;
            d|D)
                (( n > 0 )) || continue
                read_line '删除第几个（编号，回车取消）：' idx
                [[ $idx =~ ^[0-9]+$ ]] || continue
                local tag="landing$idx"
                if [[ $(jq --arg t "$tag" '[.landings[] | select(.tag == $t)] | length' "$DRAFT") == 0 ]]; then
                    ui_warn '没有这个编号。'
                    continue
                fi
                st_filter --arg t "$tag" '.landings |= map(select(.tag != $t)) | .users |= map(select(.out != $t))' ;;
            '') continue ;;
            *) return 0 ;;
        esac
    done
}

add_landing() {
    local link=$1 idx tag port=0 s
    s=$(scheme)
    idx=$(next_landing_index)
    tag="landing$idx"
    if [[ $s == ss ]]; then port=$(random_free_port); fi
    st_filter --arg tag "$tag" --arg link "$link" --argjson ob "$PARSED_OUTBOUND_JSON" --arg kind "$PARSED_KIND" \
        --arg host "$PARSED_HOST" --argjson port "$PARSED_PORT" --arg label "$PARSED_LABEL" --argjson up "$port" \
        '.landings += [{tag:$tag, link:$link, outbound:$ob, kind:$kind, host:$host, port:$port, label:$label}]
         | .users += [{name:$tag, id:"", out:$tag} + (if $up > 0 then {port:$up} else {} end)]'
}


edit_addr() {
    local c v
    ui_section '修改地址'
    if scheme_is_split "$(scheme)"; then
        ui_line '上下行分离需要本机的 IPv4 和 IPv6 地址。'
        read_line "IPv4（回车保持 $(st .net.v4)）：" v
        if [[ -n $v ]]; then
            if valid_ipv4 "$v"; then st_sets .net.v4 "$v"; st_set .net.manual 1; else ui_warn '格式不正确，未修改。'; fi
        fi
        read_line "IPv6（回车保持 $(st .net.v6)）：" v
        if [[ -n $v ]]; then
            if valid_ipv6 "$v"; then st_sets .net.v6 "$v"; st_set .net.manual 1; else ui_warn '格式不正确，未修改。'; fi
        fi
        return 0
    fi
    local -a opts=()
    [[ -z $NET_V4 ]] || opts+=("IPv4 $NET_V4")
    [[ -z $NET_V6 ]] || opts+=("IPv6 $NET_V6")
    opts+=('手动输入域名或 IP')
    local cur=${#opts[@]} host
    host=$(st .net.host)
    if [[ -n $NET_V4 && $host == "$NET_V4" ]]; then cur=1
    elif [[ -n $NET_V6 && $host == "$NET_V6" ]]; then index_of cur "IPv6 $NET_V6" "${opts[@]}"; fi
    ask_choice c "$cur" "${opts[@]}"
    [[ -n $c ]] || return 0
    local sel=${opts[$((c - 1))]}
    case $sel in
        'IPv4 '*) st_sets .net.host "$NET_V4" ;;
        'IPv6 '*) st_sets .net.host "$NET_V6" ;;
        *)
            while :; do
                read_line '客户端连接用的域名或 IP（回车取消）：' v
                [[ -n $v ]] || return 0
                if valid_host "$v"; then st_sets .net.host "${v,,}"; return 0; fi
                ui_warn '格式不正确。'
            done ;;
    esac
}


edit_guard() {
    local c v
    while :; do
        ui_section '修改防护'
        if [[ $(st .reality.guard) == nginx ]]; then v='Nginx（SNI 过滤、连接上限）'; else v='Xray 内置过滤（不装 Nginx）'; fi
        ui_item 1 '前置' "$v"
        ui_item 2 '回落限速' "$(limit_label)：$(limit_text)"
        if [[ $(st .reality.guard) == nginx ]]; then
            ui_item 3 '连接上限' "每 IP $(st .reality.conn_ip)，总计 $(st .reality.conn_total)"
        fi
        read_line '修改哪一项（0 返回）：' c
        case $c in
            1)
                if [[ $(st .reality.guard) == nginx ]]; then
                    st_sets .reality.guard xray
                else
                    if selinux_enforcing; then ui_warn 'SELinux 强制模式下无法使用 Nginx 前置。'; continue; fi
                    st_sets .reality.guard nginx
                fi ;;
            2) edit_limit ;;
            3) if [[ $(st .reality.guard) == nginx ]]; then edit_conn; fi ;;
            '') continue ;;
            *) return 0 ;;
        esac
    done
}

edit_limit() {
    local c ua ur da dr cur
    index_of cur "$(st .reality.limit)" orig std custom
    ui_section '修改回落限速'
    ask_choice c "$cur" '原版：上传 8 KiB 后 1 KiB/s，下载 32 KiB 后 2 KiB/s' \
        '标准：上传 256 KiB 后 32 KiB/s，下载 1 MiB 后 64 KiB/s' '自定义'
    case $c in
        1) st_sets .reality.limit orig ;;
        2) st_sets .reality.limit std ;;
        3)
            ask_number '上传多少字节后开始限速' 0 104857600 "$(st .reality.limit_custom.ua)" ua
            ask_number '上传限速（字节/秒）' 1 104857600 "$(st .reality.limit_custom.ur)" ur
            ask_number '下载多少字节后开始限速' 0 104857600 "$(st .reality.limit_custom.da)" da
            ask_number '下载限速（字节/秒）' 1 104857600 "$(st .reality.limit_custom.dr)" dr
            st_set .reality.limit_custom "$(jq -cn --argjson a "$ua" --argjson b "$ur" --argjson c "$da" --argjson d "$dr" '{ua:$a,ur:$b,da:$c,dr:$d}')"
            st_sets .reality.limit custom ;;
    esac
}

edit_conn() {
    local a b
    ui_line '连接上限在鉴权之前生效，也会约束正常用户。'
    ask_number '每 IP 连接上限' 16 65535 "$(st .reality.conn_ip)" a
    ask_number '总连接上限' "$a" 65535 "$(st .reality.conn_total)" b
    st_set .reality.conn_ip "$a"
    st_set .reality.conn_total "$b"
}


edit_ssm() {
    local c want cur
    index_of cur "$(st .ss.method)" 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm
    ui_section '修改 SS2022 加密方式'
    ask_choice c "$cur" '2022-blake3-aes-128-gcm' '2022-blake3-aes-256-gcm'
    case $c in
        1) want=2022-blake3-aes-128-gcm ;;
        2) want=2022-blake3-aes-256-gcm ;;
        *) return 0 ;;
    esac
    [[ $want != "$(st .ss.method)" ]] || return 0
    confirm_identity_change '更换加密方式会生成新密码' || return 0
    st_sets .ss.method "$want"
    st_sets .ss.password ''
    if [[ $(scheme) == ss ]]; then st_filter '.users |= map(if .name != "direct" then .id = "" else . end)'; fi
}

edit_encp() {
    local c v
    while :; do
        ui_section '修改 VLESS-ENC'
        ui_item 1 '握手' "$(st .enc.rtt)"
        ui_item 2 '外观' "$(st .enc.shape)"
        ui_item 3 '认证' "$(st .enc.auth)"
        case $(st .enc.pad) in off) v='核心默认' ;; gentle) v='温和' ;; aggressive) v='激进' ;; custom) v='自定义' ;; esac
        ui_item 4 'padding' "$v"
        ui_item 5 '票据时长' "$(st .enc.ticket)"
        read_line '修改哪一项（0 返回）：' c
        case $c in
            1)
                confirm_identity_change '修改握手方式' || continue
                if [[ $(st .enc.rtt) == 0rtt ]]; then st_sets .enc.rtt 1rtt; else st_sets .enc.rtt 0rtt; fi ;;
            2)
                local cur_shape
                index_of cur_shape "$(st .enc.shape)" random xorpub native
                ask_choice v "$cur_shape" 'random' 'xorpub' 'native'
                [[ -n $v && $v != "$cur_shape" ]] || continue
                confirm_identity_change '修改外观' || continue
                case $v in 1) st_sets .enc.shape random ;; 2) st_sets .enc.shape xorpub ;; 3) st_sets .enc.shape native ;; esac ;;
            3)
                confirm_identity_change '更换认证方式会生成新密钥' || continue
                if [[ $(st .enc.auth) == x25519 ]]; then st_sets .enc.auth mlkem768; else st_sets .enc.auth x25519; fi
                st_filter '.enc.server_key = "" | .enc.client_key = ""' ;;
            4) edit_padding ;;
            5)
                ask_number '服务端票据有效期（秒）' 1 86400 "$(st .enc.ticket | tr -d s)" v
                st_sets .enc.ticket "${v}s" ;;
            '') continue ;;
            *) return 0 ;;
        esac
    done
}

edit_padding() {
    local c p q cur
    index_of cur "$(st .enc.pad)" off gentle aggressive custom
    ui_section '修改 padding'
    ask_choice c "$cur" '核心默认' '温和' '激进' '自定义'
    [[ -n $c ]] || return 0
    if [[ $c == "$cur" && $c != 4 ]]; then return 0; fi
    confirm_identity_change '修改 padding' || return 0
    case $c in
        1) st_sets .enc.pad off ;;
        2) st_sets .enc.pad gentle ;;
        3) st_sets .enc.pad aggressive ;;
        4)
            while :; do
                read_line '客户端规则（如 100-96-768.60-0-80.40-0-1600）：' p
                valid_padding "$p" && break
                ui_warn '格式无效：首段概率须为 100，长度不小于 35。'
            done
            while :; do
                read_line '服务端规则：' q
                valid_padding "$q" && break
                ui_warn '格式无效：首段概率须为 100，长度不小于 35。'
            done
            st_filter --arg p "$p" --arg q "$q" '.enc.pad = "custom" | .enc.pad_client = $p | .enc.pad_server = $q' ;;
    esac
}


edit_other() {
    local c s
    s=$(scheme)
    while :; do
        ui_section '修改其他'
        ui_item 1 '出站' "$(outbound_label "$(st .outbound)")"
        if [[ $(st .bbr) == 1 ]]; then ui_item 2 'BBR' '开（内核支持时）'; else ui_item 2 'BBR' '关（保持系统设置）'; fi
        local k=3
        local -a keys=(outbound bbr)
        if scheme_has_reality "$s"; then
            ui_item "$k" '指纹' "$(st .reality.fp)"
            keys+=(fp); k=$(( k + 1 ))
        fi
        ui_item "$k" '核心版本' "$(other_core_text)"
        keys+=(core)
        read_line '修改哪一项（0 返回）：' c
        [[ -n $c ]] || continue
        [[ $c =~ ^[1-9]$ ]] && (( c <= ${#keys[@]} )) || return 0
        case ${keys[$((c - 1))]} in
            outbound) edit_outbound ;;
            bbr) if [[ $(st .bbr) == 1 ]]; then st_set .bbr 0; else st_set .bbr 1; fi ;;
            fp)
                local -a fps=(firefox chrome safari edge)
                local fi_cur=1 j
                for j in "${!fps[@]}"; do [[ ${fps[$j]} != "$(st .reality.fp)" ]] || fi_cur=$(( j + 1 )); done
                ask_choice c "$fi_cur" "${fps[@]}"
                if [[ $c =~ ^[1-4]$ ]]; then st_sets .reality.fp "${fps[$((c - 1))]}"; fi ;;
            core) edit_core ;;
        esac
    done
}

other_core_text() {
    local -a o=()
    if needs_xray; then o+=("Xray $(core_label xray)"); fi
    if needs_ss_rust; then o+=("SS-Rust $(core_label ss)"); fi
    local v
    v=$(IFS=,; printf '%s' "${o[*]}")
    printf '%s' "${v//,/，}"
}

edit_outbound() {
    local c
    local -a modes=(v4first v6first v4only v6only) opts=()
    local m
    for m in "${modes[@]}"; do
        if [[ $m == v4only && -z $NET_V4 ]]; then opts+=("$(outbound_label "$m")（本机无 IPv4，不可选）")
        elif [[ $m == v6only && -z $NET_V6 ]]; then opts+=("$(outbound_label "$m")（本机无 IPv6，不可选）")
        else opts+=("$(outbound_label "$m")"); fi
    done
    local cur
    index_of cur "$(st .outbound)" "${modes[@]}"
    ui_section '修改出站'
    ask_choice c "$cur" "${opts[@]}"
    [[ -n $c ]] || return 0
    m=${modes[$((c - 1))]}
    if [[ ${opts[$((c - 1))]} == *不可选* ]]; then ui_warn '本机缺少对应的网络，不能选这个模式。'; return 0; fi
    st_sets .outbound "$m"
    if [[ $(scheme) == ss && $(ss_core) == xray && ( $m == v4only || $m == v6only ) ]]; then
        ui_line '这个出站模式 ss-rust 做不到，SS2022 改用 Xray 核心。'
    fi
}

edit_core() {
    local c v
    local -a which=()
    if needs_xray; then which+=(xray); fi
    if needs_ss_rust; then which+=(ss); fi
    ui_section '修改核心版本'
    local w name
    for w in "${which[@]}"; do
        if [[ $w == xray ]]; then name=Xray; else name=SS-Rust; fi
        read_line "$name 版本（latest 或官方标签，回车保持 $(st ".core.$w")）：" v
        [[ -n $v ]] || continue
        if [[ $v == latest || $v =~ ^v?[0-9][A-Za-z0-9._-]*$ ]]; then st_sets ".core.$w" "$(normalize_tag "$v")"
        else ui_warn '版本格式不正确，未修改。'; fi
    done
}


listen_any() { if has_ipv6_stack; then printf '::'; else printf '0.0.0.0'; fi; }

block_rules_json() {
    jq -cn '[
      {type:"field", domain:["full:localhost","full:localhost.localdomain"], outboundTag:"blocked"},
      {type:"field", network:"tcp", port:"25,465,587,2525", outboundTag:"blocked"},
      {type:"field", ip:["geoip:private","0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16",
        "172.16.0.0/12","192.0.0.0/24","192.0.2.0/24","192.168.0.0/16","198.18.0.0/15","198.51.100.0/24",
        "203.0.113.0/24","224.0.0.0/4","240.0.0.0/4","255.255.255.255/32","::/128","::1/128","fc00::/7",
        "fe80::/10","ff00::/8","2001:db8::/32"], outboundTag:"blocked"}
    ]'
}

shared_users_json() {
    local flow=$1
    jq -c --arg flow "$flow" '[.users[] | select((.port // 0) == 0) | {id, email: .name} + (if $flow == "" then {} else {flow: $flow} end)]' "$DRAFT"
}

render_xray_config() {
    local out=$1 s listen strategy
    s=$(scheme)
    listen=$(listen_any)
    strategy=$(outbound_xray_strategy "$(st .outbound)")
    local inb=$STAGE/xr-in.ndjson rules=$STAGE/xr-rules.ndjson
    : > "$inb"
    : > "$rules"
    local -a direct_tags=()

    if scheme_has_reality "$s"; then
        local net flow dec stream users lv
        net=$(scheme_transport "$s")
        flow=xtls-rprx-vision dec=none
        if [[ $net == xhttp ]]; then
            if [[ $s == reality-xhttp && $(st .xhttp.enc) == 1 ]]; then dec=$(enc_string server); else flow=''; fi
        fi
        [[ $s != triple ]] || net=raw
        users=$(shared_users_json "$flow")
        [[ $s == triple ]] && users=$(jq -c '[.[] | select(.email == "direct")]' <<< "$users")
        read -r -a lv <<< "$(limit_values)"
        stream=$(jq -cn --arg net "$net" --arg sni "$(st .reality.sni)" --arg key "$(st .reality.private_key)" \
            --arg sid "$(st .reality.short_id)" --arg path "$(st .xhttp.path)" --arg guard "$(st .reality.guard)" \
            --arg gate "127.0.0.1:$(st .reality.gate)" \
            --argjson ua "${lv[0]}" --argjson ur "${lv[1]}" --argjson da "${lv[2]}" --argjson dr "${lv[3]}" '
            {network: $net, security: "reality",
             realitySettings: {show: false, target: (if $guard == "nginx" then ($sni + ":443") else $gate end),
                serverNames: [$sni], privateKey: $key, shortIds: [$sid],
                limitFallbackUpload: {afterBytes: $ua, bytesPerSec: $ur, burstBytesPerSec: 0},
                limitFallbackDownload: {afterBytes: $da, bytesPerSec: $dr, burstBytesPerSec: 0}}}
            + (if $net == "xhttp" then {xhttpSettings: {path: $path, mode: "auto"}} else {} end)
            + (if $guard == "nginx" then {sockopt: {acceptProxyProtocol: true}} else {} end)')
        if [[ $(st .reality.guard) == nginx ]]; then
            jq -cn --argjson p "$(st .reality.internal)" --argjson u "$users" --arg dec "$dec" --argjson st "$stream" \
                '{tag:"in-reality", listen:"127.0.0.1", port:$p, protocol:"vless", settings:{clients:$u, decryption:$dec}, streamSettings:$st}' >> "$inb"
        else
            jq -cn --arg l "$listen" --argjson p "$(st .reality.port)" --argjson u "$users" --arg dec "$dec" --argjson st "$stream" \
                '{tag:"in-reality", listen:$l, port:$p, protocol:"vless", settings:{clients:$u, decryption:$dec}, streamSettings:$st}' >> "$inb"
            jq -cn --argjson p "$(st .reality.gate)" --arg sni "$(st .reality.sni)" \
                '{tag:"reality-gate", listen:"127.0.0.1", port:$p, protocol:"tunnel",
                  settings:{address:$sni, port:443, network:"tcp"},
                  sniffing:{enabled:true, destOverride:["tls"], routeOnly:true}}' >> "$inb"
            jq -cn --arg sni "$(st .reality.sni)" \
                '{type:"field", inboundTag:["reality-gate"], domain:["full:" + $sni], network:"tcp", outboundTag:"direct"}' \
                >> "$STAGE/xr-gate.ndjson"
            jq -cn '{type:"field", inboundTag:["reality-gate"], network:"tcp", outboundTag:"blocked"}' >> "$STAGE/xr-gate.ndjson"
        fi
        direct_tags+=(in-reality)
    fi

    if scheme_has_enc_inbound "$s"; then
        local users stream dec
        dec=$(enc_string server)
        if [[ $s == enc-split ]]; then users=$(shared_users_json ''); else users=$(shared_users_json xtls-rprx-vision); fi
        [[ $s == enc ]] || users=$(jq -c '[.[] | select(.email == "direct")]' <<< "$users")
        if [[ $s == enc-split ]]; then
            stream=$(jq -cn --arg path "$(st .xhttp.path)" '{network:"xhttp", security:"none", xhttpSettings:{path:$path, mode:"auto"}}')
        else
            stream='{"network":"raw","security":"none"}'
        fi
        jq -cn --arg l "$listen" --argjson p "$(st .enc.port)" --argjson u "$users" --arg dec "$dec" --argjson st "$stream" \
            '{tag:"in-enc", listen:$l, port:$p, protocol:"vless", settings:{clients:$u, decryption:$dec}, streamSettings:$st}' >> "$inb"
        direct_tags+=(in-enc)
    fi

    if scheme_has_ss "$s"; then
        jq -cn --arg l "$listen" --argjson p "$(st .ss.port)" --arg m "$(st .ss.method)" --arg pw "$(st .ss.password)" \
            '{tag:"in-ss", listen:$l, port:$p, protocol:"shadowsocks", settings:{method:$m, password:$pw, network:"tcp,udp"}}' >> "$inb"
        direct_tags+=(in-ss)
        if [[ $s == ss ]]; then
            jq -c --arg l "$listen" --arg m "$(st .ss.method)" '.users[] | select((.port // 0) > 0) |
                {tag:("in-ss-" + .name), listen:$l, port:.port, protocol:"shadowsocks",
                 settings:{method:$m, password:.id, network:"tcp,udp"}}' "$DRAFT" >> "$inb"
            jq -c '.users[] | select((.port // 0) > 0) | {type:"field", inboundTag:["in-ss-" + .name], outboundTag:.out}' "$DRAFT" >> "$rules"
        fi
    fi

    local shared_tag=''
    if scheme_has_reality "$s" && [[ $s != triple ]]; then shared_tag=in-reality; fi
    if [[ $s == enc ]]; then shared_tag=in-enc; fi
    if [[ -n $shared_tag ]]; then
        jq -c --arg t "$shared_tag" '.users[] | select((.port // 0) == 0 and .out != "direct") |
            {type:"field", inboundTag:[$t], user:[.name], outboundTag:.out}' "$DRAFT" >> "$rules"
    fi

    local family='[]'
    case $(st .outbound) in
        v4only) family='[{"type":"field","ip":["::/0"],"outboundTag":"blocked"}]' ;;
        v6only) family='[{"type":"field","ip":["0.0.0.0/0"],"outboundTag":"blocked"}]' ;;
    esac
    local gate='[]'
    [[ ! -s $STAGE/xr-gate.ndjson ]] || gate=$(jq -cs . "$STAGE/xr-gate.ndjson")
    rm -f -- "$STAGE/xr-gate.ndjson"
    local tags_json
    tags_json=$(printf '%s\n' "${direct_tags[@]}" | jq -R . | jq -cs .)
    jq -n --slurpfile inb "$inb" --slurpfile landing_rules "$rules" --argjson block "$(block_rules_json)" \
        --argjson gate "$gate" --argjson family "$family" --argjson tags "$tags_json" --arg strategy "$strategy" \
        --argjson landings "$(stj '[.landings[] | .outbound + {tag}]')" '{
        log: {loglevel: "warning", access: "none"},
        inbounds: $inb,
        outbounds: ([{tag: "direct", protocol: "freedom", streamSettings: {sockopt: {domainStrategy: $strategy}}},
                     {tag: "blocked", protocol: "blackhole"}] + $landings),
        routing: {domainStrategy: "AsIs", rules: ($gate + $block + $landing_rules + $family
            + [{type: "field", inboundTag: $tags, network: "tcp,udp", outboundTag: "direct"},
               {type: "field", network: "tcp,udp", outboundTag: "blocked"}])}
    }' > "$out"
}


render_ss_rust() {
    local cfg=$1 acl=$2 v6first=false
    [[ $(st .outbound) == v6first ]] && v6first=true
    jq -n --arg l "$(listen_any)" --argjson p "$(st .ss.port)" --arg m "$(st .ss.method)" --arg pw "$(st .ss.password)" \
        --argjson v6 "$v6first" \
        '{server: $l, server_port: $p, method: $m, password: $pw, mode: "tcp_and_udp", timeout: 300,
          ipv6_first: $v6, ipv6_only: false, no_delay: true}' > "$cfg"
    cat > "$acl" <<'ACL'
# Managed by Xray Manager
[accept_all]

[outbound_block_list]
0.0.0.0/8
10.0.0.0/8
100.64.0.0/10
127.0.0.0/8
169.254.0.0/16
172.16.0.0/12
192.0.0.0/24
192.0.2.0/24
192.168.0.0/16
198.18.0.0/15
198.51.100.0/24
203.0.113.0/24
224.0.0.0/4
240.0.0.0/4
::/128
::1/128
fc00::/7
fe80::/10
ff00::/8
2001:db8::/32
(^|\.)localhost$
ACL
}


nginx_detect() {
    local build v
    build=$(nginx -V 2>&1)
    NGINX_MODULE_LINE=''
    if [[ $build == *--with-stream=dynamic* ]]; then
        local m
        for m in /usr/lib/nginx/modules/ngx_stream_module.so /usr/lib64/nginx/modules/ngx_stream_module.so \
            /usr/share/nginx/modules/ngx_stream_module.so; do
            if [[ -f $m ]]; then NGINX_MODULE_LINE="load_module $m;"; break; fi
        done
        [[ -n $NGINX_MODULE_LINE ]] || { die '找不到 Nginx Stream 动态模块。'; return 1; }
    elif [[ $build != *--with-stream* ]]; then
        die '当前 Nginx 没有编译 Stream 模块。'
        return 1
    fi
    v=$(sed -n 's#.*nginx/\([0-9.]*\).*#\1#p' <<< "$build" | head -n 1)
    if [[ -n $v ]] && ver_ge "$v" 1.19.4; then NGINX_REJECT_TLS=1; else NGINX_REJECT_TLS=0; fi
}

render_nginx() {
    local out=$1 user group sni
    user=nobody
    group=$(id -gn nobody 2>/dev/null || echo nogroup)
    sni=$(st .reality.sni)
    {
        printf '%s\n' "$MANAGED_TAG"
        [[ -z $NGINX_MODULE_LINE ]] || printf '%s\n' "$NGINX_MODULE_LINE"
        cat <<EOF
user $user $group;
worker_processes auto;
worker_rlimit_nofile 65535;
pid $NGINX_RUN/nginx.pid;
error_log $NGINX_DIR/error.log warn;

events {
    worker_connections 8192;
}

stream {
    map \$ssl_preread_server_name \$zxray_backend {
        $sni   127.0.0.1:$(st .reality.internal);
        default   unix:$NGINX_RUN/reject.sock;
    }
    map \$remote_addr \$zxray_all {
        default all;
    }
    limit_conn_zone \$binary_remote_addr zone=zxray_ip:10m;
    limit_conn_zone \$zxray_all zone=zxray_total:1m;

    server {
        listen 0.0.0.0:$(st .reality.port);
EOF
        if has_ipv6_stack; then printf '        listen [::]:%s ipv6only=on;\n' "$(st .reality.port)"; fi
        cat <<EOF
        ssl_preread on;
        preread_timeout 5s;
        proxy_connect_timeout 5s;
        proxy_timeout 24h;
        proxy_socket_keepalive on;
        limit_conn zxray_ip $(st .reality.conn_ip);
        limit_conn zxray_total $(st .reality.conn_total);
        proxy_protocol on;
        proxy_pass \$zxray_backend;
    }
EOF
        if (( ! NGINX_REJECT_TLS )); then
            cat <<EOF

    server {
        listen unix:$NGINX_RUN/reject.sock proxy_protocol;
        return "";
    }
EOF
        fi
        printf '}\n'
        if (( NGINX_REJECT_TLS )); then
            cat <<EOF

http {
    access_log off;
    client_body_temp_path $NGINX_DIR/tmp/body;
    proxy_temp_path $NGINX_DIR/tmp/proxy;
    fastcgi_temp_path $NGINX_DIR/tmp/fastcgi;
    uwsgi_temp_path $NGINX_DIR/tmp/uwsgi;
    scgi_temp_path $NGINX_DIR/tmp/scgi;

    server {
        listen unix:$NGINX_RUN/reject.sock ssl proxy_protocol default_server;
        ssl_reject_handshake on;
    }
}
EOF
        fi
    } > "$out"
}


landing_label() {
    local out=$1
    if [[ $out == direct ]]; then printf '直出'; else printf '落地%s' "${out#landing}"; fi
}

reality_query() {
    printf 'security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&spx=%%2F' \
        "$(url_encode "$(st .reality.sni)")" "$(st .reality.fp)" "$(st .reality.public_key)" "$(st .reality.short_id)"
}

split_hosts() {
    if [[ $(st .xhttp.split) == v6_up_v4_down ]]; then printf '%s %s' "$(st .net.v6)" "$(st .net.v4)"
    else printf '%s %s' "$(st .net.v4)" "$(st .net.v6)"; fi
}

node_add() { jq -cn --arg l "$1" --arg k "$2" '{label:$l, link:$k}' >> "$NODES_TMP"; }

node_add_with_v6() {
    local label=$1 link=$2 host=$3 port=$4
    node_add "$label" "$link"
    local v6
    v6=$(st .net.v6)
    if [[ -n $v6 && $host == "$(st .net.v4)" ]]; then
        local l6=${link/"@$(uri_host "$host"):$port"/"@[$v6]:$port"}
        l6="${l6%%#*}#$(url_encode "$label-IPv6")"
        node_add "$label-IPv6" "$l6"
    fi
}

render_nodes() {
    local out=$1 s host hu
    s=$(scheme)
    NODES_TMP=$out
    : > "$NODES_TMP"
    host=$(st .net.host)
    hu=$(uri_host "$host")
    local n i id outtag port name label link
    n=$(jq '.users | length' "$DRAFT")

    if scheme_has_reality "$s"; then
        local net
        net=$(scheme_transport "$s")
        [[ $s != triple ]] || net=raw
        for (( i = 0; i < n; i++ )); do
            [[ $(jq -r ".users[$i].port // 0" "$DRAFT") == 0 ]] || continue
            outtag=$(jq -r ".users[$i].out" "$DRAFT")
            [[ $s != triple || $outtag == direct ]] || continue
            id=$(jq -r ".users[$i].id" "$DRAFT")
            port=$(st .reality.port)
            case $s in
                reality-xhttp)
                    label="XHTTP-$(landing_label "$outtag")-zxray"
                    local enc=none flowq='' extra=''
                    if [[ $(st .xhttp.enc) == 1 ]]; then enc=$(enc_string client); flowq='&flow=xtls-rprx-vision'; fi
                    if [[ $(stj .xhttp.xmux) != null ]]; then extra="&extra=$(url_encode "$(jq -c '{xmux: .xhttp.xmux}' "$DRAFT")")"; fi
                    link="vless://$id@$hu:$port?encryption=$(url_encode "$enc")$flowq&$(reality_query)"
                    link+="&type=xhttp&path=$(url_encode "$(st .xhttp.path)")&mode=stream-one$extra#$(url_encode "$label")"
                    node_add_with_v6 "$label" "$link" "$host" "$port" ;;
                reality-split)
                    local up down ex
                    read -r up down <<< "$(split_hosts)"
                    label="XHTTP-分离-$(landing_label "$outtag")-zxray"
                    ex=$(jq -cn --arg a "$down" --argjson p "$port" --arg sni "$(st .reality.sni)" --arg fp "$(st .reality.fp)" \
                        --arg pbk "$(st .reality.public_key)" --arg sid "$(st .reality.short_id)" --arg path "$(st .xhttp.path)" \
                        '{downloadSettings:{address:$a, port:$p, network:"xhttp", security:"reality",
                          realitySettings:{serverName:$sni, fingerprint:$fp, publicKey:$pbk, shortId:$sid, spiderX:"/"},
                          xhttpSettings:{path:$path}}}')
                    link="vless://$id@$(uri_host "$up"):$port?encryption=none&$(reality_query)&type=xhttp"
                    link+="&path=$(url_encode "$(st .xhttp.path)")&mode=auto&extra=$(url_encode "$ex")#$(url_encode "$label")"
                    node_add "$label" "$link" ;;
                *)
                    label="REALITY-$(landing_label "$outtag")-zxray"
                    link="vless://$id@$hu:$port?encryption=none&flow=xtls-rprx-vision&$(reality_query)&type=tcp&headerType=none#$(url_encode "$label")"
                    node_add_with_v6 "$label" "$link" "$host" "$port" ;;
            esac
        done
    fi

    if scheme_has_enc_inbound "$s"; then
        local enc
        enc=$(url_encode "$(enc_string client)")
        for (( i = 0; i < n; i++ )); do
            outtag=$(jq -r ".users[$i].out" "$DRAFT")
            [[ $s == enc || $outtag == direct ]] || continue
            id=$(jq -r ".users[$i].id" "$DRAFT")
            port=$(st .enc.port)
            if [[ $s == enc-split ]]; then
                local up down ex
                read -r up down <<< "$(split_hosts)"
                label='XHTTP-ENC-分离-zxray'
                ex=$(jq -cn --arg a "$down" --argjson p "$port" --arg path "$(st .xhttp.path)" \
                    '{downloadSettings:{address:$a, port:$p, network:"xhttp", xhttpSettings:{path:$path}}}')
                link="vless://$id@$(uri_host "$up"):$port?encryption=$enc&security=none&type=xhttp"
                link+="&path=$(url_encode "$(st .xhttp.path)")&mode=auto&extra=$(url_encode "$ex")#$(url_encode "$label")"
                node_add "$label" "$link"
            else
                label="VLESS-ENC-$(landing_label "$outtag")-zxray"
                link="vless://$id@$hu:$port?encryption=$enc&flow=xtls-rprx-vision&security=none&type=tcp&headerType=none#$(url_encode "$label")"
                node_add_with_v6 "$label" "$link" "$host" "$port"
            fi
        done
    fi

    if scheme_has_ss "$s"; then
        local m pw ui
        m=$(st .ss.method)
        pw=$(st .ss.password)
        ui=$(b64url_nopad "$m:$pw")
        link="ss://$ui@$hu:$(st .ss.port)#$(url_encode 'SS-直出-zxray')"
        node_add_with_v6 'SS-直出-zxray' "$link" "$host" "$(st .ss.port)"
        if [[ $s == ss ]]; then
            for (( i = 0; i < n; i++ )); do
                port=$(jq -r ".users[$i].port // 0" "$DRAFT")
                [[ $port != 0 ]] || continue
                outtag=$(jq -r ".users[$i].out" "$DRAFT")
                ui=$(b64url_nopad "$m:$(jq -r ".users[$i].id" "$DRAFT")")
                label="SS-$(landing_label "$outtag")-zxray"
                node_add_with_v6 "$label" "ss://$ui@$hu:$port#$(url_encode "$label")" "$host" "$port"
            done
        fi
    fi
}

render_info() {
    local nodes=$1 out=$2 s
    s=$(scheme)
    {
        printf 'Xray Manager v%s\n' "$SCRIPT_VERSION"
        printf '方案    %s\n' "$(scheme_label "$s")"
        printf '时间    %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        jq -r '.[] | "\(.label)\n\(.link)\n"' "$nodes"
        if (( $(jq '.landings | length' "$DRAFT") > 0 )); then
            printf '落地原始链接\n'
            jq -r '.landings[] | "\(.tag | sub("landing"; "落地 ")): \(.link)"' "$DRAFT"
            printf '\n'
        fi
        printf '对外端口\n'
        public_ports | awk '{printf "%s/%s %s\n", $2, toupper($1), $3}'
        printf '\n出站    %s\n' "$(outbound_label "$(st .outbound)")"
        if scheme_has_reality "$s"; then
            if [[ $(st .reality.guard) == nginx ]]; then printf '防护    Nginx SNI 过滤 + 回落限速\n'
            else printf '防护    Xray 内置 SNI 过滤 + 回落限速\n'; fi
            printf '限速    %s\n' "$(limit_text)"
        fi
        if [[ $(scheme_transport "$s") == xhttp ]]; then
            printf 'XHTTP   请使用 Xray 内核客户端，不要开启通用 Mux.cool\n'
        fi
        if [[ $s == ss && $(ss_core) == ss-rust ]]; then
            printf 'SS-Rust 已拦截私网地址；不含 Xray 的 SMTP 端口拦截\n'
        fi
    } > "$out"
}


installed_version() { jq -r ".installed.$1 // empty" "$STATE" 2>/dev/null || true; }

plan_cores() {
    USE_XRAY='' USE_SS='' NEW_XRAY=0 NEW_SS=0
    local want cur
    if needs_xray; then
        want=$(st .core.xray); cur=$(installed_version xray)
        if [[ $MODE == modify && -x $XRAY_BIN && -n $cur && ( $want == latest || $want == "$cur" ) ]]; then
            USE_XRAY=$XRAY_BIN USE_XRAY_ASSET=$XRAY_ASSET_DIR
        else NEW_XRAY=1; fi
    fi
    if needs_ss_rust; then
        want=$(st .core.ss); cur=$(installed_version ss)
        if [[ $MODE == modify && -x $SS_BIN && -n $cur && ( $want == latest || $want == "$cur" ) ]]; then USE_SS=$SS_BIN
        else NEW_SS=1; fi
    fi
}

download_cores() {
    local dir=$STAGE/core
    mkdir -p "$dir"
    if (( NEW_XRAY )); then
        download_xray "$(st .core.xray)" "$dir/xray-pkg"
        USE_XRAY=$dir/xray-pkg/xray USE_XRAY_ASSET=$dir/xray-pkg
    fi
    if (( NEW_SS )); then
        download_ss "$(st .core.ss)" "$dir/ss-pkg"
        USE_SS=$dir/ss-pkg/ssserver
    fi
}

validate_xray_config() {
    local cfg=$1
    XRAY_LOCATION_ASSET=$USE_XRAY_ASSET "$USE_XRAY" run -test -config "$cfg" >> "$STEP_LOG" 2>&1 ||
        { die 'Xray 配置校验未通过。'; return 1; }
}

validate_ss_rust() {
    local cfg=$1 acl=$2 p child ok=0 k
    p=$(random_free_port)
    jq --argjson p "$p" '.server = "127.0.0.1" | .server_port = $p' "$cfg" > "$STAGE/ss-check.json"
    "$USE_SS" -c "$STAGE/ss-check.json" --acl "$acl" >> "$STEP_LOG" 2>&1 3>&- 9>&- &
    child=$!
    CHECK_PID=$child
    for k in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.3
        if ! kill -0 "$child" 2>/dev/null; then break; fi
        if port_listening tcp "$p"; then ok=1; break; fi
    done
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    CHECK_PID=''
    (( ok )) || { die 'shadowsocks-rust 配置试启动失败。'; return 1; }
}


nginx_packages() {
    case $PKG in
        apk) printf '%s\n' nginx nginx-mod-stream ;;
        apt) printf '%s\n' nginx libnginx-mod-stream ;;
        dnf|yum) printf '%s\n' nginx nginx-mod-stream ;;
        pacman) printf '%s\n' nginx ;;
    esac
}

nginx_system_hash() {
    [[ -d $ROOT/etc/nginx ]] || return 0
    (cd "$ROOT/etc/nginx" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum) | sha256sum | awk '{print $1}'
}

prepare_nginx() {
    local p
    local -a want=() missing=()
    mapfile -t want < <(nginx_packages)
    for p in "${want[@]}"; do pkg_installed "$p" || missing+=("$p"); done
    if (( ${#missing[@]} )); then
        local had_nginx=0 rc=0
        if have nginx || svc_exists nginx; then had_nginx=1; fi
        if (( ! had_nginx )); then printf '%s\n' "${missing[@]}" >> "$TX/new-packages"; fi
        pkg_refresh >> "$STEP_LOG" 2>&1 || true
        if (( ! had_nginx )) && [[ $INIT == systemd ]]; then systemctl mask nginx >> "$STEP_LOG" 2>&1 || true; fi
        pkg_install "${missing[@]}" >> "$STEP_LOG" 2>&1 || rc=$?
        if (( ! had_nginx )) && [[ $INIT == systemd ]]; then systemctl unmask nginx >> "$STEP_LOG" 2>&1 || true; fi
        (( rc == 0 )) || { die 'Nginx 安装失败。'; return 1; }
        if (( ! had_nginx )); then
            svc_stop_disable nginx
            st_filter --argjson add "$(printf '%s\n' "${missing[@]}" | jq -R . | jq -cs .)" '.meta.nginx_packages = ((.meta.nginx_packages + $add) | unique)'
            if [[ -z $(st .meta.nginx_hash) ]]; then st_sets .meta.nginx_hash "$(nginx_system_hash)"; fi
        fi
    fi
    nginx_detect
}


configure_bbr() {
    if [[ $(st .bbr) != 1 ]]; then
        if is_managed_file "$SYSCTL_FILE"; then rm -f -- "$SYSCTL_FILE"; restore_bbr_original; fi
        return 0
    fi
    local cc q
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    q=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    modprobe tcp_bbr >/dev/null 2>&1 || true
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then return 0; fi
    if [[ -f $SYSCTL_FILE ]] && ! is_managed_file "$SYSCTL_FILE"; then return 0; fi
    if [[ ! -f $DATA_DIR/bbr-original.json ]]; then
        jq -n --arg cc "$cc" --arg q "$q" '{cc: $cc, qdisc: $q}' > "$DATA_DIR/bbr-original.json"
    fi
    mkdir -p "$(dirname -- "$SYSCTL_FILE")"
    printf '%s\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' "$MANAGED_TAG" > "$SYSCTL_FILE"
    chmod 644 "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
}

restore_bbr_original() {
    [[ -f $DATA_DIR/bbr-original.json ]] || return 0
    local cc q
    cc=$(jq -r '.cc // empty' "$DATA_DIR/bbr-original.json")
    q=$(jq -r '.qdisc // empty' "$DATA_DIR/bbr-original.json")
    [[ -z $cc ]] || sysctl -q -w "net.ipv4.tcp_congestion_control=$cc" >/dev/null 2>&1 || true
    [[ -z $q ]] || sysctl -q -w "net.core.default_qdisc=$q" >/dev/null 2>&1 || true
    rm -f -- "$DATA_DIR/bbr-original.json"
}

install_logrotate() {
    [[ -d $ROOT/etc/logrotate.d ]] || return 0
    cat > "$ROOT/etc/logrotate.d/zxray" <<EOF
$MANAGED_TAG
$DATA_DIR/log/*.log $NGINX_DIR/error.log {
    size 1M
    rotate 2
    missingok
    notifempty
    copytruncate
    compress
}
EOF
    chmod 644 "$ROOT/etc/logrotate.d/zxray"
}


wanted_services() {
    if needs_xray; then printf 'xray\n'; fi
    if needs_ss_rust; then printf 'zxray-ss\n'; fi
    if needs_nginx; then printf 'zxray-nginx\n'; fi
}

stop_owned_services() {
    local s pid n
    for s in "${MANAGED_SERVICES[@]}"; do svc_stop_disable "$s"; done
    while read -r pid; do
        [[ -n $pid ]] || continue
        if pid_is_owned "$pid"; then
            kill "$pid" 2>/dev/null || true
            for n in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
            if kill -0 "$pid" 2>/dev/null; then die "进程 $pid 未能停止。"; return 1; fi
        fi
    done < <(pgrep -x 'xray|ssserver|nginx' 2>/dev/null || true)
}

remove_old_files() {
    local n
    rm -rf -- "$CONFIG_DIR" "$SS_CONFIG" "$SS_ACL" "$NGINX_DIR" "$NGINX_RUN"
    for n in "${MANAGED_SERVICES[@]}"; do
        rm -f -- "$OPENRC_DIR/$n" "$SYSTEMD_DIR/$n.service" "$ROOT/etc/runlevels/default/$n"
        rm -f -- "$SYSTEMD_DIR/multi-user.target.wants/$n.service"
    done
    needs_xray || rm -rf -- "$XRAY_BIN" "$XRAY_ASSET_DIR"
    needs_ss_rust || rm -f -- "$SS_BIN"
    return 0
}

xray_needs_lowport() {
    local proto port label
    while read -r proto port label; do
        [[ -n $port ]] || continue
        if [[ $label == REALITY && $(st .reality.guard) == nginx ]]; then continue; fi
        if (( port < 1024 )); then return 0; fi
    done < <(public_ports)
    return 1
}
install_files_and_services() {
    local low
    ensure_service_user
    if (( SERVICE_USER_CREATED )); then st_set .meta.created_user 1; fi
    mkdir -p "$DATA_DIR/log" "$SELF_DIR" "$ROOT/usr/local/bin"
    chmod 755 "$DATA_DIR" "$SELF_DIR"
    chown "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR/log"
    chmod 750 "$DATA_DIR/log"
    if needs_xray; then
        if [[ $USE_XRAY != "$XRAY_BIN" ]]; then
            install_bin "$USE_XRAY" "$XRAY_BIN"
            atomic_install "$USE_XRAY_ASSET/geoip.dat" "$XRAY_ASSET_DIR/geoip.dat" 644
            atomic_install "$USE_XRAY_ASSET/geosite.dat" "$XRAY_ASSET_DIR/geosite.dat" 644
            chmod 755 "$XRAY_ASSET_DIR"
        fi
        mkdir -p "$CONFIG_DIR"
        atomic_install "$STAGE/config.json" "$CONFIG_FILE" 640
        chown "root:$SERVICE_USER" "$CONFIG_FILE"
        chmod 750 "$CONFIG_DIR"
        chown "root:$SERVICE_USER" "$CONFIG_DIR"
        low=0
        if xray_needs_lowport; then low=1; fi
        grant_lowport "$XRAY_BIN" "$low"
        write_service xray "$XRAY_BIN" "run -config $CONFIG_FILE" 'Xray' "$SERVICE_USER" "$low" "XRAY_LOCATION_ASSET=$XRAY_ASSET_DIR"
    fi
    if needs_ss_rust; then
        [[ $USE_SS == "$SS_BIN" ]] || install_bin "$USE_SS" "$SS_BIN"
        atomic_install "$STAGE/ssserver.json" "$SS_CONFIG" 640
        atomic_install "$STAGE/ssserver.acl" "$SS_ACL" 640
        chown "root:$SERVICE_USER" "$SS_CONFIG" "$SS_ACL"
        low=0
        if (( $(st .ss.port) < 1024 )); then low=1; fi
        grant_lowport "$SS_BIN" "$low"
        write_service zxray-ss "$SS_BIN" "-c $SS_CONFIG --acl $SS_ACL" 'Shadowsocks Rust' "$SERVICE_USER" "$low"
    fi
    if needs_nginx; then
        mkdir -p "$NGINX_DIR/tmp" "$NGINX_RUN"
        chmod 755 "$NGINX_RUN"
        atomic_install "$STAGE/nginx.conf" "$NGINX_DIR/nginx.conf" 644
        nginx -t -c "$NGINX_DIR/nginx.conf" -p "$NGINX_DIR/" >> "$STEP_LOG" 2>&1 || { die 'Nginx 配置校验未通过。'; return 1; }
        write_service zxray-nginx "$(command -v nginx)" "-c $NGINX_DIR/nginx.conf -p $NGINX_DIR/ -g 'daemon off;'" \
            'Xray Manager Nginx' root 0 '' "$NGINX_DIR" zxray-nginx
    fi
}

start_services() {
    local s
    svc_reload_units
    while read -r s; do
        [[ -n $s ]] || continue
        svc_do enable "$s"
        svc_do start "$s" || true
    done < <(wanted_services)
}

service_log_to_step() {
    local s=$1
    if [[ $INIT == systemd ]]; then
        journalctl -u "$s" -n 30 --no-pager >> "$STEP_LOG" 2>&1 || true
    elif [[ -f $DATA_DIR/log/$s.log ]]; then
        tail -n 30 "$DATA_DIR/log/$s.log" >> "$STEP_LOG" 2>&1 || true
    fi
}


wait_active() {
    local s=$1 secs=$2 i
    for (( i = 0; i < secs * 2; i++ )); do
        if svc_active "$s"; then return 0; fi
        sleep 0.5
    done
    return 1
}

health_check() {
    local s proto port label i
    while read -r s; do
        [[ -n $s ]] || continue
        if ! wait_active "$s" 10; then service_log_to_step "$s"; die "$s 没有正常运行。"; return 1; fi
    done < <(wanted_services)
    sleep 1
    while read -r proto port label; do
        [[ -n $port ]] || continue
        for (( i = 0; i < 10; i++ )); do
            if port_listening "$proto" "$port"; then break; fi
            sleep 0.5
        done
        port_listening "$proto" "$port" || { die "$label 的 ${proto^^} $port 端口没有监听。"; return 1; }
    done < <(public_ports)
    if scheme_has_reality "$(scheme)"; then reality_check; fi
    return 0
}

reality_check() {
    local rp sni rows
    rp=$(st .reality.port)
    sni=$(st .reality.sni)
    if [[ $(st .reality.guard) == nginx ]]; then
        rows=$(listeners tcp "$(st .reality.internal)")
        [[ -n $rows && $rows == *127.0.0.1:* ]] || { die 'REALITY 本地监听异常。'; return 1; }
        if grep -vq '127.0.0.1:' <<< "$rows"; then die 'REALITY 后端意外暴露到公网。'; return 1; fi
    fi
    if timeout 6 openssl s_client -connect "127.0.0.1:$rp" -servername invalid.example -tls1_3 -brief </dev/null >> "$STEP_LOG" 2>&1; then
        die '错误 SNI 没有被拒绝。'
        return 1
    fi
    local ok=0 t
    for t in 1 2; do
        if timeout 10 openssl s_client -connect "127.0.0.1:$rp" -servername "$sni" -tls1_3 -brief \
            -verify_hostname "$sni" -verify_return_error </dev/null >> "$STEP_LOG" 2>&1; then ok=1; break; fi
        sleep 1
    done
    (( ok )) || { die '正确 SNI 的回落握手失败（服务器可能连不上目标站）。'; return 1; }
}


record_installed_versions() {
    local v
    if needs_xray; then v=$(xray_version_of "$XRAY_BIN"); st_sets .installed.xray "v$v"; else st_sets .installed.xray ''; fi
    if needs_ss_rust; then v=$(ss_version_of "$SS_BIN"); st_sets .installed.ss "v$v"; else st_sets .installed.ss ''; fi
}

apply_draft() {
    plan_cores
    STEP_NO=0
    STEP_TOTAL=4
    local dl=0
    if (( NEW_XRAY || NEW_SS )); then dl=1; STEP_TOTAL=$(( STEP_TOTAL + 1 )); fi
    local ng=0
    if needs_nginx; then ng=1; STEP_TOTAL=$(( STEP_TOTAL + 1 )); fi

    ui_blank
    if (( dl )); then
        ui_step '下载并校验核心'
        download_cores
        ui_step_done
    fi

    ui_step '生成并校验配置'
    : > "$STEP_LOG"
    finalize_identity "$USE_XRAY"
    if needs_xray; then
        render_xray_config "$STAGE/config.json"
        validate_xray_config "$STAGE/config.json"
    fi
    if needs_ss_rust; then
        render_ss_rust "$STAGE/ssserver.json" "$STAGE/ssserver.acl"
        validate_ss_rust "$STAGE/ssserver.json" "$STAGE/ssserver.acl"
    fi
    render_nodes "$STAGE/nodes.ndjson"
    jq -s . "$STAGE/nodes.ndjson" > "$STAGE/nodes.json"
    ui_step_done

    tx_begin
    if (( ng )); then
        ui_step '准备 Nginx'
        : > "$STEP_LOG"
        prepare_nginx
        render_nginx "$STAGE/nginx.conf"
        ui_step_done
    fi

    ui_step '切换并启动服务'
    : > "$STEP_LOG"
    stop_owned_services
    remove_old_files
    install_files_and_services
    configure_bbr
    install_logrotate
    install_self
    st_sets .script "$SCRIPT_VERSION"
    [[ -n $(st .installed_at) ]] || st_sets .installed_at "$(date -Is)"
    st_sets .updated_at "$(date -Is)"
    write_node_files
    start_services
    ui_step_done

    ui_step '检查端口与防护'
    : > "$STEP_LOG"
    health_check
    record_installed_versions
    atomic_install "$DRAFT" "$STATE" 600
    ui_step_done

    ui_step '清理'
    tx_commit
    post_commit_cleanup
    ui_step_done
}

write_node_files() {
    mkdir -p "$DATA_DIR"
    atomic_install "$STAGE/nodes.json" "$NODES_JSON" 600
    render_info "$STAGE/nodes.json" "$STAGE/info.txt"
    atomic_install "$STAGE/info.txt" "$INFO_FILE" 600
    jq -r '.[].link' "$STAGE/nodes.json" > "$STAGE/sub.txt"
    atomic_install "$STAGE/sub.txt" "$SUB_FILE" 600
    b64_oneline < "$SUB_FILE" | atomic_write "$SUB_B64" 600
}

post_commit_cleanup() {
    if ! needs_nginx; then release_nginx_packages || true; fi
    return 0
}

release_nginx_packages() {
    local pk hash
    pk=$(jq -c '.meta.nginx_packages // []' "$STATE" 2>/dev/null || echo '[]')
    [[ $pk != '[]' ]] || return 0
    hash=$(jq -r '.meta.nginx_hash // empty' "$STATE")
    if svc_active nginx || pgrep -x nginx >/dev/null 2>&1 || [[ $(nginx_system_hash) != "$hash" ]]; then
        ui_line 'Nginx 仍在被其他服务使用（或配置有改动），保留软件包。'
        return 0
    fi
    local -a pkgs=()
    mapfile -t pkgs < <(jq -r '.[]' <<< "$pk")
    pkg_remove "${pkgs[@]}" >/dev/null 2>&1 || { ui_warn 'Nginx 软件包清理失败，下次卸载时会重试。'; return 1; }
    jq '.meta.nginx_packages = [] | .meta.nginx_hash = ""' "$STATE" > "$STAGE/state-clean.json"
    atomic_install "$STAGE/state-clean.json" "$STATE" 600
}


state_ok() { [[ -f $STATE ]] && [[ $(jq -r '.schema // 0' "$STATE" 2>/dev/null) == "$STATE_SCHEMA" ]]; }

foreign_install_present() {
    state_ok && return 1
    [[ -e $CONFIG_FILE || -e $XRAY_BIN ]]
}

foreign_install_hint() {
    ui_err '发现不属于本脚本的 Xray 安装，为避免破坏已停止。'
    local p
    for p in "$CONFIG_FILE" "$XRAY_BIN" "$STATE"; do
        [[ -e $p ]] && ui_line "  $p"
    done
    ui_line '确认这些文件可以清理后，删除它们再重新运行。'
    return 1
}


install_self() {
    local src=$SOURCE_PATH
    mkdir -p "$SELF_DIR" "$(dirname -- "$QUICK_BIN")"
    if [[ -n $src && -f $src && $src != "$SELF_SCRIPT_PATH" ]] && grep -q "$SCRIPT_MARKER" "$src" 2>/dev/null; then
        local cur_v src_v
        src_v=$(script_version_of "$src")
        cur_v=$(script_version_of "$SELF_SCRIPT_PATH")
        if [[ -z $cur_v ]] || ver_ge "$src_v" "$cur_v"; then
            atomic_install "$src" "$SELF_SCRIPT_PATH" 700
        fi
        if [[ $src != /proc/* && $src != /dev/* ]]; then
            mkdir -p "$DATA_DIR"
            jq -cn --arg p "$src" --arg h "$(sha256_of "$src")" '{path:$p, sha256:$h}' >> "$DATA_DIR/sources.ndjson"
            jq -sc 'unique_by(.path) | .[]' "$DATA_DIR/sources.ndjson" > "$DATA_DIR/sources.ndjson.new" &&
                mv -f "$DATA_DIR/sources.ndjson.new" "$DATA_DIR/sources.ndjson"
        fi
    fi
    [[ -f $SELF_SCRIPT_PATH ]] || return 0
    if [[ -e $QUICK_BIN ]] && ! is_managed_file "$QUICK_BIN"; then
        ui_warn "$QUICK_BIN 已被其他程序占用，快捷命令未创建。"
        return 0
    fi
    printf '#!/bin/sh\n%s\nexec bash "%s" "$@"\n' "$MANAGED_TAG" "$SELF_SCRIPT_PATH" > "$QUICK_BIN"
    chmod 755 "$QUICK_BIN"
}


prepare_new_draft() {
    local s
    s=$(scheme)
    if scheme_has_reality "$s"; then
        local d
        ui_line 'REALITY 需要一个目标网站（SNI），正在测速选择...'
        if sni_auto_select d; then
            st_sets .reality.sni "$d"
            st_set .reality.sni_auto 1
        else
            note_add '自动测速没有找到可用的 SNI，请手动填写。'
        fi
    fi
    if [[ $(st .meta.selinux_note) == 1 ]]; then
        note_add 'SELinux 强制模式下，REALITY 改用 Xray 内置过滤。'
    fi
}

refresh_net_in_draft() {
    local old4 old6 host
    old4=$(st .net.v4)
    old6=$(st .net.v6)
    host=$(st .net.host)
    [[ $(st .net.manual) != 1 ]] || return 0
    if [[ -n $NET_V4 && $NET_V4 != "$old4" ]]; then
        st_sets .net.v4 "$NET_V4"
        if [[ -n $old4 && $host == "$old4" ]]; then
            st_sets .net.host "$NET_V4"
            note_add "公网 IPv4 已变化，节点地址改为 $NET_V4。"
        fi
    fi
    if [[ -n $NET_V6 && $NET_V6 != "$old6" ]]; then
        st_sets .net.v6 "$NET_V6"
        if [[ -n $old6 && $host == "$old6" ]]; then
            st_sets .net.host "$NET_V6"
            note_add '公网 IPv6 已变化，节点地址已更新。'
        fi
    fi
    return 0
}

carry_meta_from_state() {
    [[ -f $STATE ]] || return 0
    local meta
    meta=$(jq -c '.meta // {}' "$STATE" 2>/dev/null || echo '{}')
    st_filter --argjson m "$meta" '.meta = (.meta + ($m
        | {nginx_packages, nginx_hash, created_user}
        | with_entries(select(.value != null))))'
}

action_install() {
    if foreign_install_present; then
        foreign_install_hint
        return 1
    fi
    ui_line '检测网络...'
    detect_public_ips
    DRAFT=$STAGE/draft.json
    local def=1
    if state_ok; then
        MODE=modify
        load_state_draft
        PREVIEW_NOTES=()
        refresh_net_in_draft
        def=$(scheme_index "$(scheme)")
        cp "$NODES_JSON" "$STAGE/nodes-before.json" 2>/dev/null || echo '[]' > "$STAGE/nodes-before.json"
        preview_loop
        case $PREVIEW_RESULT in
            0) apply_draft; show_modify_result; return 0 ;;
            1) return 0 ;;
        esac
    fi
    while :; do
        MODE=new
        local s
        choose_scheme s "$def"
        [[ -n $s ]] || return 0
        if scheme_is_split "$s" && [[ -z $NET_V4 || -z $NET_V6 ]]; then
            ui_warn '上下行分离需要本机同时有公网 IPv4 和 IPv6。'
            ui_pause
            continue
        fi
        draft_new "$s"
        carry_meta_from_state
        prepare_new_draft
        preview_loop
        if [[ $PREVIEW_RESULT != 0 ]]; then def=$(scheme_index "$s"); continue; fi
        if state_ok; then
            if ! ask_no '覆盖安装会生成新节点，旧节点将失效。继续'; then continue; fi
        fi
        apply_draft
        show_install_result
        return 0
    done
}

firewall_hints() {
    local proto port label
    local -a lines=()
    while read -r proto port label; do
        [[ -n $port ]] || continue
        lines+=("$port/$proto")
    done < <(public_ports)
    mapfile -t lines < <(printf '%s\n' "${lines[@]}" | sort -u)
    ui_line "请在云服务商安全组放行：${lines[*]}"
    if have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
        ui_line '检测到 ufw 已启用，可执行：'
        local l
        for l in "${lines[@]}"; do ui_line "  ufw allow $l"; done
    elif have firewall-cmd && [[ $(firewall-cmd --state 2>/dev/null || true) == running ]]; then
        ui_line '检测到 firewalld 已启用，可执行：'
        local l
        for l in "${lines[@]}"; do ui_line "  firewall-cmd --permanent --add-port=$l"; done
        ui_line '  firewall-cmd --reload'
    fi
}

show_install_result() {
    ui_blank
    ui_title '安装完成'
    print_nodes
    ui_rule
    firewall_hints
    ui_line '以后输入 zxray 即可打开主页。'
}

show_modify_result() {
    ui_blank
    ui_title '已应用'
    local changed
    changed=$(jq -rn --slurpfile a "$STAGE/nodes-before.json" --slurpfile b "$NODES_JSON" '
        ($a[0] | map({(.label): .link}) | add // {}) as $old
        | $b[0][] | select($old[.label] != .link) | .label')
    if [[ -z $changed ]]; then
        ui_ok '节点链接没有变化，客户端无需改动。'
    else
        ui_warn '以下节点的链接有变化，需要重新导入：'
        local l
        while IFS= read -r l; do ui_line "  $l"; done <<< "$changed"
        ui_blank
        print_nodes
    fi
    ui_rule
    firewall_hints
}


print_nodes() {
    local n i
    [[ -f $NODES_JSON ]] || { ui_line '还没有节点，请先安装。'; return 0; }
    n=$(jq 'length' "$NODES_JSON")
    local kw=${#n} label
    for (( i = 0; i < n; i++ )); do
        fit_width "$(jq -r ".[$i].label" "$NODES_JSON")" $(( UI_W - 4 - kw )) label
        printf '  %*s  %s\n' "$kw" "$(( i + 1 ))" "$label"
        jq -r ".[$i].link" "$NODES_JSON"
    done
}

action_nodes() {
    local k n
    if [[ ! -t 1 ]] || (( ASSUME_YES )); then
        print_nodes
        return 0
    fi
    while :; do
        ui_clear
        if state_ok; then
            DRAFT=$STATE
            ui_title "节点：$(scheme_label "$(scheme)")"
        else
            ui_title '节点'
        fi
        print_nodes
        n=$(jq 'length' "$NODES_JSON" 2>/dev/null || echo 0)
        if (( n == 0 )); then ui_footer '回车返回'; read_line '' k; return 0; fi
        ui_footer '序号 显示二维码   回车 返回'
        read_line '序号：' k
        [[ $k =~ ^[1-9][0-9]?$ ]] && (( k <= n )) || return 0
        show_qr "$(jq -r ".[$((k - 1))].link" "$NODES_JSON")" "$(jq -r ".[$((k - 1))].label" "$NODES_JSON")"
    done
}

show_qr() {
    local link=$1 label=$2 k
    if ! have qrencode; then
        if ask_yes '显示二维码需要安装 qrencode'; then
            pkg_install "$(qr_package)" >/dev/null 2>&1 || true
        fi
        have qrencode || return 0
    fi
    ui_clear
    ui_title "$label"
    qrencode -t ANSIUTF8 -m 1 "$link" || ui_warn '链接太长，无法生成二维码。'
    ui_pause
}

qr_package() {
    case $PKG in apk) printf 'libqrencode-tools' ;; *) printf 'qrencode' ;; esac
}


action_maintain() {
    local k
    while :; do
        ui_clear
        ui_title '更新与维护'
        ui_item 1 '更新脚本和核心（节点不变）'
        ui_item 2 '仅重启服务'
        ui_item 3 '状态与日志'
        ui_item 4 'SNI 候选池'
        ui_footer '0 返回'
        read_line '请选择：' k
        case $k in
            1)
                run_sub action_update
                if (( SUB_RC == 21 || SUB_RC == 23 )); then exit "$SUB_RC"; fi
                return 0 ;;
            2) run_sub action_restart ;;
            3) run_sub action_status ;;
            4) run_sub action_sni_pool ;;
            '') continue ;;
            *) return 0 ;;
        esac
    done
}

run_sub() {
    run_child "$@"
    SUB_RC=$CHILD_RC
    if (( SUB_RC == 21 || SUB_RC == 23 )); then return 0; fi
    if (( SUB_RC == 130 )); then exit 130; fi
    ui_pause
    return 0
}

require_state() {
    STATE_READY=0
    if ! state_ok; then
        ui_warn '还没有安装，请先在主页选择“安装”。'
        return 0
    fi
    load_state_draft
    STATE_READY=1
}

action_update() {
    require_state
    (( STATE_READY )) || return 0
    STEP_NO=0 STEP_TOTAL=1
    ui_blank
    ui_step '检查脚本更新'
    : > "$STEP_LOG"
    local remote_v
    download_script "$STAGE/remote.sh"
    remote_v=$(script_version_of "$STAGE/remote.sh")
    if ver_ge "$SCRIPT_VERSION" "$remote_v"; then
        ui_step_skip "已是最新（v$SCRIPT_VERSION）"
    else
        [[ ! -f $SELF_SCRIPT_PATH ]] || cp -f -- "$SELF_SCRIPT_PATH" "$SELF_SCRIPT_PATH.prev"
        atomic_install "$STAGE/remote.sh" "$SELF_SCRIPT_PATH" 700
        install_self
        ui_step_skip "已更新到 v$remote_v"
        ui_line '用新版脚本继续更新核心...'
        local rc=0
        ZX_REEXEC=1 bash "$SELF_SCRIPT_PATH" --update-cores "${ASSUME_YES_FLAG[@]}" <&"$INPUT_FD" || rc=$?
        if (( rc != 0 )); then
            ui_warn '核心没有更新，节点按原样运行。'
            ui_line "如需退回旧版脚本：cp $SELF_SCRIPT_PATH.prev $SELF_SCRIPT_PATH"
            exit 23
        fi
        exit 21
    fi
    update_cores
}

update_cores() {
    require_state
    (( STATE_READY )) || return 0
    MODE=modify
    local -a todo=()
    local cur new tag
    STEP_NO=0
    STEP_TOTAL=1
    ui_step '检查核心版本'
    : > "$STEP_LOG"
    local dir=$STAGE/core
    mkdir -p "$dir"
    if needs_xray; then
        cur=$(installed_version xray)
        tag=$(latest_tag_quiet XTLS/Xray-core || true)
        if [[ -z $tag || ${tag#v} != "${cur#v}" ]]; then
            download_xray latest "$dir/xray-pkg"
            new=$(cat "$dir/xray-pkg/xray.version")
            if [[ $new != "$cur" ]] && ver_ge "$new" "${cur:-0}"; then todo+=("Xray $cur -> $new"); USE_XRAY=$dir/xray-pkg/xray USE_XRAY_ASSET=$dir/xray-pkg; fi
        fi
    fi
    if needs_ss_rust; then
        cur=$(installed_version ss)
        new=$(latest_tag shadowsocks/shadowsocks-rust)
        if [[ $new != "$cur" ]] && ver_ge "$new" "${cur:-0}"; then
            download_ss "$new" "$dir/ss-pkg"
            todo+=("SS-Rust $cur -> $new"); USE_SS=$dir/ss-pkg/ssserver
        fi
    fi
    if (( ${#todo[@]} == 0 )); then
        ui_step_skip '已是最新'
    else
        ui_step_done
        local t
        for t in "${todo[@]}"; do ui_line "$t"; done
        replace_cores
    fi
    if [[ ${ZX_REEXEC:-0} == 1 ]]; then regenerate_from_state; fi
    return 0
}

replace_cores() {
    STEP_NO=0
    STEP_TOTAL=1
    ui_blank
    if [[ -n $USE_XRAY ]]; then
        STEP_TOTAL=2
        ui_step '校验现有配置'
        validate_xray_config "$CONFIG_FILE"
        ui_step_done
    fi
    ui_step '替换并重启'
    : > "$STEP_LOG"
    tx_begin
    local s
    while read -r s; do svc_do stop "$s" >/dev/null 2>&1 || true; done < <(wanted_services)
    if [[ -n $USE_XRAY ]]; then
        install_bin "$USE_XRAY" "$XRAY_BIN"
        atomic_install "$USE_XRAY_ASSET/geoip.dat" "$XRAY_ASSET_DIR/geoip.dat" 644
        atomic_install "$USE_XRAY_ASSET/geosite.dat" "$XRAY_ASSET_DIR/geosite.dat" 644
        if xray_needs_lowport; then grant_lowport "$XRAY_BIN" 1; fi
    fi
    if [[ -n $USE_SS ]]; then
        install_bin "$USE_SS" "$SS_BIN"
        if (( $(st .ss.port) < 1024 )); then grant_lowport "$SS_BIN" 1; fi
    fi
    start_services
    health_check
    record_installed_versions
    atomic_install "$DRAFT" "$STATE" 600
    tx_commit
    ui_step_done
    ui_ok '核心已更新并重启，节点不变。'
}

regenerate_from_state() {
    ui_blank
    ui_line '用新版脚本重新生成配置（节点不变）...'
    load_state_draft
    MODE=modify
    PREVIEW_NOTES=()
    cp "$NODES_JSON" "$STAGE/nodes-before.json" 2>/dev/null || echo '[]' > "$STAGE/nodes-before.json"
    apply_draft
    show_modify_result
}

action_restart() {
    require_state
    (( STATE_READY )) || return 0
    local s
    ui_blank
    STEP_NO=0 STEP_TOTAL=2
    ui_step '重启服务'
    : > "$STEP_LOG"
    while read -r s; do
        [[ -n $s ]] || continue
        svc_do restart "$s" || svc_do start "$s" || true
    done < <(wanted_services)
    ui_step_done
    ui_step '检查端口与防护'
    health_check
    ui_step_done
}

action_status() {
    require_state
    (( STATE_READY )) || return 0
    local s v
    ui_blank
    ui_title "状态：$(scheme_label "$(scheme)")"
    while read -r s; do
        [[ -n $s ]] || continue
        if svc_active "$s"; then v='运行中'; else v='已停止'; fi
        ui_kv "$s" "$v"
    done < <(wanted_services)
    [[ -z $(installed_version xray) ]] || ui_kv 'Xray' "$(installed_version xray)"
    [[ -z $(installed_version ss) ]] || ui_kv 'SS-Rust' "$(installed_version ss)"
    local proto port label
    while read -r proto port label; do
        [[ -n $port ]] || continue
        if port_listening "$proto" "$port"; then v='监听中'; else v='未监听'; fi
        ui_kv "$port/${proto^^}" "$label $v"
    done < <(public_ports)
    ui_rule
    ui_line '最近日志'
    while read -r s; do
        [[ -n $s ]] || continue
        printf '  [%s]\n' "$s"
        if [[ $INIT == systemd ]]; then
            journalctl -u "$s" -n 8 --no-pager -o cat 2>/dev/null | cut -c1-$(( UI_W - 4 )) | sed 's/^/    /' || true
        elif [[ -f $DATA_DIR/log/$s.log ]]; then
            tail -n 8 "$DATA_DIR/log/$s.log" | cut -c1-$(( UI_W - 4 )) | sed 's/^/    /'
        fi
    done < <(wanted_services)
}

action_sni_pool() {
    local k d
    while :; do
        ui_blank
        ui_title 'SNI 候选池'
        if [[ -f $SNI_POOL_FILE ]]; then ui_line '当前使用自定义候选池：'; else ui_line '当前使用默认候选池：'; fi
        sni_pool | sed 's/^/    /'
        ui_footer 'a 添加   d 删除   r 恢复默认   0 返回'
        read_line '请选择：' k
        case $k in
            a|A)
                read_line '添加域名：' d
                d=${d,,}
                if valid_domain "$d"; then
                    [[ -f $SNI_POOL_FILE ]] || sni_pool > "$SNI_POOL_FILE"
                    grep -qxF "$d" "$SNI_POOL_FILE" || printf '%s\n' "$d" >> "$SNI_POOL_FILE"
                else ui_warn '域名格式不正确。'; fi ;;
            d|D)
                read_line '删除域名：' d
                [[ -f $SNI_POOL_FILE ]] || sni_pool > "$SNI_POOL_FILE"
                grep -vxF "${d,,}" "$SNI_POOL_FILE" > "$SNI_POOL_FILE.new" || true
                if [[ -s $SNI_POOL_FILE.new ]]; then mv -f "$SNI_POOL_FILE.new" "$SNI_POOL_FILE"
                else rm -f "$SNI_POOL_FILE.new"; ui_warn '候选池不能为空。'; fi ;;
            r|R) rm -f -- "$SNI_POOL_FILE"; ui_ok '已恢复默认候选池。' ;;
            '') continue ;;
            *) return 0 ;;
        esac
    done
}


action_uninstall() {
    if ! state_ok; then
        ui_line '没有发现本脚本部署的服务。'
        if [[ -f $SELF_SCRIPT_PATH || -f $QUICK_BIN ]] && ask_no '只删除脚本自身和快捷命令'; then
            remove_self_files
            exit 20
        fi
        return 0
    fi
    if [[ -s $DATA_DIR/sources.ndjson ]]; then
        ui_line '同时删除当初下载到本机的脚本文件（内容未改动时）：'
        jq -r '.path' "$DATA_DIR/sources.ndjson" 2>/dev/null | sed 's/^/    /' || true
    fi
    ask_no '完整卸载本脚本、核心、节点和防护配置' || return 0
    load_state_draft
    STEP_NO=0 STEP_TOTAL=3
    ui_blank
    ui_step '停止服务并删除文件'
    : > "$STEP_LOG"
    cp -f "$DATA_DIR/sources.ndjson" "$STAGE/sources.ndjson" 2>/dev/null || true
    cp -f "$STATE" "$STAGE/state-old.json"
    local own_user=0
    if [[ $(jq -r '.meta.created_user // 0' "$DRAFT" 2>/dev/null) == 1 ]]; then own_user=1; fi
    tx_begin
    stop_owned_services
    if is_managed_file "$SYSCTL_FILE"; then rm -f -- "$SYSCTL_FILE"; fi
    restore_bbr_original
    local p
    for p in "${MANAGED_PATHS[@]}"; do
        [[ $p != "$SYSCTL_FILE" && $p != "$QUICK_BIN" ]] || continue
        rm -rf -- "$p"
    done
    rm -rf -- "$NGINX_RUN" "$ROOT/etc/runlevels/default/"{xray,zxray-ss,zxray-nginx}
    svc_reload_units
    if [[ $INIT == systemd ]]; then
        for p in "${MANAGED_SERVICES[@]}"; do systemctl reset-failed "$p" >/dev/null 2>&1 || true; done
    fi
    tx_commit
    ui_step_done
    ui_step '清理软件包与用户'
    STATE=$STAGE/state-old.json release_nginx_packages || true
    if (( own_user )); then remove_service_user; fi
    ui_step_done
    ui_step '删除脚本'
    delete_recorded_sources
    remove_self_files
    ui_step_done
    ui_ok '完整卸载完成。共享的系统依赖（curl、jq 等）已保留。'
    exit 20
}

remove_self_files() {
    rm -rf -- "$SELF_DIR" "$DATA_DIR"
    if is_managed_file "$QUICK_BIN"; then rm -f -- "$QUICK_BIN"; fi
    local d
    for d in "$STAGE_BASE".*; do
        [[ -d $d && $d != "$STAGE" ]] && rm -rf -- "$d"
    done
    rm -f -- "$LOCK_FILE"
}

delete_recorded_sources() {
    [[ -f $STAGE/sources.ndjson ]] || return 0
    local rec path sha
    while IFS= read -r rec; do
        path=$(jq -r '.path' <<< "$rec")
        sha=$(jq -r '.sha256' <<< "$rec")
        [[ $path == /* && -f $path && ! -L $path ]] || continue
        if [[ $(sha256_of "$path") == "$sha" ]] && grep -q "$SCRIPT_MARKER" "$path" 2>/dev/null; then
            rm -f -- "$path"
        fi
    done < "$STAGE/sources.ndjson"
    return 0
}


usage() {
    cat <<EOF
Xray Manager v$SCRIPT_VERSION

用法：sh xray-manager.sh [选项]
      zxray [选项]

不带选项打开主页：安装或修改配置 / 节点链接 / 更新与维护 / 卸载。

选项：
  --install            安装（配合 --yes 时全部使用默认值）
  --scheme 名称        reality-raw | reality-xhttp | reality-split | ss | enc
                       dual | triple | enc-split
  --update             更新脚本和核心，节点不变
  --uninstall          完整卸载
  --nodes              显示节点链接
  --core-version 标签  安装时指定 Xray 版本
  --yes                跳过确认
  --force              跳过确认，并允许覆盖已有安装
  --version            显示脚本版本
  --help               显示帮助
EOF
}

map_scheme_name() {
    local s
    for s in "${SCHEMES[@]}"; do
        if [[ $s == "$1" ]]; then printf '%s' "$s"; return 0; fi
    done
    return 1
}

parse_args() {
    while (( $# )); do
        case $1 in
            -h|--help) usage; exit 0 ;;
            --install) ACTION=install ;;
            --update) ACTION=update ;;
            --update-cores) ACTION=update-cores ;;
            --uninstall) ACTION=uninstall ;;
            --nodes) ACTION=nodes ;;
            --yes|-y) ASSUME_YES=1; ASSUME_YES_FLAG=(--yes) ;;
            --force) ASSUME_YES=1 FORCE=1; ASSUME_YES_FLAG=(--yes) ;;
            --scheme)
                (( $# >= 2 )) || fatal '--scheme 缺少参数。'
                CLI_SCHEME=$(map_scheme_name "$2") || fatal "未知方案：$2"
                shift ;;
            --core-version)
                (( $# >= 2 )) || fatal '--core-version 缺少参数。'
                CLI_CORE_TAG=$2
                shift ;;
            --version|-V) printf 'Xray Manager v%s\n' "$SCRIPT_VERSION"; exit 0 ;;
            *) fatal "未知参数：$1（--help 查看用法）" ;;
        esac
        shift
    done
    if [[ -n $CLI_SCHEME && $ACTION == menu ]]; then ACTION=install; fi
    return 0
}

action_install_cli() {
    if foreign_install_present; then foreign_install_hint; return 1; fi
    if state_ok && (( ! FORCE )); then
        die '已有安装，覆盖会生成新节点；确认要覆盖请加 --force。'
        return 1
    fi
    detect_public_ips
    DRAFT=$STAGE/draft.json
    MODE=new
    local s=${CLI_SCHEME:-reality-raw}
    if scheme_is_split "$s" && [[ -z $NET_V4 || -z $NET_V6 ]]; then die '上下行分离需要同时有公网 IPv4 和 IPv6。'; return 1; fi
    draft_new "$s"
    carry_meta_from_state
    [[ -z $CLI_CORE_TAG ]] || st_sets .core.xray "$(normalize_tag "$CLI_CORE_TAG")"
    prepare_new_draft
    if scheme_has_reality "$s" && [[ -z $(st .reality.sni) ]]; then die '没有可用的 SNI。'; return 1; fi
    [[ -n $(st .net.host) ]] || { die '无法检测公网地址。'; return 1; }
    apply_draft
    show_install_result
}

system_running() {
    if state_ok; then
        local s any=0
        DRAFT=$STATE
        while read -r s; do
            [[ -n $s ]] || continue
            any=1
            svc_active "$s" || return 1
        done < <(wanted_services)
        (( any ))
    else
        return 1
    fi
}

show_home() {
    ui_clear
    ui_title "XRAY MANAGER v$SCRIPT_VERSION" "$C_HI"
    if state_ok; then
        DRAFT=$STATE
        ui_kv '方案' "$(scheme_label "$(scheme)")"
        ui_kv '地址' "$(st .net.host)"
        if system_running; then ui_kv '状态' "${C_GREEN}运行中${C_RESET}"; else ui_kv '状态' "${C_YELLOW}已停止${C_RESET}"; fi
    else
        ui_kv '状态' '未安装'
    fi
    ui_rule
    if state_ok; then ui_item 1 '修改配置'; else ui_item 1 '安装'; fi
    ui_item 2 '节点链接'
    ui_item 3 '更新与维护'
    ui_item 4 '卸载'
    ui_item 0 '退出'
    ui_rule
}

on_main_int() {
    (( CHILD_RUNNING )) && return 0
    printf '\n'
    exit 130
}

run_top() {
    run_child "$@"
    TOP_RC=$CHILD_RC
}

after_action() {
    local rc=$1
    case $rc in
        20) exit 0 ;;
        21|23) ui_pause; exec bash "$SELF_SCRIPT_PATH" ;;
    esac
    if [[ -e $TX ]]; then
        ui_err '仍有未完成的操作，重新运行脚本可以恢复。'
        ui_line "快照：$TX"
        exit 1
    fi
    return 0
}

main() {
    parse_args "$@"
    (( EUID == 0 )) || fatal '请用 root 运行（例如 sudo sh xray-manager.sh）。'
    ui_setup
    input_setup
    detect_system || exit 1
    ensure_deps || exit 1
    if [[ ${ZX_REEXEC:-0} != 1 ]]; then acquire_lock; fi
    trap 'on_main_int' INT
    SOURCE_PATH=${BASH_SOURCE[0]}
    if [[ -f $SOURCE_PATH ]]; then SOURCE_PATH=$(readlink -f -- "$SOURCE_PATH"); fi
    tx_recover_if_needed
    if [[ ${ZX_REEXEC:-0} != 1 ]]; then clean_stale_stages; fi

    case $ACTION in
        install)
            if (( ASSUME_YES )); then run_top action_install_cli; else run_top action_install; fi
            after_action "$TOP_RC"; exit "$TOP_RC" ;;
        update)
            run_top action_update
            if (( TOP_RC == 21 )); then exit 0; fi
            if (( TOP_RC == 23 )); then exit 1; fi
            after_action "$TOP_RC"; exit "$TOP_RC" ;;
        update-cores) run_top update_cores; exit "$TOP_RC" ;;
        uninstall) run_top action_uninstall; after_action "$TOP_RC"; exit "$TOP_RC" ;;
        nodes) run_top action_nodes; exit "$TOP_RC" ;;
    esac

    local k
    while :; do
        show_home
        read_line '请选择：' k
        case $k in
            1) run_top action_install ;;
            2) run_top action_nodes; after_action "$TOP_RC"; continue ;;
            3) run_top action_maintain; after_action "$TOP_RC"; continue ;;
            4) run_top action_uninstall ;;
            0|q|Q) ui_clear; exit 0 ;;
            *) continue ;;
        esac
        after_action "$TOP_RC"
        if (( TOP_RC != 130 )); then ui_pause; fi
    done
}

if [[ ${BASH_SOURCE[0]:-} == "$0" ]]; then main "$@"; fi
