#!/bin/sh
# shellcheck shell=bash

readonly SCRIPT_VERSION="0.3.0"
readonly XRAY_MIN_VERSION="26.10.31"
readonly SCHEME_NAMES="reality-raw reality-xhttp reality-split ss enc dual triple enc-split"
ACTION=menu ASSUME_YES=0 FORCE=0 CLI_SCHEME='' CLI_CORE_TAG=''

usage() {
    cat <<EOF
Xray Manager v$SCRIPT_VERSION

用法：sh xray-manager.sh [选项]
      zxray [选项]

支持 Debian 和 Ubuntu，需启用 systemd。不加选项时打开主页。

选项：
  --install            安装或修改配置。加 --yes 时使用指定方案和默认参数
  --scheme 方案        选择安装方案（默认 reality-raw），可省略 --install
                       reality-raw  reality-xhttp  reality-split  ss
                       enc  dual  triple  enc-split
  --core-version 版本  选择 Xray 版本，可省略 --install
                       默认 latest，可指定 v$XRAY_MIN_VERSION 或更高版本
                       使用 SS-Rust 时仅保存此偏好
  --update             更新当前方案使用的组件，保留配置
  --update-cores       同 --update（旧命令）
  --nodes              查看分享链接。加 --yes 或重定向输出时列出全部链接
  --uninstall          卸载托管组件和配置
  -y, --yes            跳过确认。覆盖已有安装还需 --force
  --force              仅限安装，跳过确认并允许覆盖已有安装
  -V, --version        显示脚本版本
  -h, --help           显示帮助
EOF
}

# Help and version also work through /bin/sh before Bash starts.
cli_known_scheme() (
    for value in $SCHEME_NAMES; do [ "$value" != "$1" ] || return 0; done
    return 1
)

cli_xray_tag_ok() {
    printf '%s\n' "$1" | LC_ALL=C awk -v minimum="$XRAY_MIN_VERSION" '
        NR == 1 && /^v?[0-9]+\.[0-9]+\.[0-9]+$/ {
            sub(/^v/, ""); split($0, v, "[.]"); split(minimum, m, "[.]"); valid=1
            for (i=1; i<=3; i++) {
                if (v[i]+0 > m[i]+0) break
                if (v[i]+0 < m[i]+0) {too_old=1; break}
            }
        }
        END {if (NR != 1 || !valid) exit 1; if (too_old) exit 2}'
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case $1 in
            -h|--help) usage; exit 0 ;;
            -V|--version) printf 'Xray Manager v%s\n' "$SCRIPT_VERSION"; exit 0 ;;
            --install|--update|--update-cores|--uninstall|--nodes)
                cli_action=${1#--}
                [ "$cli_action" != update-cores ] || cli_action=update
                if [ "$ACTION" != menu ] && [ "$ACTION" != "$cli_action" ]; then
                    printf '不能同时执行 --%s 和 %s。\n' "$ACTION" "$1" >&2; return 1
                fi
                ACTION=$cli_action ;;
            --yes|-y) ASSUME_YES=1 ;;
            --force) ASSUME_YES=1 FORCE=1 ;;
            --scheme|--core-version)
                if [ "$#" -lt 2 ]; then printf '%s 缺少参数。\n' "$1" >&2; return 1; fi
                if [ "$1" = --scheme ]; then
                    cli_known_scheme "$2" || { printf '未知方案：%s\n' "$2" >&2; return 1; }
                    CLI_SCHEME=$2
                elif [ "$2" = latest ]; then CLI_CORE_TAG=latest
                elif cli_xray_tag_ok "$2"; then CLI_CORE_TAG=v${2#v}
                else
                    case $? in
                        2) printf '%s 最低 v%s。\n' "$1" "$XRAY_MIN_VERSION" >&2 ;;
                        *) printf '%s 需要三段版本号，例如 v%s。\n' "$1" "$XRAY_MIN_VERSION" >&2 ;;
                    esac
                    return 1
                fi
                shift ;;
            *) printf '未知参数：%s（--help 查看用法）\n' "$1" >&2; return 1 ;;
        esac
        shift
    done
    if [ -n "$CLI_SCHEME" ] || [ -n "$CLI_CORE_TAG" ]; then
        if [ "$ACTION" != menu ] && [ "$ACTION" != install ]; then
            printf '%s 仅用于安装，不能与 --%s 同用。\n' '--scheme 和 --core-version' "$ACTION" >&2; return 1
        fi
        ACTION=install
    fi
    if [ "$FORCE" = 1 ] && [ "$ACTION" != install ]; then
        printf '%s\n' '--force 仅用于安装。其他操作跳过确认请用 --yes。' >&2; return 1
    fi
    return 0
}

if [ -z "${BASH_VERSION:-}" ]; then
    parse_args "$@" || exit 1
    if [ ! -f "$0" ]; then
        echo "请先把脚本下载为文件，再运行：sh xray-manager.sh" >&2
        exit 1
    fi
    if ! command -v bash >/dev/null 2>&1; then
        echo "仅支持 Debian 和 Ubuntu，需要 Bash 4.4 或更新版本。" >&2
        exit 1
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
exec 4>&1 5>&2

readonly SCRIPT_MARKER="ZXRAY_MANAGER"
readonly STATE_SCHEMA=5
readonly DEFAULT_BLOCK_DOMAIN=ping0.cc
readonly SERVICE_USER="zxray"
readonly MANAGED_TAG="# Managed by Xray Manager"
readonly RC_QUIET=10
IFS=' ' read -r -a SCHEMES <<< "$SCHEME_NAMES"
readonly -a SCHEMES
readonly DEFAULT_SNI_POOL=(c.6sc.co www.amazon.com drivers.amd.com a0.awsstatic.com d1.awsstatic.com
    s0.awsstatic.com gateway.icloud.com m.media-amazon.com addons.mozilla.org tag.demandbase.com
    t0.m.awsstatic.com images-na.ssl-images-amazon.com)

init_paths() {
    ROOT=${1:-}
    DATA_DIR=$ROOT/usr/local/share/zxray
    SELF_DIR=$ROOT/usr/local/lib/zxray
    SELF_SCRIPT_PATH=$SELF_DIR/zxray.sh
    QUICK_BIN=$ROOT/usr/local/bin/zxray
    PUBLIC_XRAY=$ROOT/usr/local/bin/xray
    STATE=$DATA_DIR/state.json
    CONFIG_DIR=$ROOT/usr/local/etc/xray
    CONFIG_FILE=$CONFIG_DIR/config.json
    CORE_BIN=$SELF_DIR/xray
    XRAY_BIN=$CORE_BIN
    LEGACY_CORE_OWNED=0
    XRAY_ASSET_DIR=$ROOT/usr/local/share/xray
    SS_BIN=$SELF_DIR/ssserver
    SS_CONFIG=$DATA_DIR/ssserver.json
    SS_ACL=$DATA_DIR/ssserver.acl
    NGINX_DIR=$DATA_DIR/nginx
    NGINX_RUN=$ROOT/run/zxray-nginx
    NODES_JSON=$DATA_DIR/nodes.json
    INFO_FILE=$DATA_DIR/node-info.txt
    SUB_FILE=$DATA_DIR/subscription.txt
    SUB_B64=$DATA_DIR/subscription.b64
    SNI_POOL_FILE=$DATA_DIR/sni-pool.txt
    TX=$ROOT/usr/local/share/zxray-transaction
    STAGE_BASE=$ROOT/usr/local/share/zxray-stage
    LOCK_FILE=$ROOT/run/zxray.lock
    SYSCTL_FILE=$ROOT/etc/sysctl.d/99-zxray-bbr.conf
    SYSTEMD_DIR=$ROOT/etc/systemd/system
    OLD_DATA_DIR=$ROOT/usr/local/share/doudou-xray
    OLD_SELF_SCRIPT=$ROOT/usr/local/lib/doudou/xray_manager.sh
    # Snapshot slots follow this order. tx_load_paths also recognizes the 0.2.x layout.
    # CORE_BIN is already included through SELF_DIR.
    MANAGED_PATHS=(
        "$DATA_DIR" "$SELF_DIR" "$CONFIG_DIR" "$PUBLIC_XRAY" "$XRAY_ASSET_DIR"
        "$SYSTEMD_DIR/xray.service" "$SYSTEMD_DIR/zxray-ss.service" "$SYSTEMD_DIR/zxray-nginx.service"
        "$ROOT/etc/logrotate.d/zxray" "$QUICK_BIN" "$SYSCTL_FILE"
    )
    MANAGED_SERVICES=(xray zxray-ss zxray-nginx)
}
init_paths ''

STAGE='' TX_ACTIVE=0 IN_ROLLBACK=0 KEEP_TX=0 ACTION_PID='' CHILD_RUNNING=0
LOCK_OWNER='' DRAFT_GENERATION='' SOURCE_DIGEST=''
INPUT_FD=0 INPUT_TTY_STATE='' SOURCE_PATH='' DRAFT=''
INPUT_SUPERVISORS=()
SOURCE_RECORD='' SOURCE_CLEANUP_LEFT=0
STEP_NO=0 STEP_TOTAL=0 STEP_OPEN=0 STEP_LOG='' STEP_LABEL='' DIE_SHOWN=0
CHILD_RC=0 SUB_RC=0 TOP_RC=0 TOP_QUIET=0 STATE_READY=0
MODE=new PREVIEW_RESULT=1 PORT_NOTE='' DRAFT_WATCH=0 DRAFT_BASE=''
PREVIEW_NOTES=() CREATED_DIRS=()
SNI_POOL_STAGED=0
UPDATE_BG_PID='' UPDATE_BG_TMP=''
NET_V4='' NET_V6=''
SNI_BEST_MS=0
PARSE_ERR=''
SERVICE_USER_CREATED=0
NGINX_MODULE_LINE='' NGINX_SUPPORTS_E=0 NGINX_SUPPORTS_KEEPALIVE=0 NGINX_PROBE_ERR=''
USE_XRAY='' USE_XRAY_ASSET='' USE_SS=''
NEW_XRAY=0 NEW_SS=0 GEO_REFRESH=0 FULL_GEO_DIR=''
UI_W=60 UI_H=24 LABEL_W=12 KEY_W=1 UI_UTF8=1
TUI=0 TUI_REVIEW_FIRST=0 TUI_KEY='' TUI_CUR=0 TUI_TOP=0 TUI_HEAD=0 TUI_PREV_OK=0 INPUT_DIRTY=0 STEP_PW=0 TUI_MSG='' TUI_RESIZED=0 TUI_HELP_H=0 TUI_FOOT='' TUI_FOOT_PLAIN=''
UI_BUF_ON=0 SPIN_PID=''
UI_BUF=() TUI_ITEMS=() TUI_IKEYS=() TUI_HELPS=() TUI_PREV=()
C_KEY='' C_GROUP='' C_RULE='' C_DIM='' C_BOLD='' C_GREEN='' C_YELLOW='' C_RED='' C_RESET='' C_TITLE='' C_TITLE_OK='' C_BRAND=''

NGINX_LEGACY_COLLATE=${LC_COLLATE:-}

ui_setup_locale() {
    local loc current=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
    local -a candidates=("$current" C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8)
    unset LANGUAGE
    while IFS= read -r loc; do
        case ${loc,,} in *utf8*|*utf-8*) candidates+=("$loc") ;; esac
    done < <(locale -a 2>/dev/null || true)
    for loc in "${candidates[@]}"; do
        [[ -n $loc ]] || continue
        if LC_ALL=$loc bash -c 's="端口"; [[ ${#s} == 2 ]]' 2>/dev/null; then
            unset LC_ALL
            export LANG=$loc LC_CTYPE=$loc LC_COLLATE=C LC_MESSAGES=C LC_NUMERIC=C
            UI_UTF8=1
            return 0
        fi
    done
    export LC_ALL=C
    UI_UTF8=0 TUI=0
}

ui_measure() {
    local sz=''
    if input_is_tty; then sz=$(stty size <&"$INPUT_FD" 2>/dev/null || true); fi
    if [[ ! $sz =~ ^[0-9]+\ [0-9]+$ && -t 1 ]]; then sz="$(tput lines 2>/dev/null || true) $(tput cols 2>/dev/null || true)"; fi
    [[ $sz =~ ^([0-9]+)\ ([0-9]+)$ ]] || return 0
    (( BASH_REMATCH[1] > 0 && BASH_REMATCH[2] > 0 )) || return 0
    UI_H=${BASH_REMATCH[1]}
    UI_W=${BASH_REMATCH[2]}
    (( UI_W <= 60 )) || UI_W=60
    # Small terminals use the plain menu instead of drawing outside the viewport.
    (( UI_W >= 20 )) || UI_W=20
    (( UI_H >= 3 )) || UI_H=3
}

ui_ansi_tty() { [[ -t 1 && ${TERM:-dumb} != dumb ]]; }
ui_menu_tty() { (( UI_UTF8 && ! ASSUME_YES )) && ui_ansi_tty && input_is_tty; }

ui_setup() {
    ui_setup_locale
    ui_measure
    if ui_ansi_tty && [[ -z ${NO_COLOR:-} ]]; then
        C_KEY=$'\e[36m'
        C_GROUP=$'\e[1;36m'
        C_RULE=$'\e[90m'
        C_DIM=$'\e[90m'
        C_BOLD=$'\e[1m'
        C_GREEN=$'\e[32m'
        C_YELLOW=$'\e[33m'
        C_RED=$'\e[31m'
        C_RESET=$'\e[0m'
        C_TITLE=$'\e[1;36m'
        C_TITLE_OK=$'\e[1;92m'
        C_BRAND=$'\e[1;93m'
    fi
    if (( UI_W >= 40 && UI_H >= 12 )) && ui_menu_tty; then TUI=1; fi
    return 0
}

byte_len() { local LC_ALL=C; printf -v "$2" '%d' "${#1}"; }

strip_ansi() {
    local __sa_s=$1
    if [[ $__sa_s != *$'\e'* ]]; then printf -v "$2" '%s' "$__sa_s"; return 0; fi
    while [[ $__sa_s =~ $'\e'\[[0-9\;]*m ]]; do __sa_s=${__sa_s/"${BASH_REMATCH[0]}"/}; done
    printf -v "$2" '%s' "$__sa_s"
}

# A fast, no-fork width path for ASCII + common wide CJK/fullwidth characters.
# Other Unicode (including emoji, narrow accented letters and combining sequences)
# deliberately falls back to wc -L rather than applying an incorrect byte heuristic.
ui_fast_wide() {
    local __uw_s=$1 __uw_tail __uw_b
    case $__uw_s in
        *$'\u200d'*|*$'\ufe0e'*|*$'\ufe0f'*|*$'\u20e3'*|*$'\u3099'*|*$'\u309a'*) return 1 ;;
    esac
    local LC_ALL=C
    # Only shortcut known double-width ranges; defer mixed scripts to wc -L.
    [[ $__uw_s != *[$'\xc2'-$'\xe2'$'\xea'-$'\xee'$'\xf0'-$'\xf4']* &&
       $__uw_s != *$'\xe4'[$'\x80'-$'\xb7']* ]] || return 1
    __uw_tail=$__uw_s
    while [[ $__uw_tail == *$'\xe3'* ]]; do
        __uw_tail=${__uw_tail#*$'\xe3'}
        [[ ${__uw_tail:0:2} == $'\x80'[$'\x80'-$'\xa9'] ]] || return 1
    done
    # EF also contains narrow halfwidth/format code points; whitelist only
    # fullwidth forms in EF BC, part of EF BD, and currency forms EF BF A0-A6.
    __uw_tail=$__uw_s
    while [[ $__uw_tail == *$'\xef'* ]]; do
        __uw_tail=${__uw_tail#*$'\xef'}
        [[ ${#__uw_tail} -ge 2 ]] || return 1
        __uw_b=${__uw_tail:1:1}
        case ${__uw_tail:0:1} in
            $'\xbc') [[ $__uw_b != $'\x80' ]] || return 1 ;;
            $'\xbd') [[ $__uw_b < $'\xa1' ]] || return 1 ;;
            $'\xbf') [[ $__uw_b == [$'\xa0'-$'\xa6'] ]] || return 1 ;;
            *) return 1 ;;
        esac
    done
    return 0
}

str_width() {
    local __sw_s __sw_chars __sw_bytes __sw_w __sw_joined=0
    strip_ansi "$1" __sw_s
    __sw_chars=${#__sw_s}
    byte_len "$__sw_s" __sw_bytes
    if (( __sw_chars == __sw_bytes )); then
        printf -v "$2" '%d' "$__sw_chars"
        return 0
    fi
    if ui_fast_wide "$__sw_s"; then
        printf -v "$2" '%d' $(( __sw_chars + (__sw_bytes - __sw_chars) / 2 ))
        return 0
    fi
    if [[ $__sw_s == *$'\u200d'* ]]; then
        local __sw_unit
        local -a __sw_units=()
        mapfile -t __sw_units < <(display_units "$__sw_s")
        # Measure the remaining text together. Starting wc for each ordinary
        # character made one joined emoji stall a whole log line.
        __sw_s=''
        for __sw_unit in "${__sw_units[@]}"; do
            case $__sw_unit in
                $'\u200d') ;;
                *$'\u200d'*) __sw_joined=$(( __sw_joined + 2 )) ;;
                $'\t') __sw_s+='        ' ;;
                $'\r'|$'\f') ;;
                *) __sw_s+=$__sw_unit ;;
            esac
        done
        __sw_chars=${#__sw_s}
        byte_len "$__sw_s" __sw_bytes
    fi
    __sw_w=$(printf '%s\n' "$__sw_s" | wc -L 2>/dev/null) || __sw_w=$(( __sw_chars + (__sw_bytes - __sw_chars) / 2 ))
    [[ $__sw_w =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] || __sw_w=$(( __sw_chars + (__sw_bytes - __sw_chars) / 2 ))
    printf -v "$2" '%d' "$(( __sw_w + __sw_joined ))"
}

display_units() {
    local s=$1 i=0 n=${#1} unit ch after
    local flags='🇦🇧🇨🇩🇪🇫🇬🇭🇮🇯🇰🇱🇲🇳🇴🇵🇶🇷🇸🇹🇺🇻🇼🇽🇾🇿'
    local tones='🏻🏼🏽🏾🏿'
    while (( i < n )); do
        unit=${s:i:1}
        i=$(( i + 1 ))
        if [[ $flags == *"$unit"* && $i -lt $n ]]; then
            after=${s:i:1}
            if [[ $flags == *"$after"* ]]; then unit+=$after; i=$(( i + 1 )); fi
        fi
        while (( i < n )); do
            ch=${s:i:1}
            case $ch in
                $'\ufe0e'|$'\ufe0f'|$'\u20e3') unit+=$ch; i=$(( i + 1 )) ;;
                $'\u200d')
                    unit+=$ch; i=$(( i + 1 ))
                    if (( i < n )); then unit+=${s:i:1}; i=$(( i + 1 )); fi ;;
                *)
                    if [[ $tones == *"$ch"* ]]; then unit+=$ch; i=$(( i + 1 ))
                    else break; fi ;;
            esac
        done
        printf '%s\n' "$unit"
    done
}

# Only multi-code-point emoji sequences need the subprocess-backed grapheme
# splitter. Ordinary CJK/ASCII text is split directly in the calling shell.
ui_complex_clusters() {
    local __uc_s=$1
    case $__uc_s in
        *$'\u200d'*|*$'\ufe0e'*|*$'\ufe0f'*|*$'\u20e3'*) return 0 ;;
    esac
    local LC_ALL=C
    [[ $__uc_s == *[$'\xf0'-$'\xf4']* ]]
}

ui_split_units() {
    local __us_s=$1 __us_dest=$2 __us_i __us_len=${#1}
    local -n __us_array=$__us_dest
    __us_array=()
    if ui_complex_clusters "$__us_s"; then
        mapfile -t __us_array < <(display_units "$__us_s")
    else
        for (( __us_i=0; __us_i < __us_len; __us_i++ )); do
            __us_array+=("${__us_s:__us_i:1}")
        done
    fi
}

fit_width() {
    local __fw_s=$1 __fw_max=$2 __fw_cur __fw_out __fw_head __fw_tail __fw_i __fw_ch __fw_w __fw_acc
    # A byte-only locale cannot safely truncate Chinese or emoji.
    if (( ! UI_UTF8 )); then printf -v "$3" '%s' "$__fw_s"; return 0; fi
    str_width "$__fw_s" __fw_cur
    if (( __fw_cur <= __fw_max )); then
        printf -v "$3" '%s' "$__fw_s"
        return 0
    fi
    strip_ansi "$__fw_s" __fw_s
    local -a __fw_units=()
    ui_split_units "$__fw_s" __fw_units
    if (( __fw_max < 8 )); then
        __fw_out='' __fw_acc=0
        for (( __fw_i = 0; __fw_i < ${#__fw_units[@]}; __fw_i++ )); do
            __fw_ch=${__fw_units[$__fw_i]}
            str_width "$__fw_ch" __fw_w
            (( __fw_acc + __fw_w <= __fw_max )) || break
            __fw_out+=$__fw_ch
            __fw_acc=$(( __fw_acc + __fw_w ))
        done
        printf -v "$3" '%s' "$__fw_out"
        return 0
    fi
    __fw_head=$(( (__fw_max - 3) * 3 / 5 ))
    [[ ${4:-} != end ]] || __fw_head=$(( __fw_max - 3 ))
    __fw_tail=$(( __fw_max - 3 - __fw_head ))
    __fw_out='' __fw_acc=0
    for (( __fw_i = 0; __fw_i < ${#__fw_units[@]}; __fw_i++ )); do
        __fw_ch=${__fw_units[$__fw_i]}
        str_width "$__fw_ch" __fw_w
        (( __fw_acc + __fw_w <= __fw_head )) || break
        __fw_out+=$__fw_ch
        __fw_acc=$(( __fw_acc + __fw_w ))
    done
    local __fw_back='' __fw_bacc=0
    for (( __fw_i = ${#__fw_units[@]} - 1; __fw_i >= 0; __fw_i-- )); do
        __fw_ch=${__fw_units[$__fw_i]}
        str_width "$__fw_ch" __fw_w
        (( __fw_bacc + __fw_w <= __fw_tail )) || break
        __fw_back=$__fw_ch$__fw_back
        __fw_bacc=$(( __fw_bacc + __fw_w ))
    done
    printf -v "$3" '%s...%s' "$__fw_out" "$__fw_back"
}

# Continuation lines align with the first visible character after the prefix.
ui_text_row() {
    local prefix=$1 body=$2 color=${3:-} reset='' indent w line
    str_width "$prefix" w
    printf -v indent '%*s' "$w" ''
    [[ -z $color ]] || reset=$C_RESET
    wrap_text "$body" $(( UI_W - w )) body
    while IFS= read -r line; do
        ui_emit "$prefix$color$line$reset"
        prefix=$indent
    done <<< "$body"
}

ui_emit() {
    if (( UI_BUF_ON )); then UI_BUF+=("$1"); else printf '%s\n' "$1" >&4; fi
}

rule_line() {
    local __rl_l __rl_char=${2:--}
    if (( TUI )); then
        case $__rl_char in -) __rl_char='─' ;; =) __rl_char='═' ;; esac
    fi
    printf -v __rl_l '%*s' "$UI_W" ''
    printf -v "$1" '%s%s%s' "$C_RULE" "${__rl_l// /$__rl_char}" "$C_RESET"
}

ui_rule() { local l; rule_line l; ui_emit "$l"; }
ui_rule_thick() { local l; rule_line l '='; ui_emit "$l"; }
ui_line() { ui_colored '' 4 "$*"; }
ui_code() { step_break; ui_emit "  $*"; }
ui_blank() { step_break; ui_emit ''; }

ui_colored() {
    local c=$1 fd=$2 t=$3 l r=$C_RESET
    step_break
    [[ -n $c ]] || r=''
    wrap_text "$t" $(( UI_W - 2 )) t
    while IFS= read -r l; do
        if (( UI_BUF_ON )); then UI_BUF+=("  $c$l$r"); else printf '  %s%s%s\n' "$c" "$l" "$r" >&"$fd"; fi
    done <<< "$t"
}

ui_note() { ui_colored "$C_DIM" 4 "$*"; }
ui_ok() { ui_colored "$C_GREEN" 4 "$*"; }
ui_warn() { ui_colored "$C_YELLOW" 5 "$*"; }
ui_err() { ui_colored "$C_RED" 5 "$*"; }

ui_hint() {
    local l
    while IFS= read -r l; do ui_note "$l"; done <<< "$1"
}

die() {
    local m
    ui_step_fail
    for m in "$@"; do ui_err "$m"; done
    DIE_SHOWN=1
    [[ -z $STAGE || ! -d $STAGE ]] || : > "$STAGE/.died"
    return 1
}
fatal() { ui_err "$*"; exit 1; }

ui_banner() {
    local t='XRAY MANAGER' v="  v$SCRIPT_VERSION" w l line
    if (( TUI && UI_H <= 14 )); then
        fit_width "$t$v" $(( UI_W - 2 )) line end
        ui_emit "  $C_BRAND$line$C_RESET"
        ui_rule
        (( ! UI_BUF_ON )) || TUI_HEAD=${#UI_BUF[@]}
        return 0
    fi
    str_width "$t$v" w
    l=$(( (UI_W - w) / 2 ))
    ui_rule_thick
    printf -v line '%*s%s%s%s%s%s%s' "$l" '' "$C_BRAND" "$t" "$C_RESET" "$C_DIM" "$v" "$C_RESET"
    ui_emit "$line"
    ui_rule_thick
    (( ! UI_BUF_ON )) || TUI_HEAD=${#UI_BUF[@]}
}

ui_title() {
    local text=$1 sub=${2:-} c=$C_TITLE h0=${#UI_BUF[@]} w
    [[ ${3:-} != ok ]] || c=$C_TITLE_OK
    ui_rule_thick
    str_width "$text    $sub" w
    if [[ -n $sub ]] && (( w <= UI_W - 2 )); then
        ui_emit "  $c$text$C_RESET    $C_DIM$sub$C_RESET"
    else
        ui_text_row '  ' "$text" "$c"
        [[ -z $sub ]] || ui_text_row '  ' "$sub" "$C_DIM"
    fi
    ui_rule
    (( ! UI_BUF_ON || h0 > 0 )) || TUI_HEAD=${#UI_BUF[@]}
}

ui_page() {
    KEY_W=1
    ui_clear
    ui_title "$@"
}

ui_group() { ui_text_row '  ' "$1" "$C_GROUP"; }

ui_field() {
    local prefix=$1 label=$2 col=$3 value=$4 note=$5 pad indent lw pw w body
    if [[ -z $value && -z $note ]]; then
        ui_text_row "$prefix" "$label"
        return 0
    fi
    str_width "$prefix" pw
    str_width "$label" lw
    (( col > lw )) || col=$(( lw + 1 ))
    if (( UI_W - pw - col >= 12 )); then
        printf -v pad '%*s' $(( col - lw )) ''
        printf -v indent '%*s' $(( pw + col )) ''
        prefix+="$label$pad"
    else
        [[ -z $label ]] || ui_text_row "$prefix" "$label"
        printf -v indent '%*s' $(( pw + 2 )) ''
        prefix=$indent
    fi
    if [[ -n $note && -n $value ]]; then
        body="$value  $C_DIM$note$C_RESET"
        str_width "$prefix$body" w
        if [[ $body != *$'\n'* ]] && (( w <= UI_W )); then ui_emit "$prefix$body"; return 0; fi
        ui_text_row "$prefix" "$value"
        prefix=$indent
    elif [[ -z $note ]]; then
        ui_text_row "$prefix" "$value"
        return 0
    fi
    ui_text_row "$prefix" "$note" "$C_DIM"
}

ui_item() {
    local key
    printf -v key '%*s' "$KEY_W" "$1"
    ui_field "   $C_KEY$key$C_RESET  " "$2" "$LABEL_W" "${3:-}" "${4:-}"
}

ui_cont() {
    local prefix
    printf -v prefix '%*s' $(( KEY_W + 5 )) ''
    ui_field "$prefix" '' "$LABEL_W" "$1" "${2:-}"
    if (( UI_BUF_ON && ${#TUI_ITEMS[@]} )); then menu_item_end[-1]=$(( ${#UI_BUF[@]} - 1 )); fi
}

ui_kv() { ui_field '  ' "$1" "$LABEL_W" "${2:-}" "${3:-}"; }

ui_kv_words() {
    local label=$1 word line='' w
    shift
    for word in "$@"; do
        str_width "$line $word" w
        if [[ -n $line ]] && (( w > UI_W - 2 - LABEL_W )); then
            ui_kv "$label" "$line"
            label='' line=''
        fi
        line+=${line:+ }$word
    done
    ui_kv "$label" "$line"
}

ui_option() {
    local key label=$2 desc=$3 cur=$4 col=$5 prefix lw w pad
    printf -v key '%*s' "$KEY_W" "$1"
    prefix="   $C_KEY$key$C_RESET  "
    str_width "$label" lw
    (( col > lw )) || col=$(( lw + 1 ))
    if (( cur )); then
        str_width "$desc" w
        w=$(( UI_W - 5 - KEY_W - col - w - 4 ))
        if [[ $desc != *$'\n'* ]] && (( w >= 2 )); then
            printf -v pad '%*s' "$w" ''
            ui_field "$prefix" "$label" "$col" "$C_DIM$desc$C_RESET$pad${C_GREEN}当前$C_RESET" ''
            return 0
        fi
        label+="  ${C_GREEN}当前$C_RESET"
    fi
    ui_field "$prefix" "$label" "$col" '' "$desc"
}

footer_lines() {
    local text=$1 seg key row='' part wrapped w used=0
    local -n footer_out=$2
    footer_out=()
    if [[ $ACTION == menu && -n $ACTION_PID ]]; then text+='   b 主页'; fi
    if (( TUI )); then text=${text//上下键/↑↓}; fi
    while [[ -n $text ]]; do
        seg=${text%%   *}
        if [[ $text == *'   '* ]]; then text=${text#*   }; else text=''; fi
        [[ -n $seg ]] || continue
        key=${seg%% *}
        case $key in Esc|q|Q) seg="q/Esc${seg#"$key"}"; key=q/Esc ;; esac
        str_width "$seg" w
        if [[ -n $row ]] && (( used + 2 + w > UI_W - 2 )); then
            footer_out+=("  $row"); row='' used=0
        fi
        if (( w > UI_W - 2 )); then
            wrap_text "$seg" "$(( UI_W - 2 ))" wrapped
            while IFS= read -r part; do footer_out+=("  $part"); done <<< "$wrapped"
            continue
        fi
        if [[ -n $row ]]; then row+='  '; used=$(( used + 2 )); fi
        row+="$C_KEY$key$C_RESET${seg#"$key"}"
        used=$(( used + w ))
    done
    if [[ -n $row ]]; then footer_out+=("  $row"); fi
}

ui_footer() {
    local line
    local -a lines=()
    ui_rule_thick
    footer_lines "$*" lines
    for line in "${lines[@]}"; do ui_emit "$line"; done
}

step_mark() { [[ -z $STAGE || ! -d $STAGE ]] || : > "$STAGE/.step$STEP_NO-$1"; }
step_has() { [[ -n $STAGE && -e $STAGE/.step$STEP_NO-$1 ]]; }

step_prefix() {
    local w d dots col n
    str_width "$STEP_LABEL" w
    col=$(( UI_W - 18 ))
    (( col <= 28 )) || col=28
    dots=$(( col - w - 1 ))
    (( dots >= 3 )) || dots=3
    printf -v d '%*s' "$dots" ''
    n="[$STEP_NO/$STEP_TOTAL]"
    STEP_PW=$(( 2 + ${#n} + 1 + w + 1 + dots + 1 ))
    if (( STEP_PW + 4 > UI_W )); then
        ui_text_row '  ' "$C_KEY$n$C_RESET $STEP_LABEL"
        STEP_PW=2
        printf '  ' >&4
        return 0
    fi
    printf '  %s%s%s %s %s%s%s ' "$C_KEY" "$n" "$C_RESET" "$STEP_LABEL" "$C_RULE" "${d// /.}" "$C_RESET" >&4
}

spin_start() {
    (( TUI )) || return 0
    local owner=$BASHPID room=$(( UI_W - STEP_PW ))
    (( room >= 2 )) || return 0
    (
        trap - ERR INT TERM HUP EXIT TSTP
        set +e
        i=0 t0=$SECONDS
        f=('|' '/' '-' '\')
        while sleep 0.25; do
            kill -0 "$owner" 2>/dev/null || exit 0
            i=$(( i + 1 ))
            e=$(( SECONDS - t0 ))
            if (( e >= 2 && room >= 7 )); then printf '\e7%s %ds\e8' "${f[i % 4]}" "$e"
            else printf '\e7%s\e8' "${f[i % 4]}"; fi
        done
    ) >&4 2>/dev/null 3>&- 4>&- 5>&- 8>&- 9>&- &
    SPIN_PID=$!
}

spin_stop() {
    [[ -n $SPIN_PID ]] || return 0
    kill "$SPIN_PID" 2>/dev/null || true
    wait "$SPIN_PID" 2>/dev/null || true
    SPIN_PID=''
    printf '\e[K' >&4
}

step_break() {
    (( STEP_OPEN == 1 )) || return 0
    spin_stop
    step_has break || printf '\n' >&4
    STEP_OPEN=2
    step_mark break
}

step_end() {
    (( STEP_OPEN )) || return 0
    spin_stop
    if step_has end; then STEP_OPEN=0; return 0; fi
    if (( STEP_OPEN == 2 )) || step_has break; then step_prefix; fi
    local r=$1 w
    str_width "$r" w
    if (( w <= UI_W - STEP_PW )); then
        printf '%s\n' "$r" >&4
    else
        printf '\n' >&4
        ui_text_row '  ' "$r"
    fi
    STEP_OPEN=0
    step_mark end
}

ui_step() {
    tty_echo -echo
    INPUT_DIRTY=1
    STEP_NO=$(( STEP_NO + 1 ))
    [[ -z $STAGE || ! -d $STAGE ]] || rm -f -- "$STAGE/.step$STEP_NO-break" "$STAGE/.step$STEP_NO-end"
    STEP_LABEL=$1
    step_prefix
    STEP_OPEN=1
    spin_start
}
ui_step_done() { step_end "${C_GREEN}完成${C_RESET}"; }
ui_step_fail() { step_end "${C_RED}失败${C_RESET}"; }
ui_step_skip() { step_end "${C_DIM}${1:-跳过}${C_RESET}"; }

ui_clear() {
    (( ! UI_BUF_ON )) || return 0
    if ui_ansi_tty; then printf '\e[H\e[2J' >&4; fi
}

tui_cursor() {
    ui_ansi_tty || return 0
    if [[ $1 == on ]]; then printf '\e[?25h' >&4; else printf '\e[?25l' >&4; fi
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
    if input_is_tty; then INPUT_TTY_STATE=$(stty -g <&"$INPUT_FD" 2>/dev/null || true); fi
}

input_is_tty() { [[ -t $INPUT_FD ]]; }

tty_echo() {
    input_is_tty || return 0
    stty "$1" <&"$INPUT_FD" 2>/dev/null || true
}

ui_flush() {
    INPUT_DIRTY=0
    input_is_tty || return 0
    local _f _i
    for (( _i=0; _i<32; _i++ )); do
        IFS= read -r -s -n 64 -t 0.02 -u "$INPUT_FD" _f 2>/dev/null || break
    done
    return 0
}

on_tstp() {
    local pid=$BASHPID pgrp sid
    read -r pgrp sid < <(awk '{sub(/^.*\) /, ""); print $3, $4}' "/proc/$pid/stat" 2>/dev/null) || return 0
    [[ $pgrp =~ ^[0-9]+$ && $sid =~ ^[0-9]+$ ]] && (( pgrp > 1 && pgrp != sid )) || return 0
    tui_cursor on
    tty_echo "${INPUT_TTY_STATE:-echo}"
    if [[ ${LOG_VIEW_ACTIVE:-0} == 1 ]]; then printf '\e[0m\e[?1049l' >&4; fi
    printf '\n  %s\n' 'zxray 将暂停。在本终端运行 jobs -l 查看作业，用 fg %作业号 恢复。' >&4
    trap - TSTP
    # Suspend the whole job only after the active view has restored the terminal.
    # SIGTSTP preserves the kernel's orphaned process-group protection.
    kill -TSTP -- "-$pgrp" 2>/dev/null || true
    trap on_tstp TSTP
    if [[ ${LOG_VIEW_ACTIVE:-0} == 1 ]]; then printf '\e[?1049h\e[H\e[2J' >&4; fi
    tty_echo -echo
    tui_cursor off
    TUI_PREV_OK=0
    TUI_RESIZED=1
}

check_input_session() {
    (( ${#INPUT_SUPERVISORS[@]} )) || return 0
    # Each asynchronous action has a waiting parent. A plain kill -0 on the
    # top manager would miss a missing intermediate parent or a recycled PID.
    local pid=$BASHPID stat state ppid pgrp sid tty fg i
    local -a chain=("${INPUT_SUPERVISORS[@]}" "$ACTION_PID")
    [[ $pid == "$ACTION_PID" ]] || chain+=("$pid")  # log viewer subshell
    for (( i=${#chain[@]}-1; i>0; i-- )); do
        stat=$(< "/proc/${chain[i]}/stat") 2>/dev/null || stat=''
        stat=${stat##*) }; stat=${stat#* }
        [[ ${stat%% *} == "${chain[i-1]}" ]] && continue
        # Exit through the action's cleanup trap. Restore a live terminal only
        # while this process group still owns its foreground.
        trap '' PIPE TTOU
        stat=$(< "/proc/$pid/stat") || stat=''
        read -r state ppid pgrp sid tty fg _ <<< "${stat##*) }"
        if [[ ${LOG_VIEW_ACTIVE:-0} == 1 && $pid != "$ACTION_PID" ]]; then
            # The viewer's EXIT handler restores a menu-local raw mode. Its
            # caller may be gone; restore only the original foreground state.
            trap - EXIT
        fi
        if [[ -n $INPUT_TTY_STATE && $pgrp == "$fg" && $fg =~ ^[1-9][0-9]*$ ]]; then
            if [[ ${LOG_VIEW_ACTIVE:-0} == 1 ]]; then printf '\e[0m\e[?1049l' >&4 || :; fi
            tty_echo "$INPUT_TTY_STATE"
            tui_cursor on || :
        fi
        exit 143
    done
}

input_eof() {
    # A disconnected client can close output and input together.
    trap '' PIPE
    printf '\n' >&4 2>/dev/null || :
    if [[ -n $ACTION_PID ]]; then
        exit 130
    fi
    exit 0
}

draft_hash() {
    {
        jq -S -c . "$DRAFT" || return 1
        if (( SNI_POOL_STAGED )); then
            if [[ -f $STAGE/sni-pool.txt ]]; then
                printf '%s\n' 'CUSTOM_SNI_POOL_PRESENT'
                cat -- "$STAGE/sni-pool.txt"
            else
                printf '%s\n' 'DEFAULT_SNI_POOL'
            fi
        fi
    } | sha256sum | cut -c1-16
}

draft_watch_start() { DRAFT_BASE=$(draft_hash); DRAFT_WATCH=1; }
draft_watch_stop() { DRAFT_WATCH=0; DRAFT_BASE=''; }
draft_changed() { [[ -n $DRAFT_BASE && $(draft_hash) != "$DRAFT_BASE" ]]; }

confirm_discard() {
    (( DRAFT_WATCH )) && draft_changed || return 0
    # Plain-mode confirmations also use read_line. A second b is not consent.
    local confirming_discard=1
    ask_no "$1"
}

go_home_if_b() {
    [[ ( $1 == b || $1 == B ) && $ACTION == menu && -n $ACTION_PID && ${confirming_discard:-0} == 0 ]] || return 0
    confirm_discard '放弃未应用的修改并回主页？' || return 1
    exit 130
}

input_prompt() {
    local width
    str_width "$1" width
    if (( width <= UI_W - 8 )); then
        printf -v "$2" '%s' "$1"
    else
        ui_text_row '  ' "$1"
        printf -v "$2" '%s' '> '
    fi
}

draw_input_line() {
    local prompt=$1 left=$2 right=$3 w room
    str_width "$prompt" w
    room=$(( UI_W - w - 3 ))
    if (( ${#left} > room )); then left=${left: -room}; fi
    str_width "$left" w
    while (( w > room )); do left=${left:1}; str_width "$left" w; done
    right=${right:0:room-w}
    str_width "$left$right" w
    while (( w > room )); do right=${right%?}; str_width "$left$right" w; done
    printf '\r\e[2K  %s%s\e7%s\e8' "$prompt" "$left" "$right" >&4
}

tty_edit_line() {
    local prompt=$1 mode=$4 left=$3 right='' key saved rc=0
    saved=$(stty -g <&"$INPUT_FD") || return 1
    stty -echo -icanon min 1 time 0 susp undef <&"$INPUT_FD" || return 1
    trap on_tstp TSTP
    tui_cursor on
    if [[ $mode == secret ]]; then printf '  %s' "$prompt" >&4
    else input_prompt "$1" prompt; draw_input_line "$prompt" "$left" "$right"; fi
    while :; do
        tui_read_key key edit
        case $key in
            ENTER) break ;;
            ESC) rc=1; break ;;
            q|Q) if [[ $mode == numeric ]]; then rc=1; break; fi; left+=$key ;;
            LEFT|$'\x02') right=${left: -1}$right; left=${left%?} ;;
            RIGHT|$'\x06') left+=${right:0:1}; right=${right:1} ;;
            HOME|$'\x01') right=$left$right; left='' ;;
            END|$'\x05') left+=$right; right='' ;;
            BACKSPACE) left=${left%?} ;;
            DELETE) right=${right:1} ;;
            $'\x15') left='' ;;
            $'\x0b') right='' ;;
            RESIZE)
                ui_measure
                if [[ $mode != secret ]]; then
                    printf '\r\e[2K' >&4
                    input_prompt "$1" prompt
                fi
                stty -echo -icanon min 1 time 0 susp undef <&"$INPUT_FD"
                tui_cursor on ;;
            *) [[ ${#key} != 1 || $key == [[:cntrl:]] ]] || left+=$key ;;
        esac
        # Redraw once at the end of a paste. Never paint private key material.
        if [[ $mode != secret ]] && ! IFS= read -r -t 0 -u "$INPUT_FD"; then
            draw_input_line "$prompt" "$left" "$right"
        fi
    done
    trap - TSTP
    tty_echo "$saved"
    printf '\n' >&4
    if (( rc )); then INPUT_DIRTY=1; return 1; fi
    printf -v "$2" '%s' "$left$right"
}

read_line() {
    local __rl_p=$1 __rl_v='' __rl_pre=${3:-} __rl_mode=${4:-text}
    local __rl_part __rl_rc __rl_tty=''
    local -a __rl_options=(-r -u "$INPUT_FD")
    (( ! ${#INPUT_SUPERVISORS[@]} )) || __rl_options+=(-t 1)
    [[ $__rl_mode != secret ]] || __rl_options+=(-s)
    ui_flush
    while :; do
        printf -v "$2" '%s' ''
        if input_is_tty && ui_ansi_tty && (( UI_UTF8 )); then
            tty_edit_line "$__rl_p" __rl_v "$__rl_pre" "$__rl_mode" || return 1
        else
            if [[ -n $__rl_pre && $__rl_mode != secret ]]; then
                ui_note "回车保留当前值 $__rl_pre"
            fi
            printf '  %s' "$__rl_p" >&4
            if [[ $__rl_mode == secret ]]; then
                if input_is_tty; then
                    __rl_tty=$(stty -g <&"$INPUT_FD") || return 1
                    stty -echo <&"$INPUT_FD" || return 1
                fi
            else
                tty_echo echo
            fi
            __rl_v=''
            while :; do
                check_input_session
                __rl_part='' __rl_rc=0
                IFS= read "${__rl_options[@]}" __rl_part || __rl_rc=$?
                __rl_v+=$__rl_part
                (( __rl_rc > 128 )) || break
            done
            [[ -z $__rl_tty ]] || tty_echo "$__rl_tty"
            (( __rl_rc == 0 )) || input_eof
            check_input_session
            if [[ $__rl_mode == secret ]]; then printf '\n' >&4
            elif [[ -z $__rl_v ]]; then __rl_v=$__rl_pre; fi
        fi
        __rl_v=${__rl_v#"${__rl_v%%[![:space:]]*}"}
        __rl_v=${__rl_v%"${__rl_v##*[![:space:]]}"}
        if [[ $__rl_mode == literal ]]; then
            case $__rl_v in /cancel|$'\e') return 1 ;; esac
        else
            case $__rl_v in q|Q|$'\e') return 1 ;; esac
            # Declining to leave means retry this prompt, never synthesize Enter.
            go_home_if_b "$__rl_v" || continue
        fi
        printf -v "$2" '%s' "$__rl_v"
        return 0
    done
}

read_secret_line() { read_line "$1" "$2" '' secret; }

tui_read_key() {
    local __k='' __c='' __seq='' __rc __tty_state=''
    # The line editor and menus already own the terminal mode while reading.
    if [[ ${2:-} != edit ]]; then
        if [[ ${2:-} != menu ]] && input_is_tty; then __tty_state=$(stty -g <&"$INPUT_FD" 2>/dev/null || true); fi
        trap on_tstp TSTP
        [[ -z $__tty_state ]] || stty susp undef <&"$INPUT_FD" 2>/dev/null || true
    fi
    while :; do
        check_input_session
        if (( TUI_RESIZED )); then TUI_RESIZED=0; __k=RESIZE; break; fi
        __rc=0
        IFS= read -rsn1 -t 1 -u "$INPUT_FD" __k || __rc=$?
        check_input_session
        if (( __rc > 128 )); then
            if (( ! TUI_RESIZED )) && [[ ${2:-} == timed ]]; then __k=TICK; break; fi
            continue
        fi
        (( __rc == 0 )) || { [[ -z $__tty_state ]] || tty_echo "$__tty_state"; input_eof; }
        break
    done
    [[ -z $__tty_state ]] || tty_echo "$__tty_state"
    case $__k in
        $'\x1a') on_tstp; [[ -z $__tty_state ]] || tty_echo "$__tty_state"; TUI_RESIZED=0; __k=RESIZE ;;
        $'\e')
            __rc=0
            IFS= read -rsn1 -t 0.1 -u "$INPUT_FD" __c || __rc=$?
            if [[ $__c == '[' || $__c == O ]]; then
                while IFS= read -rsn1 -t 0.05 -u "$INPUT_FD" __c; do
                    __seq+=$__c
                    (( ${#__seq} < 16 )) || break
                    [[ $__c != [A-Za-z~] ]] || break
                done
                case $__seq in
                    A) __k=UP ;; B) __k=DOWN ;; C) __k=RIGHT ;; D) __k=LEFT ;;
                    H|1~|7~) __k=HOME ;; F|4~|8~) __k=END ;; 5~) __k=PGUP ;; 6~) __k=PGDN ;; 3~) __k=DELETE ;;
                    *) __k=NONE ;;
                esac
            else
                __k=ESC
            fi ;;
        ''|$'\r'|$'\n') __k=ENTER ;;
        $'\x04') input_eof ;;
        $'\t') __k=TAB ;;
        $'\x7f'|$'\b') if [[ ${2:-} == edit ]]; then __k=BACKSPACE; else __k=ESC; fi ;;
    esac
    [[ ${2:-} == edit ]] || trap - TSTP
    printf -v "$1" '%s' "$__k"
}

tui_hl() {
    local __h_s __h_w
    strip_ansi "$1" __h_s
    [[ ${__h_s:0:2} != '  ' ]] || __h_s=" >${__h_s:2}"
    str_width "$__h_s" __h_w
    (( __h_w >= UI_W )) || printf -v __h_s '%s%*s' "$__h_s" $(( UI_W - __h_w )) ''
    printf -v "$2" '\e[7m%s\e[0m' "$__h_s"
}

tui_item() {
    TUI_ITEMS+=("${#UI_BUF[@]}")
    TUI_IKEYS+=("$1")
    TUI_HELPS+=("${5:-}")
    ui_item "$1" "$2" "${3:-}" "${4:-}"
    if (( UI_BUF_ON )); then menu_item_end+=("$(( ${#UI_BUF[@]} - 1 ))")
    elif [[ -n ${5:-} && -z ${3:-}${4:-} ]]; then ui_note "$5"; fi
}

tui_opt() {
    TUI_ITEMS+=("${#UI_BUF[@]}")
    TUI_IKEYS+=("$1")
    TUI_HELPS+=("${6:-}")
    ui_option "$1" "$2" "$3" "$4" "$5"
    if (( UI_BUF_ON )); then menu_item_end+=("$(( ${#UI_BUF[@]} - 1 ))")
    elif [[ -n ${6:-} && -z $3 ]]; then ui_note "$6"; fi
}

tui_build() {
    local __tb_fn=$1 __tb_i __tb_w __tb_n __tb_item=0 __tb_space __tb_line __tb_status
    shift
    UI_BUF=() TUI_ITEMS=() TUI_IKEYS=() TUI_HELPS=() TUI_FOOT='' TUI_FOOT_PLAIN='' TUI_HELP_H=0 KEY_W=1 TUI_HEAD=0
    menu_item_end=()
    UI_BUF_ON=1
    "$__tb_fn" "$@"
    __tb_status=$?
    UI_BUF_ON=0
    (( __tb_status == 0 )) || return "$__tb_status"
    for __tb_i in "${!UI_BUF[@]}"; do
        str_width "${UI_BUF[$__tb_i]}" __tb_n
        (( __tb_n <= UI_W )) || { fit_width "${UI_BUF[$__tb_i]}" "$UI_W" __tb_w; UI_BUF[__tb_i]=$__tb_w; }
    done
    footer_lines "${TUI_FOOT:-上下键 移动   回车 选择   Esc 返回}" menu_footer
    menu_notice=()
    if [[ -n $TUI_MSG ]]; then
        wrap_text "$TUI_MSG" "$(( UI_W - 2 ))" __tb_w
        mapfile -t menu_notice <<< "$__tb_w"
    fi
    # Keep at least three body rows, a footer rule and one spare cursor row.
    __tb_space=$(( UI_H - ${#menu_footer[@]} - 5 ))
    if (( ${#menu_notice[@]} > __tb_space )); then
        UI_BUF+=('')
        for __tb_line in "${menu_notice[@]}"; do UI_BUF+=("  $C_YELLOW$__tb_line$C_RESET"); done
        menu_notice=('PgDn 查看完整提示')
    fi
    (( TUI_HELP_H > 0 )) || return 0
    TUI_HELP_H=0
    for __tb_i in "${!TUI_HELPS[@]}"; do
        wrap_text "${TUI_HELPS[$__tb_i]}" $(( UI_W - 2 )) __tb_w
        TUI_HELPS[__tb_i]=$__tb_w
        [[ -n $__tb_w ]] || continue
        __tb_n=1
        while [[ $__tb_w == *$'\n'* ]]; do __tb_w=${__tb_w#*$'\n'}; __tb_n=$(( __tb_n + 1 )); done
        (( __tb_n <= TUI_HELP_H )) || TUI_HELP_H=$__tb_n
    done
    __tb_space=$(( __tb_space - ${#menu_notice[@]} ))
    if (( TUI_HEAD <= __tb_space )); then __tb_space=$(( __tb_space - TUI_HEAD )); fi
    if (( TUI_HELP_H && TUI_HELP_H + 1 > __tb_space )); then
        # Short windows keep the complete help with its option in the scrollable body.
        local -a __tb_old=("${UI_BUF[@]}") __tb_starts=("${TUI_ITEMS[@]}")
        UI_BUF=() TUI_HELP_H=0
        for __tb_i in "${!__tb_old[@]}"; do
            UI_BUF+=("${__tb_old[__tb_i]}")
            if [[ ${__tb_starts[__tb_item]:-} == "$__tb_i" ]]; then TUI_ITEMS[__tb_item]=$(( ${#UI_BUF[@]} - 1 )); fi
            [[ ${menu_item_end[__tb_item]:-} == "$__tb_i" ]] || continue
            if [[ -n ${TUI_HELPS[__tb_item]} ]]; then
                while IFS= read -r __tb_line; do UI_BUF+=("  $C_DIM$__tb_line$C_RESET"); done <<< "${TUI_HELPS[__tb_item]}"
            fi
            menu_item_end[__tb_item]=$(( ${#UI_BUF[@]} - 1 ))
            __tb_item=$(( __tb_item + 1 ))
        done
    fi
}

wrap_text() {
    local __wt_in=$1 __wt_max=$2 __wt_out='' __wt_line __wt_w __wt_cur __wt_acc __wt_i __wt_ch __wt_hold __wt_hw __wt_lines_out=0
    if (( ! UI_UTF8 )); then printf -v "$3" '%s' "$__wt_in"; return 0; fi
    local -a __wt_lines=()
    mapfile -t __wt_lines <<< "$__wt_in"
    for __wt_line in "${__wt_lines[@]}"; do
        str_width "$__wt_line" __wt_w
        if (( __wt_w <= __wt_max )); then
            (( ! __wt_lines_out )) || __wt_out+=$'\n'
            __wt_out+=$__wt_line; __wt_lines_out=$(( __wt_lines_out + 1 )); continue
        fi
        # Do not split a colour escape between display lines.
        strip_ansi "$__wt_line" __wt_line
        # Plain ASCII records can be divided a row at a time using byte offsets.
        # Keep the same word-boundary and trailing-space rules as the Unicode path.
        if (( __wt_max > 0 )) && [[ $__wt_line != *[!$'\x20'-$'\x7e']* ]]; then
            local __wt_pos=0 __wt_take __wt_len=${#__wt_line}
            while (( __wt_len - __wt_pos > __wt_max )); do
                __wt_take=$__wt_max
                __wt_cur=${__wt_line:__wt_pos:__wt_take}
                __wt_ch=${__wt_line:__wt_pos+__wt_take:1}
                if [[ $__wt_ch == [A-Za-z0-9._/:-] && $__wt_cur =~ [A-Za-z0-9._/:-]+$ ]] &&
                    (( ${#BASH_REMATCH[0]} < __wt_take )); then
                    __wt_take=$(( __wt_take - ${#BASH_REMATCH[0]} ))
                    __wt_cur=${__wt_cur:0:__wt_take}
                fi
                (( ! __wt_lines_out )) || __wt_out+=$'\n'
                __wt_out+=${__wt_cur%' '}; __wt_lines_out=$(( __wt_lines_out + 1 ))
                __wt_pos=$(( __wt_pos + __wt_take ))
                [[ $__wt_ch != ' ' ]] || __wt_pos=$(( __wt_pos + 1 ))
            done
            (( ! __wt_lines_out )) || __wt_out+=$'\n'
            __wt_out+=${__wt_line:__wt_pos}; __wt_lines_out=$(( __wt_lines_out + 1 ))
            continue
        fi
        __wt_cur='' __wt_acc=0
        local -a __wt_units=()
        ui_split_units "$__wt_line" __wt_units
        for (( __wt_i = 0; __wt_i < ${#__wt_units[@]}; __wt_i++ )); do
            __wt_ch=${__wt_units[$__wt_i]}
            str_width "$__wt_ch" __wt_w
            if (( __wt_acc + __wt_w > __wt_max )); then
                __wt_hold=''
                if [[ $__wt_ch == [A-Za-z0-9._/:-] || $__wt_ch == [，。；：、）！？」] ]]; then
                    if [[ $__wt_cur =~ [A-Za-z0-9._/:-]+$ ]]; then __wt_hold=${BASH_REMATCH[0]}
                    elif [[ $__wt_ch != [A-Za-z0-9._/:-] && $__wt_i -gt 0 ]]; then __wt_hold=${__wt_units[$(( __wt_i - 1 ))]}; fi
                    str_width "$__wt_hold" __wt_hw
                    (( ${#__wt_hold} < ${#__wt_cur} && __wt_hw + __wt_w <= __wt_max )) || __wt_hold=''
                    __wt_cur=${__wt_cur:0:${#__wt_cur}-${#__wt_hold}}
                fi
                (( ! __wt_lines_out )) || __wt_out+=$'\n'
                __wt_out+=${__wt_cur%' '}; __wt_lines_out=$(( __wt_lines_out + 1 ))
                __wt_cur=$__wt_hold
                str_width "$__wt_hold" __wt_acc
                [[ $__wt_ch != ' ' ]] || continue
            fi
            __wt_cur+=$__wt_ch
            __wt_acc=$(( __wt_acc + __wt_w ))
        done
        (( ! __wt_lines_out )) || __wt_out+=$'\n'
        __wt_out+=$__wt_cur; __wt_lines_out=$(( __wt_lines_out + 1 ))
    done
    printf -v "$3" '%s' "$__wt_out"
}

tui_draw() {
    local i line sel=-1 se n avail top end rl rt h hd=$TUI_HEAD scroll=0 ind out='' mv help_h=$TUI_HELP_H
    local -a help=() F=()
    n=${#UI_BUF[@]}
    (( ${#TUI_ITEMS[@]} == 0 )) || sel=${TUI_ITEMS[$TUI_CUR]}
    avail=$(( UI_H - 2 - ${#menu_footer[@]} - ${#menu_notice[@]} ))
    if (( help_h > 0 )); then avail=$(( avail - help_h - 1 )); fi
    (( hd + 3 <= avail )) || hd=0
    for (( i = 0; i < hd; i++ )); do F+=("${UI_BUF[$i]}"); done
    avail=$(( avail - hd ))
    (( avail >= 3 )) || avail=3
    top=$hd
    if (( n - hd > avail )); then
        scroll=1
        avail=$(( avail - 1 ))
        se=$sel
        if (( sel >= 0 )); then
            se=${menu_item_end[TUI_CUR]:-$sel}
        fi
        (( se - sel < avail )) || se=$(( sel + avail - 1 ))
        top=$TUI_TOP
        (( top >= hd )) || top=$hd
        if (( ! ${page_browse:-0} )); then
            (( TUI_CUR > 0 || ${#TUI_ITEMS[@]} == 0 )) || top=$hd
            (( sel < 0 || sel >= top )) || top=$sel
            (( se < top + avail )) || top=$(( se - avail + 1 ))
        fi
        (( top + avail <= n )) || top=$(( n - avail ))
        (( top >= hd )) || top=$hd
    fi
    TUI_TOP=$top
    end=$(( top + avail ))
    (( end <= n )) || end=$n
    page_rows=$avail
    selected_visible=$(( sel >= 0 && (sel < hd || (sel >= top && sel < end)) ))
    for (( i = top; i < end; i++ )); do
        line=${UI_BUF[$i]}
        (( i != sel )) || tui_hl "$line" line
        F+=("$line")
    done
    if (( scroll )); then
        if (( top > hd && end < n )); then ind='PgUp/PgDn 翻页'
        elif (( end < n )); then ind='PgDn 下一页'
        else ind='PgUp 上一页'; fi
        if (( ${page_browse:-0} && ! selected_visible && ! help_h )); then ind+='   回车定位选项'; fi
        F+=("  $C_DIM$ind$C_RESET")
    fi
    rule_line rl
    rule_line rt '='
    if (( help_h > 0 )); then
        F+=("$rl")
        if (( ${page_browse:-0} && ! selected_visible )); then help=('回车定位当前选项')
        else mapfile -t help <<< "${TUI_HELPS[$TUI_CUR]:-}"; fi
        for (( h = 0; h < help_h; h++ )); do
            line=${help[$h]:-}
            F+=("  $C_DIM$line$C_RESET")
        done
    fi
    for line in "${menu_notice[@]}"; do F+=("  $C_YELLOW$line$C_RESET"); done
    F+=("$rt" "${menu_footer[@]}")
    # Address each row explicitly, including the first frame and a resize.
    # SSH terminals can keep OPOST enabled with ONLCR disabled.
    for i in "${!F[@]}"; do
        if (( TUI_PREV_OK && i < ${#TUI_PREV[@]} )) && [[ ${F[$i]} == "${TUI_PREV[$i]}" ]]; then continue; fi
        printf -v mv '\e[%d;1H\e[2K' $(( i + 1 ))
        out+=$mv${F[$i]}
    done
    printf -v mv '\e[%d;1H' $(( ${#F[@]} + 1 ))
    out+=$mv
    if (( ! TUI_PREV_OK || ${#F[@]} < ${#TUI_PREV[@]} )); then out+=$'\e[J'; fi
    TUI_PREV=("${F[@]}")
    TUI_PREV_OK=1
    printf '%s' "$out" >&4
}

tui_jump() {
    local __j_k=$1 __j_i
    for __j_i in "${!TUI_IKEYS[@]}"; do
        [[ ${TUI_IKEYS[$__j_i],,} == "${__j_k,,}" ]] || continue
        TUI_CUR=$__j_i
        return 0
    done
    return 1
}

tui_menu() {
    local __tm_fn=$1 __tm_keys=${3:-} __tm_k __tm_n __tm_dg='' __tm_dt=0 __tm_now __tm_tty_state='' __tm_read_mode=''
    local __tm_build=1 __tm_status=0
    local page_browse=${TUI_REVIEW_FIRST:-0} page_rows=1 selected_visible=0
    local -a menu_footer=() menu_notice=() menu_item_end=()
    TUI_CUR=${2:-0}
    shift $(( $# < 3 ? $# : 3 ))
    TUI_KEY=''
    if (( ! TUI )); then
        if ui_menu_tty; then
            ui_measure
            if (( UI_W >= 40 && UI_H >= 12 )); then TUI=1; fi
        fi
        if (( ! TUI )); then tui_plain "$__tm_fn" "$__tm_keys" "$@"; return; fi
    fi
    __tm_tty_state=$(stty -g <&"$INPUT_FD" 2>/dev/null || true)
    if [[ -n $__tm_tty_state ]] && stty susp undef <&"$INPUT_FD" 2>/dev/null; then __tm_read_mode=menu; fi
    ui_measure
    if (( UI_W < 40 || UI_H < 12 )); then
        [[ -z $__tm_tty_state ]] || tty_echo "$__tm_tty_state"
        tui_cursor on
        TUI=0
        ui_clear
        tui_plain "$__tm_fn" "$__tm_keys" "$@"
        return
    fi
    TUI_RESIZED=0
    (( ! INPUT_DIRTY )) || ui_flush
    TUI_TOP=0
    tty_echo -echo
    tui_cursor off
    while :; do
        if (( __tm_build )); then
            # A confirmation caller can test this menu in a conditional, where
            # Bash suppresses errexit. Do not draw or dispatch a partial menu.
            tui_build "$__tm_fn" "$@"
            __tm_status=$?
            (( __tm_status == 0 )) || break
            __tm_n=${#TUI_ITEMS[@]}
            (( TUI_CUR >= 0 && TUI_CUR < __tm_n )) || TUI_CUR=0
            __tm_build=0 TUI_PREV_OK=0
        fi
        tui_draw
        tui_read_key __tm_k "$__tm_read_mode"
        [[ $__tm_k == [0-9] ]] || __tm_dg=''
        if (( page_browse && ! selected_visible )) &&
            [[ $__tm_k == ENTER || ( $__tm_k == c && $__tm_keys == *c* ) ]]; then
            page_browse=0
            continue
        fi
        case $__tm_k in UP|DOWN|TAB|HOME|END) page_browse=0 ;; esac
        case $__tm_k in
            RESIZE)
                ui_measure
                if (( UI_W < 40 || UI_H < 12 )); then
                    [[ -z $__tm_tty_state ]] || tty_echo "$__tm_tty_state"
                    tui_cursor on
                    TUI=0
                    ui_clear
                    tui_plain "$__tm_fn" "$__tm_keys" "$@"
                    return
                fi
                # A suspended job restores the login tty before it stops.
                if [[ $__tm_read_mode == menu ]]; then stty susp undef <&"$INPUT_FD" 2>/dev/null || __tm_read_mode=''; fi
                __tm_build=1 ;;
            UP) (( __tm_n == 0 )) || TUI_CUR=$(( (TUI_CUR + __tm_n - 1) % __tm_n )) ;;
            DOWN|TAB) (( __tm_n == 0 )) || TUI_CUR=$(( (TUI_CUR + 1) % __tm_n )) ;;
            HOME) TUI_CUR=0 ;;
            END) (( __tm_n == 0 )) || TUI_CUR=$(( __tm_n - 1 )) ;;
            PGUP) page_browse=1; TUI_TOP=$(( TUI_TOP - page_rows )) ;;
            PGDN) page_browse=1; TUI_TOP=$(( TUI_TOP + page_rows )) ;;
            ENTER) (( __tm_n == 0 )) || { TUI_KEY=ENTER; break; } ;;
            ESC|q|Q)
                if [[ $__tm_keys == *q* ]]; then TUI_KEY=q; else TUI_KEY=ESC; fi
                break ;;
            LEFT) TUI_KEY=ESC; break ;;
            b|B)
                if [[ -n $ACTION_PID ]]; then
                    go_home_if_b b || true
                    tty_echo -echo
                    tui_cursor off
                    TUI_PREV_OK=0
                fi ;;
            *)
                if [[ ${#__tm_k} == 1 && -n $__tm_keys && $__tm_keys == *"$__tm_k"* ]]; then TUI_KEY=$__tm_k; break; fi
                if [[ $__tm_k == [0-9] ]]; then
                    __tm_now=$(now_ms) || __tm_now=$(( (SECONDS % 100000) * 1000 ))
                    # Modular delta remains correct when the 100000-second counter wraps.
                    if [[ -n $__tm_dg ]] && (( (__tm_now - __tm_dt + 100000000) % 100000000 < 1000 )) \
                        && tui_jump "$__tm_dg$__tm_k"; then
                        __tm_dg+=$__tm_k; page_browse=0
                    else
                        if tui_jump "$__tm_k"; then page_browse=0; fi
                        __tm_dg=$__tm_k
                    fi
                    __tm_dt=$__tm_now
                elif [[ ${#__tm_k} == 1 ]] && tui_jump "$__tm_k"; then
                    page_browse=0
                fi ;;
        esac
    done
    [[ -z $__tm_tty_state ]] || tty_echo "$__tm_tty_state"
    if (( __tm_status )); then
        tui_cursor on
        TUI_KEY='' TUI_MSG='菜单读取失败，请重试。'
        return "$__tm_status"
    fi
    TUI_MSG=''
    return 0
}

tui_plain() {
    local __tp_fn=$1 __tp_keys=$2 __tp_k __tp_hint __tp_action __tp_exit __tp_status
    shift 2
    UI_BUF_ON=0 TUI_ITEMS=() TUI_IKEYS=() TUI_HELPS=() TUI_FOOT='' TUI_FOOT_PLAIN='' TUI_HELP_H=0 KEY_W=1
    "$__tp_fn" "$@"
    __tp_status=$?
    if (( __tp_status )); then TUI_KEY='' TUI_MSG='菜单读取失败，请重试。'; return "$__tp_status"; fi
    # Render notices after the builder clears the screen, including resize fallback.
    if [[ -n $TUI_MSG ]]; then ui_colored "$C_YELLOW" 4 "$TUI_MSG"; TUI_MSG=''; fi
    __tp_hint=${TUI_FOOT_PLAIN:-"输入选项键，回车确认"}
    __tp_action=${TUI_FOOT##* }
    case $__tp_hint in
        *"   0 $__tp_action") __tp_hint=${__tp_hint%"   0 $__tp_action"}; __tp_exit=0/q/Esc ;;
        *"   回车 $__tp_action") __tp_hint=${__tp_hint%"   回车 $__tp_action"}; __tp_exit=回车/q/Esc ;;
        *) __tp_exit=回车/q/Esc ;;
    esac
    ui_footer "$__tp_hint   $__tp_exit $__tp_action"
    while :; do
        if ! read_line '请选择：' __tp_k '' numeric; then
            if [[ $__tp_keys == *q* ]]; then TUI_KEY=q; else TUI_KEY=ESC; fi
            return 0
        fi
        if [[ -z $__tp_k ]]; then TUI_KEY=ESC; return 0; fi
        if tui_jump "$__tp_k"; then TUI_KEY=ENTER; return 0; fi
        if [[ ${#__tp_k} == 1 && -n $__tp_keys && $__tp_keys == *"$__tp_k"* ]]; then TUI_KEY=$__tp_k; return 0; fi
        if [[ $__tp_k == 0 ]]; then TUI_KEY=ESC; return 0; fi
        ui_warn '没有这个选项，请重新输入。'
    done
}

key_range() {
    local n=$1 k lo='' hi=''
    for k in "${TUI_IKEYS[@]}"; do
        [[ $k =~ ^[0-9]+$ ]] || continue
        if [[ -z $lo ]] || (( k < lo )); then lo=$k; fi
        if [[ -z $hi ]] || (( k > hi )); then hi=$k; fi
    done
    if [[ -z $lo ]]; then lo=1 hi=$n; fi
    if [[ $lo == "$hi" ]]; then printf '%s' "$lo"; else printf '%s-%s' "$lo" "$hi"; fi
}

tui_confirm() {
    local p=$1 sel=$2 k yes no line wrapped saved_tty='' redraw=1
    local hint='方向键或 y/n 选择，回车确认，q/Esc 取消'
    if input_is_tty; then saved_tty=$(stty -g <&"$INPUT_FD" 2>/dev/null || true); fi
    ui_flush
    if [[ $ACTION == menu && -n $ACTION_PID && ${confirming_discard:-0} == 0 ]]; then hint+='，b 主页'; fi
    while :; do
        if (( redraw )); then
            tty_echo -echo
            tui_cursor off
            wrap_text "$p" "$(( UI_W - 2 ))" wrapped
            while IFS= read -r line; do printf '\r\e[2K  %s\n' "$line" >&4; done <<< "$wrapped"
            wrap_text "$hint" "$(( UI_W - 2 ))" wrapped
            while IFS= read -r line; do printf '\r\e[2K  %s%s%s\n' "$C_DIM" "$line" "$C_RESET" >&4; done <<< "$wrapped"
            redraw=0
        fi
        if (( sel )); then yes=$'\e[7m 是 \e[0m' no=' 否 '; else yes=' 是 ' no=$'\e[7m 否 \e[0m'; fi
        printf '\r\e[2K  %s  %s' "$yes" "$no" >&4
        tui_read_key k
        case $k in
            LEFT|RIGHT|UP|DOWN|TAB) sel=$(( 1 - sel )) ;;
            y|Y) sel=1 ;;
            n|N) sel=0 ;;
            ENTER) break ;;
            b|B)
                if [[ $ACTION == menu && -n $ACTION_PID && ${confirming_discard:-0} == 0 ]]; then
                    printf '\n' >&4
                    go_home_if_b b || redraw=1
                fi ;;
            RESIZE) printf '\n' >&4; ui_measure; redraw=1 ;;
            ESC|q|Q) sel=0; break ;;
        esac
    done
    printf '\n' >&4
    tty_echo "${saved_tty:-echo}"
    tui_cursor on
    (( sel ))
}

ask_yes() {
    local a
    (( ASSUME_YES )) && return 0
    if (( TUI && UI_W >= 40 && UI_H >= 12 )); then tui_confirm "$1" 1; return; fi
    ui_line "$1"
    ui_note '回车选「是」，q/Esc 取消。'
    while :; do
        read_line '[Y/n]：' a '' numeric || return 1
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
    if (( TUI && UI_W >= 40 && UI_H >= 12 )); then tui_confirm "$1" 0; return; fi
    ui_line "$1"
    ui_note '回车选「否」，q/Esc 取消。'
    while :; do
        read_line '[y/N]：' a '' numeric || return 1
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
        read_line "$__an_pr（回车保留 ${__an_def:-默认值}，q/Esc 取消）：" __an_n '' numeric || return 1
        [[ -n $__an_n ]] || __an_n=$__an_def
        if [[ $__an_n =~ ^[0-9]{1,9}$ ]] && (( 10#$__an_n >= __an_min && 10#$__an_n <= __an_max )); then
            printf -v "$5" '%d' $(( 10#$__an_n ))
            return 0
        fi
        ui_warn "请输入 $__an_min-$__an_max 之间的整数。"
    done
}

OP_TITLE='' OP_SUB='' OP_HINT='' OP_CUR=0
OP_OPTS=()

op_build() {
    local i opt w lw=8 desc max_label
    KEY_W=${#OP_OPTS[@]}; KEY_W=${#KEY_W}
    for opt in "${OP_OPTS[@]}"; do
        str_width "${opt%%|*}" w
        (( w + 2 <= lw )) || lw=$(( w + 2 ))
    done
    (( lw >= 12 )) || lw=12
    max_label=$(( (UI_W - 5 - KEY_W - 6) / 2 ))
    (( max_label >= 4 )) || max_label=4
    (( lw <= max_label )) || lw=$max_label
    ui_page "$OP_TITLE" "$OP_SUB"
    KEY_W=${#OP_OPTS[@]}; KEY_W=${#KEY_W}
    if [[ -n $OP_HINT ]]; then ui_hint "$OP_HINT"; ui_blank; fi
    for i in "${!OP_OPTS[@]}"; do
        opt=${OP_OPTS[$i]}
        [[ $opt == *'|'* ]] || opt+='|'
        desc=${opt#*|}
        tui_opt "$(( i + 1 ))" "${opt%%|*}" "$desc" $(( i + 1 == OP_CUR )) "$lw"
    done
    if (( OP_CUR > 0 )); then
        TUI_FOOT='上下键 移动   回车 选择   Esc 不改'
        TUI_FOOT_PLAIN="$(key_range ${#OP_OPTS[@]}) 选择   回车 不改"
    else
        TUI_FOOT='上下键 移动   回车 选择   Esc 返回'
    fi
}

option_page() {
    local __op_var=$1
    OP_CUR=$2 OP_TITLE=$3 OP_HINT=$4 OP_SUB=''
    shift 4
    OP_OPTS=("$@")
    tui_menu op_build $(( OP_CUR > 0 ? OP_CUR - 1 : 0 )) ''
    if [[ $TUI_KEY == ENTER ]]; then printf -v "$__op_var" '%d' $(( TUI_CUR + 1 ))
    else printf -v "$__op_var" '%s' ''; fi
}

in_list() {
    local x n=$1
    shift
    for x in "$@"; do [[ $x != "$n" ]] || return 0; done
    return 1
}

join_by() {
    local sep=$1 out='' x
    shift
    for x in "$@"; do out+=${out:+$sep}$x; done
    printf '%s' "$out"
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
    local k saved_tty=''
    if (( TUI )); then
        if input_is_tty; then saved_tty=$(stty -g <&"$INPUT_FD" 2>/dev/null || true); fi
        ui_flush
        tty_echo -echo
        tui_cursor off
        while :; do
            printf '\r\e[2K  %s回车或 q/Esc 返回%s' "$C_DIM" "$C_RESET" >&4
            tui_read_key k
            case $k in ENTER|ESC|q|Q) break ;; b|B) go_home_if_b b || true ;; esac
        done
        printf '\n' >&4
        tty_echo "${saved_tty:-echo}"
        tui_cursor on
        return 0
    fi
    read_line '回车或 q/Esc 返回：' k '' numeric || return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

ver_ge() {
    local a=${1#v} b=${2#v} LC_ALL=C
    local numeric='^[0-9]+([.][0-9]+)*$'
    local section left right i x y
    local -a av bv
    a=${a%%+*} b=${b%%+*}
    left=${a%%-*} right=${b%%-*}
    [[ $left =~ $numeric && $right =~ $numeric ]] || return 1
    for section in core prerelease; do
        if [[ $section == prerelease ]]; then
            # At equal core versions a release outranks every prerelease.
            [[ $a == *-* ]] || return 0
            [[ $b == *-* ]] || return 1
            left=${a#*-} right=${b#*-}
        fi
        IFS=. read -r -a av <<< "$left"
        IFS=. read -r -a bv <<< "$right"
        for ((i=0; i<${#av[@]} && i<${#bv[@]}; i++)); do
            x=${av[i]} y=${bv[i]}
            [[ $x != "$y" ]] || continue
            if [[ $x != *[!0-9]* ]]; then
                [[ $y != *[!0-9]* ]] || return 1
                x=${x#"${x%%[!0]*}"} y=${y#"${y%%[!0]*}"}
                if (( ${#x} != ${#y} )); then (( ${#x} > ${#y} )); return; fi
            elif [[ $y != *[!0-9]* ]]; then
                return 0
            fi
            if [[ $x != "$y" ]]; then [[ $x > $y ]]; return; fi
        done
        if (( ${#av[@]} != ${#bv[@]} )); then (( ${#av[@]} > ${#bv[@]} )); return; fi
    done
    return 0
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

random_path() {
    local h
    h=$(rand_hex 6) || return 1
    printf '/%s/' "$h"
}

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
        [[ ${#o} == 1 || $o != 0* ]] || return 1
        (( 10#$o <= 255 )) || return 1
    done
}

valid_ipv6_hextets() {
    local a=$1 part count=0
    [[ $a == *:* && $a != *[!0-9a-fA-F:]* && ${#a} -le 39 && $a != *:::* ]] || return 1
    if [[ $a == *::* ]]; then
        # Exactly one :: and no single stray colon at either boundary.
        [[ $a != :* || $a == ::* ]] || return 1
        [[ $a != *: || $a == *:: ]] || return 1
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

valid_short_id() {
    local LC_ALL=C
    [[ $1 =~ ^([0-9A-Fa-f]{2}){1,8}$ ]]
}

# Compare addresses numerically, including compressed and IPv4-mapped IPv6.
ip_key() {
    local a=${1,,} part left right missing i
    local -a words=() lhs=() rhs=() octets=()
    if valid_ipv4 "$a"; then
        IFS=. read -r -a octets <<< "$a"
        printf 'v4:%d.%d.%d.%d' "$((10#${octets[0]}))" "$((10#${octets[1]}))" "$((10#${octets[2]}))" "$((10#${octets[3]}))"
        return 0
    fi
    if [[ $a == *.* ]]; then
        part=${a##*:}
        valid_ipv4 "$part" || return 1
        IFS=. read -r -a octets <<< "$part"
        printf -v part '%x:%x' "$((10#${octets[0]} * 256 + 10#${octets[1]}))" "$((10#${octets[2]} * 256 + 10#${octets[3]}))"
        a=${a%:*}:$part
    fi
    valid_ipv6_hextets "$a" || return 1
    if [[ $a == *::* ]]; then
        left=${a%%::*} right=${a#*::}
        [[ -z $left ]] || IFS=: read -r -a lhs <<< "$left"
        [[ -z $right ]] || IFS=: read -r -a rhs <<< "$right"
        words=("${lhs[@]}")
        missing=$((8 - ${#lhs[@]} - ${#rhs[@]}))
        for ((i=0; i<missing; i++)); do words+=(0); done
        words+=("${rhs[@]}")
    else
        IFS=: read -r -a words <<< "$a"
    fi
    if [[ $((16#${words[0]} + 16#${words[1]} + 16#${words[2]} + 16#${words[3]} + 16#${words[4]})) == 0 && $((16#${words[5]})) == 65535 ]]; then
        printf 'v4:%d.%d.%d.%d' "$((16#${words[6]} / 256))" "$((16#${words[6]} % 256))" "$((16#${words[7]} / 256))" "$((16#${words[7]} % 256))"
    else
        printf 'v6'
        for part in "${words[@]}"; do printf ':%x' "$((16#$part))"; done
    fi
}

# A mapped IPv4 address is a valid host, but cannot supply an IPv6-only link.
valid_ipv6() {
    local key
    [[ $1 == *:* ]] && key=$(ip_key "$1") && [[ $key == v6:* ]]
}

valid_host() { valid_domain "$1" || ip_key "$1" >/dev/null; }

unusable_endpoint_ip() {
    local key
    key=$(ip_key "$1") || return 1
    case $key in
        v4:0.*|v4:127.*|v4:169.254.*|v4:255.255.255.255|v6:0:0:0:0:0:0:0:0|v6:0:0:0:0:0:0:0:1|v6:fe[89ab]?:*|v6:ff[0-9a-f][0-9a-f]:*) return 0 ;;
    esac
    if [[ $key == v4:* ]]; then
        local first=${key#v4:}; first=${first%%.*}
        (( first >= 224 )) && return 0
    fi
    return 1
}

local_ip_keys() {
    local a interfaces saved=''
    have ip || return 1
    interfaces=$(timeout -k 1 3 ip -o addr show 2>/dev/null) || return 1
    if [[ -n $DRAFT && -f $DRAFT ]]; then
        saved=$(jq -r '[.net.v4, .net.v6, .net.host][] | strings | select(length > 0)' "$DRAFT") || return 1
    fi
    # Do not emit a partial inventory when the interface query fails.
    while IFS= read -r a; do
        [[ -n $a ]] || continue
        if ip_key "$a"; then printf '\n'; fi
    done < <(
        printf '%s\n' "$NET_V4" "$NET_V6"
        awk '$3 == "inet" || $3 == "inet6" {sub(/\/.*/, "", $4); print $4}' <<< "$interfaces"
        printf '%s\n' "$saved"
    )
    return 0
}

# These ranges can be legitimate remote landings but not public REALITY decoys.
nonpublic_decoy_ip() {
    case $1 in
        v4:10.*|v4:172.1[6-9].*|v4:172.2[0-9].*|v4:172.3[01].*|v4:192.168.*) return 0 ;;
        v4:100.6[4-9].*|v4:100.[7-9][0-9].*|v4:100.1[01][0-9].*|v4:100.12[0-7].*) return 0 ;;
        v4:192.0.0.9|v4:192.0.0.10) return 1 ;; # Globally reachable anycast.
        v4:192.0.0.*|v4:192.0.2.*|v4:198.1[89].*|v4:198.51.100.*|v4:203.0.113.*) return 0 ;;
        v6:f[cd]??:*|v6:fe[c-f]?:*|v6:2001:db8:*|v6:2001:2:0:*) return 0 ;;
        v6:100:0:0:[01]:*|v6:64:ff9b:1:*) return 0 ;;
        # 3fff::/20 has a second hextet below 0x1000; ip_key strips leading zeroes.
        v6:3fff:?:*|v6:3fff:??:*|v6:3fff:???:*) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_host_ips() {
    local h=$1 strict=${2:-0} rows extra
    if ip_key "$h" >/dev/null; then printf '%s\n' "$h"; return 0; fi
    valid_domain "$h" || return 1
    if [[ $strict == 1 ]]; then
        # Query NSS without AI_ADDRCONFIG, even on single-stack hosts and older glibc.
        if [[ $(LC_ALL=C getent --help 2>/dev/null) == *--no-addrconfig* ]]; then
            rows=$(timeout -k 1 4 getent --no-addrconfig ahosts "$h" 2>/dev/null) || return 1
        else
            rows=$(timeout -k 1 4 perl -MSocket=AF_UNSPEC,SOCK_STREAM,NI_NUMERICHOST,NI_NUMERICSERV,getaddrinfo,getnameinfo -e '
                my ($error, @results) = getaddrinfo($ARGV[0], undef, {family => AF_UNSPEC, socktype => SOCK_STREAM, flags => 0});
                exit 1 if $error || !@results;
                for my $result (@results) {
                    my ($err, $addr) = getnameinfo($result->{addr}, NI_NUMERICHOST | NI_NUMERICSERV);
                    exit 1 if $err;
                    print "$addr\n";
                }' "$h" 2>/dev/null) || return 1
        fi
        [[ -n $rows ]] || return 1
        awk 'NF {print $1}' <<< "$rows" | sort -u
        return
    fi
    rows=$(timeout -k 1 4 getent ahosts "$h" 2>/dev/null) || rows=''
    # ahosts may suppress IPv6 via AI_ADDRCONFIG; hosts also checks AAAA.
    extra=$(timeout -k 1 4 getent hosts "$h" 2>/dev/null) || extra=''
    [[ -n $rows || -n $extra ]] || return 1
    printf '%s\n%s\n' "$rows" "$extra" | awk 'NF {print $1}' | sort -u
}

# Reject self-connections before replacing a working configuration. DNS is
# checked again at apply time; later DNS changes still require operator care.
safe_remote_target() {
    local h=$1 port=$2 strict=${3:-0} family=${4:-} rows a key original_key local_keys checked=0 family_found=0
    rows=$(resolve_host_ips "$h" "$strict") || { PARSE_ERR="无法解析 $h，请检查 DNS"; return 1; }
    [[ -n $rows ]] || { PARSE_ERR="无法解析 $h，请检查 DNS"; return 1; }
    local_keys=$(local_ip_keys) || { PARSE_ERR='无法读取本机地址，已停止目标检查'; return 1; }
    while IFS= read -r a; do
        if ! key=$(ip_key "$a"); then
            [[ $strict != 1 ]] || { PARSE_ERR="无法核实 $h 的全部解析结果"; return 1; }
            continue
        fi
        checked=1
        original_key=$key
        if [[ -n $family && $original_key == v"$family":* ]]; then family_found=1; fi
        if [[ $strict == 1 && $key == v6:64:ff9b:0:0:0:0:* ]]; then
            # RFC 6052 embeds the IPv4 destination in the final two hextets.
            a=::ffff:${key#v6:64:ff9b:0:0:0:0:}
            key=$(ip_key "$a") || { PARSE_ERR="无法核实 $h 的 NAT64 地址"; return 1; }
        fi
        if [[ $strict == 1 ]] && nonpublic_decoy_ip "$key"; then
            PARSE_ERR='伪装站点解析到了私有、共享、测试或文档地址，请选择公网 TLS 站点'
            return 1
        fi
        if unusable_endpoint_ip "$a"; then PARSE_ERR='不能使用环回、未指定、链路本地或组播地址'; return 1; fi
        if grep -Fxq -e "$original_key" -e "$key" <<< "$local_keys"; then
            if [[ $strict == 1 ]] || port_in_draft "$port"; then
                PARSE_ERR='目标指向本机，会造成连接回环'; return 1
            elif (( $? != 1 )); then
                PARSE_ERR='无法核实目标端口是否指向本机入口'; return 1
            fi
        fi
    done <<< "$rows"
    (( checked )) || { PARSE_ERR="无法解析 $h，请检查 DNS"; return 1; }
    if [[ -n $family ]] && (( ! family_found )); then
        PARSE_ERR="当前出站仅用 IPv$family，$h 没有可用的 IPv$family 地址"
        return 1
    fi
    return 0
}

valid_text_value() {
    local value=$1 roundtrip
    [[ $value != *[[:cntrl:]]* ]] || return 1
    # jq replaces malformed UTF-8; compare the roundtrip to detect corruption.
    roundtrip=$(printf '%s' "$value" | jq -Rrs '.') || return 1
    [[ $roundtrip == "$value" ]]
}

readonly VLESS_UUID_RE='^[[:xdigit:]]{8}-?[[:xdigit:]]{4}-?[[:xdigit:]]{4}-?[[:xdigit:]]{4}-?[[:xdigit:]]{12}$'
valid_vless_id() {
    local LC_ALL=C value=$1
    valid_text_value "$value" || return 1
    [[ ${#value} -ge 1 && ${#value} -le 30 ]] && return 0
    [[ $value =~ $VLESS_UUID_RE ]]
}

# Compare the UUID bytes used on the wire. Short names use UUIDv5 in the nil namespace.
check_local_uuids() {
    local LC_ALL=C candidate=$1 skip=$2 rows id key digest
    local -A seen=()
    rows=$(jq -r --arg skip "$skip" '.users[] | select((.port // 0) == 0 and .name != $skip) | .id |
        if . == null or . == "" then empty
        elif type == "string" and (test("[[:cntrl:]]") | not) then .
        else error("invalid local identity") end' "$DRAFT") || return 2
    [[ -n $rows ]] || return 0
    while IFS= read -r id; do
        if [[ $id =~ $VLESS_UUID_RE ]]; then
            key=${id//-/}; key=${key,,}
        else
            (( ${#id} >= 1 && ${#id} <= 30 )) || return 2
            digest=$({ printf '\0%.0s' {1..16}; printf '%s' "$id"; } | sha1sum) || return 2
            digest=${digest%% *}
            [[ $digest =~ ^[0-9a-f]{40}$ ]] || return 2
            printf -v key '%s5%s%x%s' "${digest:0:12}" "${digest:13:3}" "$((8 | (16#${digest:16:1} & 3)))" "${digest:17:15}"
        fi
        if [[ -n $candidate ]]; then
            [[ $key != "$candidate" ]] || return 1
        else
            [[ -z ${seen[$key]+x} ]] || return 1
            seen[$key]=1
        fi
    done <<< "$rows"
    return 0
}

# Locally assigned IDs use canonical UUID spelling. Landing links also allow
# Xray's short string IDs, so keep their more permissive parser separate.
write_custom_uuid() {
    local mode=$1 id=${2,,} target=${3:-direct} rc=0
    CREDENTIAL_ERR=''
    if [[ $(scheme) == ss ]]; then CREDENTIAL_ERR='SS2022 使用密码，不使用 UUID。'; return 1; fi
    if [[ ! $id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        CREDENTIAL_ERR='UUID 格式不正确，请按 8-4-4-4-12 输入十六进制字符。'
        return 1
    fi
    case $mode in
        primary) target=direct ;;
        landing) [[ $target != direct && -n $target ]] || { CREDENTIAL_ERR='未选择落地入口。'; return 1; } ;;
        add) ;;
        *) CREDENTIAL_ERR='无法识别 UUID 操作。'; return 1 ;;
    esac
    local skip=''
    [[ $mode == add ]] || skip=$target
    check_local_uuids "${id//-/}" "$skip" || rc=$?
    case $rc in
        0) ;;
        1) CREDENTIAL_ERR='这个 UUID 已被其他入口使用。'; return 1 ;;
        *) CREDENTIAL_ERR='读取草稿中的 UUID 失败。'; return 1 ;;
    esac
    if [[ $mode != add ]]; then
        st_filter --rawfile id <(printf '%s' "$id") --arg t "$target" '
            def matches: .name == $t and (.port // 0) == 0 and (if $t == "direct" then .out == "direct" else .out != "direct" end);
            if ([.users[] | select(matches)] | length) == 1 then (.users[] | select(matches) | .id) = $id
            else error("ambiguous user") end' || { CREDENTIAL_ERR='找不到唯一匹配的入口，请重新选择。'; return 1; }
    else
        st_filter --rawfile id <(printf '%s' "$id") '([.users[].name | select(test("^uuid[0-9]+$")) | ltrimstr("uuid") | tonumber] | (max // 0) + 1) as $n
            | .users += [{name:("uuid" + ($n | tostring)), id:$id, out:"direct"}]'
    fi
}

set_primary_uuid() { write_custom_uuid primary "$1"; }
add_custom_uuid() { write_custom_uuid add "$1"; }

valid_raw_key() {
    local LC_ALL=C key=$1 bytes=$2 canonical
    (( ${#key} == (bytes * 8 + 5) / 6 )) && [[ $key =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    canonical=$(b64_decode_relaxed "$key" 1 | base64 | tr -d '\r\n=' | tr '+/' '-_') || return 1
    [[ $key == "$canonical" ]]
}

keypair_public() {
    local algorithm=$1 private=$2 pubbytes=32
    [[ $algorithm != mlkem768 ]] || pubbytes=1184
    # Wrap the raw private key in PKCS#8 (RFC 8410 / RFC 9935). The raw
    # public key is the final BIT STRING payload of SubjectPublicKeyInfo.
    {
        if [[ $algorithm == mlkem768 ]]; then
            printf '\x30\x54\x02\x01\x00\x30\x0b\x06\x09\x60\x86\x48\x01\x65\x03\x04\x04\x02\x04\x42\x80\x40'
        else
            printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20'
        fi
        b64_decode_relaxed "$private" 1
    } | openssl pkey -inform DER -pubout -outform DER 2>/dev/null |
        tail -c "$pubbytes" | base64 | tr -d '\r\n=' | tr '+/' '-_'
}

verify_mlkem_pair() {
    local xray=$1 private=$2 public=$3 server_port client_port uuid cfg child i rows status='' ready=0
    server_port=$(random_free_port) || return 1
    for i in {1..5}; do
        client_port=$(random_free_port) || return 1
        [[ $client_port == "$server_port" ]] || break
    done
    [[ $client_port != "$server_port" ]] || return 1
    uuid=$(new_uuid) && [[ -n $uuid ]] || return 1
    # Feed a single, private test configuration to the selected Xray over stdin.
    # Both listeners use loopback; every possible exit is either blackholed or
    # returns a local HTTP 403. A 403 can only follow a successful VLESS handshake.
    cfg=$(jq -cn --rawfile seed <(printf '%s' "$private") --arg pub "$public" --arg id "$uuid" \
        --argjson c "$client_port" --argjson s "$server_port" '{
        log:{loglevel:"none"},
        inbounds:[
            {tag:"probe",listen:"127.0.0.1",port:$c,protocol:"tunnel",settings:{address:"127.0.0.1",port:80,network:"tcp"}},
            {tag:"verify",listen:"127.0.0.1",port:$s,protocol:"vless",
             settings:{clients:[{id:$id}],decryption:("mlkem768x25519plus.native.0s."+$seed)}}],
        outbounds:[
            {tag:"closed",protocol:"blackhole"},
            {tag:"link",protocol:"vless",settings:{address:"127.0.0.1",port:$s,id:$id,
             encryption:("mlkem768x25519plus.native.1rtt."+$pub)}},
            {tag:"answer",protocol:"blackhole",settings:{response:{type:"http"}}}],
        routing:{rules:[
            {type:"field",inboundTag:["probe"],outboundTag:"link"},
            {type:"field",inboundTag:["verify"],outboundTag:"answer"}]}}') || return 1
    "$xray" run -format json -config stdin: <<< "$cfg" >/dev/null 2>&1 3>&- 4>&- 5>&- 8>&- 9>&- &
    child=$!
    for i in {1..12}; do
        kill -0 "$child" 2>/dev/null || break
        rows=$(listeners tcp "$server_port") || break
        if listeners_only_pid "$rows" "$child"; then
            rows=$(listeners tcp "$client_port") || break
            if listeners_only_pid "$rows" "$child"; then ready=1; break; fi
        fi
        sleep 0.2
    done
    if (( ready )); then
        status=$(curl -q --noproxy '*' --max-time 5 -s -o /dev/null -w '%{http_code}' \
            "http://127.0.0.1:$client_port/") || status=''
        kill -0 "$child" 2>/dev/null || status=''
    fi
    kill -KILL "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    [[ $status == 403 ]]
}

store_keypair() {
    # Both fields are written in one atomic draft replacement. Pass the
    # private value through a pipe, never as an external process argument.
    local protocol=$1 private=$2 public=$3 settings=${4:-null}
    if [[ $protocol == reality ]]; then
        st_filter --rawfile priv <(printf '%s' "$private") --arg pub "$public" '.reality += {private_key:$priv, public_key:$pub}'
    else
        st_filter --rawfile priv <(printf '%s' "$private") --arg pub "$public" --argjson settings "$settings" '.enc += ($settings + {server_key:$priv, client_key:$pub})'
    fi
}

set_custom_keypair() {
    local protocol=$1 private=$2 public=$3 algorithm=x25519 private_bytes=32 public_bytes=32 derived settings='{}'
    local shape='' ticket='' rtt='' pad_server='' pad_client=''
    CREDENTIAL_ERR='' CREDENTIAL_NOTE=''
    case $protocol in
        reality) scheme_has_reality "$(scheme)" || { CREDENTIAL_ERR='当前方案没有 REALITY 入站。'; return 1; } ;;
        enc)
            needs_enc_keys || { CREDENTIAL_ERR='当前方案没有启用 VLESS-ENC。'; return 1; }
            if [[ $private == *.* || $public == *.* ]]; then
                # Each inbound supports one matching key pair and one shared handshake mode.
                local prefix='^mlkem768x25519plus[.](native|random|xorpub)[.]'
                local suffix='[.](([0-9.-]+)[.])?([A-Za-z0-9_-]+)$'
                local dec_re="$prefix"'([0-9-]+)s'"$suffix"
                local enc_re="$prefix"'(0rtt|1rtt)'"$suffix"
                if [[ ! $private =~ $dec_re ]]; then CREDENTIAL_ERR='decryption 格式无效，请粘贴单密钥配置的完整字段值。'; return 1; fi
                shape=${BASH_REMATCH[1]} ticket=${BASH_REMATCH[2]} pad_server=${BASH_REMATCH[4]} private=${BASH_REMATCH[5]}
                if [[ ! $public =~ $enc_re ]]; then CREDENTIAL_ERR='encryption 格式无效，请粘贴同一组的完整字段值。'; return 1; fi
                rtt=${BASH_REMATCH[2]} pad_client=${BASH_REMATCH[4]} public=${BASH_REMATCH[5]}
                if [[ $shape != "${BASH_REMATCH[1]}" ]]; then CREDENTIAL_ERR='两端的握手外观不同。'; return 1; fi
                if ! valid_enc_ticket "$ticket"; then CREDENTIAL_ERR='票据有效期须为 0–86400 秒，可写成范围。'; return 1; fi
                if { [[ -n $pad_server ]] && ! valid_padding "$pad_server"; } ||
                   { [[ -n $pad_client ]] && ! valid_padding "$pad_client"; }; then
                    CREDENTIAL_ERR='填充参数无效。'; return 1
                fi
            fi
            if (( ${#private} == 86 )); then algorithm=mlkem768; private_bytes=64; public_bytes=1184; fi ;;
        *) CREDENTIAL_ERR='无法识别密钥协议。'; return 1 ;;
    esac
    if ! valid_raw_key "$private" "$private_bytes" || ! valid_raw_key "$public" "$public_bytes"; then
        CREDENTIAL_ERR="$(auth_label "$algorithm") 需要无填充的 Base64URL 密钥，私钥 $private_bytes 字节，公钥 $public_bytes 字节。"
        return 1
    fi
    if derived=$(keypair_public "$algorithm" "$private") && [[ -n $derived ]]; then
        [[ $derived == "$public" ]] || { CREDENTIAL_ERR='公钥与私钥不配对，请核对后重新输入。'; return 1; }
    elif [[ $algorithm == mlkem768 ]]; then
        local ver
        if ver=$(xray_version_of "$XRAY_BIN") && ver_ge "$ver" "$XRAY_MIN_VERSION"; then
            verify_mlkem_pair "$XRAY_BIN" "$private" "$public" || {
                CREDENTIAL_ERR='ML-KEM 本机握手未通过，请检查密钥对和回环监听。'; return 1;
            }
        else
            CREDENTIAL_NOTE='已暂存 ML-KEM 密钥。应用时将用选定的 Xray 核验配对。'
        fi
    else
        CREDENTIAL_ERR='本机 OpenSSL 无法从 X25519 私钥派生公钥。'; return 1
    fi
    if [[ $protocol == enc ]]; then
        settings=$(jq -cn --arg auth "$algorithm" --arg shape "$shape" --arg rtt "$rtt" --arg ticket "$ticket" \
            --arg pc "$pad_client" --arg ps "$pad_server" '{auth:$auth} +
                (if $shape == "" then {} else {shape:$shape, rtt:$rtt, ticket:($ticket+"s"),
                 pad:(if $pc == "" and $ps == "" then "off" else "custom" end), pad_client:$pc, pad_server:$ps} end)') || return 1
    fi
    store_keypair "$protocol" "$private" "$public" "$settings"
}

valid_xmux_range() {
    local value=$1 digits=${2:-4} lo hi
    [[ $value =~ ^[0-9]+(-[0-9]+)?$ ]] || return 1
    lo=${value%%-*}; hi=${value##*-}
    (( ${#lo} <= digits && ${#hi} <= digits )) || return 1
    # Xray uses zero for defaults / disabling some XMUX limits.
    (( 10#$lo <= 10#$hi ))
}

valid_vless_encryption() {
    local value=$1 segment bytes padding='' keys=0
    [[ $value == none ]] && return 0
    local -a parts=()
    IFS=. read -r -a parts <<< "$value"
    (( ${#parts[@]} >= 4 )) || return 1
    [[ ${parts[0]} == mlkem768x25519plus && ${parts[1]} =~ ^(native|xorpub|random)$ && ${parts[2]} =~ ^(0rtt|1rtt)$ && $value != *. ]] || return 1
    for segment in "${parts[@]:3}"; do
        [[ -n $segment ]] || return 1
        if (( ${#segment} < 20 )); then
            (( keys == 0 )) || return 1
            padding+=${padding:+.}$segment
        else
            [[ $segment =~ ^[A-Za-z0-9_-]+$ ]] || return 1
            bytes=$(b64_decode_relaxed "$segment" 1 | wc -c) || return 1
            [[ $bytes == 32 || $bytes == 1184 ]] || return 1
            keys=$((keys + 1))
        fi
    done
    (( keys > 0 )) || return 1
    [[ -z $padding ]] || valid_padding "$padding"
}

uri_host() {
    if [[ $1 == *:* && $1 != \[*\] ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}


is_managed_path() {
    local m
    for m in "${MANAGED_PATHS[@]}" "$NGINX_RUN"; do
        [[ $1 == "$m" || $1 == "$m"/* ]] && return 0
    done
    return 1
}

make_dir() {
    local d p
    local -a missing=()
    for d in "$@"; do
        missing=()
        p=$d
        while [[ -n $p && $p != / && ! -d $p ]]; do
            missing=("$p" "${missing[@]}")
            p=$(dirname -- "$p")
        done
        (( ${#missing[@]} )) || continue
        (umask 022 && mkdir -p -- "$d") || return 1
        for p in "${missing[@]}"; do
            is_managed_path "$p" && continue
            CREATED_DIRS+=("$p")
            if [[ -d $TX ]]; then printf '%s\n' "$p" >> "$TX/created-dirs" || return 1; fi
        done
    done
}

remove_created_dirs() {
    local d p
    while IFS= read -r d; do
        [[ -n $d && $d != / && $d != "$ROOT" && ! -L $d ]] || continue
        for p in "${MANAGED_PATHS[@]}" "$NGINX_RUN"; do
            [[ $p == "$d"/* ]] || continue
            rmdir -- "$d" 2>/dev/null || true
            break
        done
    done < <(sort -ru)
}

repair_std_dirs() {
    local d m recorded
    recorded=$(jq -r '.meta.created_dirs // [] | .[]' "$DRAFT") || return 1
    while IFS= read -r d; do
        case $d in
            "$ROOT/usr/local"|"$ROOT/usr/local/bin"|"$ROOT/usr/local/etc"|"$ROOT/usr/local/lib"|"$ROOT/usr/local/share") ;;
            *) continue ;;
        esac
        [[ -d $d && ! -L $d ]] || continue
        m=$(stat -c %a -- "$d" 2>/dev/null) || continue
        (( (8#$m & 5) == 5 )) || chmod go+rx -- "$d" || return 1
    done <<< "$recorded"
}

atomic_install() {
    local src=$1 dest=$2 mode=${3:-600} tmp
    if [[ ${4:-} != replace-link || ! -L $dest ]] && [[ -d $dest ]]; then
        die "写入目标是目录：$dest"; return 1
    fi
    make_dir "$(dirname -- "$dest")" || return 1
    tmp=$(mktemp "$dest.new.XXXXXX") || { die "无法创建临时文件：$dest"; return 1; }
    if ! cp -- "$src" "$tmp" || ! chmod "$mode" "$tmp" || ! mv -fT -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        die "无法写入 $dest"
    fi
}

atomic_write() {
    local dest=$1 mode=${2:-600} tmp
    [[ ! -d $dest ]] || { die "写入目标是目录：$dest"; return 1; }
    make_dir "$(dirname -- "$dest")" || return 1
    tmp=$(mktemp "$dest.new.XXXXXX") || { die "无法创建临时文件：$dest"; return 1; }
    if ! cat > "$tmp" || ! chmod "$mode" "$tmp" || ! mv -fT -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        die "无法写入 $dest"
    fi
}

is_regular_executable() { [[ ! -L $1 && -f $1 && -x $1 ]]; }

is_managed_file() { [[ ! -L $1 && -f $1 ]] && grep -Fxq -- "$MANAGED_TAG" "$1" 2>/dev/null; }

human_bytes() {
    awk -v b="$1" 'BEGIN {
        if (b >= 1048576) { v = b / 1048576; u = "M" } else if (b >= 1024) { v = b / 1024; u = "K" } else { printf "%d", b; exit }
        s = sprintf("%.1f", v); sub(/\.0$/, "", s); printf "%s%s", s, u }'
}


detect_system() {
    local id='' line manager os_file=$ROOT/etc/os-release
    [[ -e $os_file || -L $os_file ]] || os_file=$ROOT/usr/lib/os-release
    if [[ -f $os_file && -r $os_file ]]; then
        # Read the exact ID as data. A derivative's ID_LIKE is insufficient.
        while IFS= read -r line || [[ -n $line ]]; do
            [[ $line != ID=* ]] || id=${line#ID=}
        done < "$os_file"
    fi
    case $id in
        debian|ubuntu|'"debian"'|'"ubuntu"'|"'debian'"|"'ubuntu'") ;;
        *) die '仅支持 Debian 和 Ubuntu。请核对 /etc/os-release 中的 ID。'; return 1 ;;
    esac
    if [[ ! -d $ROOT/run/systemd/system ]]; then
        if grep -qi microsoft "$ROOT/proc/sys/kernel/osrelease" 2>/dev/null; then
            die '当前 WSL 发行版未启用 systemd。' '请在 /etc/wsl.conf 的 [boot] 节设置 systemd=true，再从 Windows 重启该发行版。'
        else
            die '需要正在运行的 systemd 系统管理器。'
        fi
        return 1
    fi
    if ! manager=$(timeout -k 2 5 systemctl --system show -p Version --value 2>/dev/null) || [[ -z $manager ]]; then
        die '无法连接 systemd 系统管理器。' '请运行 systemctl --system status 检查连接。'
        return 1
    fi
}

pkg_run() { (umask 022 && "$@") 3>&- 4>&- 5>&- 8>&- 9>&-; }

pkg_install() {
    DEBIAN_FRONTEND=noninteractive pkg_run apt-get -o DPkg::Lock::Timeout=180 install -y -qq "$@"
}

pkg_refresh() {
    pkg_run apt-get -o DPkg::Lock::Timeout=180 -o APT::Update::Error-Mode=any update -qq
}

pkg_remove() {
    (( $# )) || return 0
    # apt's simulation checked reverse dependencies. The real removal must not
    # re-solve the transaction and add packages if another apt session ran since.
    DEBIAN_FRONTEND=noninteractive pkg_run dpkg --refuse-depends --purge "$@"
}

pkg_installed() {
    [[ $(dpkg-query -W -f='${db:Status-Status}' -- "$1" 2>/dev/null) == installed ]]
}

pkg_snapshot() {
    local snapshot purpose=${1:-installed} arch=''
    case $purpose in
        native-installed|native-present) arch=$(dpkg --print-architecture) && [[ -n $arch ]] || return 1 ;;
        installed|present) ;;
        *) return 1 ;;
    esac
    # Protect residual and unfinished pre-existing packages of every architecture.
    snapshot=$(timeout -k 2 15 dpkg-query -W -f='${db:Status-Status} ${Package} ${Architecture}\n' 2>/dev/null |
        awk -v purpose="$purpose" -v arch="$arch" '
            arch != "" && $3 != arch && $3 != "all" {next}
            $1 == "installed" || ((purpose == "present" || purpose == "native-present") && $1 != "not-installed") {print $2}' |
        LC_ALL=C sort -u) || return 1
    [[ -n ${snapshot//[[:space:]]/} ]] || return 1
    printf '%s\n' "$snapshot"
}

pkg_added_since() {
    local before after package added LC_ALL=C
    [[ -s $1 && -n $2 ]] || return 1
    (( $# >= 3 )) || return 0
    # Re-sort older baselines; recovery may run under a different SSH locale.
    before=$(LC_ALL=C sort -u -- "$1") || return 1
    after=$(LC_ALL=C sort -u <<< "$2") || return 1
    [[ -n $before && -n $after ]] || return 1
    while IFS= read -r package; do
        [[ $package =~ ^[a-zA-Z0-9][a-zA-Z0-9.+_:-]*$ ]] || return 1
    done <<< "$before"$'\n'"$after"
    # Never expose comm's partial output if reading/comparing either side fails.
    added=$(LC_ALL=C comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after")) || return 1
    shift 2
    while IFS= read -r package; do
        [[ -n $package ]] || continue
        if in_list "$package" "$@"; then printf '%s\n' "$package" || return 1; fi
    done <<< "$added"
}

# dpkg purge also removes old conffile and editor backups, even outside
# /etc/nginx. dpkg --verify alone does not inspect those adjacent files.
pkg_conffiles_ok() {
    local configs row path file expected hash backup
    configs=$(LC_ALL=C timeout -k 2 15 dpkg-query -W -f='${Conffiles}\n' -- "$@") || return 1
    while IFS= read -r row; do
        [[ -n $row ]] || continue
        [[ $row =~ ^[[:blank:]]+(/.*)[[:blank:]]([[:xdigit:]]{32})([[:blank:]]obsolete)?$ ]] || return 1
        path=${BASH_REMATCH[1]} expected=${BASH_REMATCH[2]}
        file=$ROOT$path
        [[ ! -L $file ]] || return 1
        for backup in "$file".dpkg-* "$file"~ "$file"% "${file%/*}/#${file##*/}#" "$file".~*~; do
            [[ ! -e $backup && ! -L $backup ]] || return 1
        done
        [[ -e $file ]] || continue
        [[ -f $file ]] && hash=$(md5sum < "$file") && [[ ${hash%% *} == "$expected" ]] || return 1
    done <<< "$configs"
}

# Interrupted unpack may leave absent non-configuration payloads.
pkg_partial_files_ok() {
    local pkg=$1 changes row file sums rc=0
    sums=$(LC_ALL=C timeout -k 2 15 dpkg-query --control-show "$pkg" md5sums 2>/dev/null) && [[ -n $sums ]] || return 1
    pkg_conffiles_ok "$pkg" || return 1
    changes=$(LC_ALL=C timeout -k 2 30 dpkg --verify-format=rpm --verify -- "$pkg" 2>&1) || rc=$?
    (( rc == 0 )) || { (( rc == 1 )) && [[ -n $changes ]]; } || return 1
    while IFS= read -r row; do
        [[ -n $row ]] || continue
        [[ $row =~ ^missing[[:blank:]]+(/usr/(bin|sbin|lib|libexec|share)/[^[:space:]]+)$ ]] || return 1
        file=$ROOT${BASH_REMATCH[1]}
        [[ ! -e $file && ! -L $file ]] || return 1
    done <<< "$changes"
}

pkg_rollback_partial() {
    local receipt=$1 arch name query_name version package_arch want flag state protected info
    shift
    [[ -n $receipt && ! -L $TX/pkgs-versions && -f $TX/pkgs-versions && -s $TX/pkgs-versions ]] || return 1
    arch=$(dpkg --print-architecture) && [[ -n $arch ]] || return 1
    local -a confirmed=() targets=() names=()
    read -r -a confirmed <<< "$receipt"
    local format='${Package} ${Architecture} ${Version} ${db:Status-Want} ${db:Status-Eflag} ${db:Status-Status} ${Essential}:${Protected}\n'
    for name in "$@"; do
        [[ $name =~ ^[a-z0-9][a-z0-9.+-]*$ ]] && in_list "$name" "${confirmed[@]}" || continue
        info=$(timeout -k 2 10 dpkg-query -W -f="$format" -- "$name" 2>/dev/null) || continue
        [[ $info != *$'\n'* ]] || continue
        read -r query_name package_arch version want flag state protected <<< "$info"
        [[ $query_name == "$name" && ( $package_arch == "$arch" || $package_arch == all ) &&
           $want == install && $flag == ok && $protected =~ ^(no)?:(no)?$ ]] || continue
        case $state in unpacked|half-configured|half-installed) ;; *) continue ;; esac
        grep -Fxq -e "$name $version" -e "$name:$package_arch $version" -- "$TX/pkgs-versions" || continue
        pkg_partial_files_ok "$name:$package_arch" || continue
        targets+=("$name:$package_arch")
        names+=("$name")
    done
    (( ${#targets[@]} )) || return 1
    if in_list nginx-common "${names[@]}"; then nginx_deb_purge_safe "${names[@]}" || return 1; fi
    # No solver or force option. A changed reverse dependency can still veto
    # removal under dpkg's lock. Leave unrelated pending triggers alone.
    local -a opts=(--no-triggers --refuse-depends,depends-version,remove-essential,remove-reinstreq --purge)
    LC_ALL=C timeout -k 2 30 dpkg --no-act "${opts[@]}" "${targets[@]}" >/dev/null 2>&1 || return 1
    DEBIAN_FRONTEND=noninteractive pkg_run dpkg "${opts[@]}" "${targets[@]}"
}

pkg_report_retained() {
    local all p arch state
    (( $# )) || return 0
    all=$(timeout -k 2 15 dpkg-query -W -f='${Package} ${Architecture} ${db:Status-Status}\n') || {
        ui_warn '未能核实软件包清理结果，请运行 dpkg --audit 检查。'; return 0;
    }
    while read -r p arch state; do
        [[ $state != not-installed ]] && in_list "$p" "$@" || continue
        ui_warn "已保留 $p:$arch（$state），请用 dpkg --audit 核查。"
    done <<< "$all"
}

pkg_remove_safe() {
    local p x plan removed set installed changes qualified arch name package_arch want selection=native-installed
    if [[ ${1:-} == --rollback ]]; then selection=native-present; shift; fi
    local -a safe=() installed_names=() targets=()
    local -A by_name=()
    (( $# )) || return 0
    for p in "$@"; do
        # Metadata must never become package-manager switches or glob patterns.
        [[ $p =~ ^[a-zA-Z0-9][a-zA-Z0-9.+_:-]*$ ]] || return 1
    done
    # A failed package lookup does not prove absence. Only a complete,
    # successful database snapshot may select or verify removals.
    installed=$(pkg_snapshot "$selection") || return 1
    mapfile -t installed_names <<< "$installed"
    for p in "$@"; do
        in_list "$p" "${installed_names[@]}" || continue
        safe+=("$p")
    done
    (( ${#safe[@]} )) || return 0
    mapfile -t safe < <(printf '%s\n' "${safe[@]}" | sort -u)
    set=" ${safe[*]} "
    # Validate the complete removal transaction, including automatically removed
    # dependencies. Failed or unrecognised plans are never permission to remove.
    plan=$(LC_ALL=C LANGUAGE=C timeout -k 5 30 apt-get -o APT::Get::AutomaticRemove=false -s purge "${safe[@]}" 2>/dev/null) || return 1
    if ! pkg_conffiles_ok "${safe[@]}"; then
        ui_warn '无法确认配置文件及其备份可安全删除，已保留软件包。'
        return 1
    fi
    changes=$(LC_ALL=C timeout -k 2 30 dpkg --verify -- "${safe[@]}" 2>&1) && [[ -z $changes ]] || return 1
    ! grep -Eq '^(Inst|Conf) ' <<< "$plan" || return 1
    removed=$(awk '$1 == "Purg" || $1 == "Remv" {print $2}' <<< "$plan")
    [[ -n $removed ]] || return 1
    while IFS= read -r x; do
        [[ -n $x && $set == *" $x "* ]] || return 1
    done <<< "$removed"
    for p in "${safe[@]}"; do
        [[ $'\n'$removed$'\n' == *$'\n'"$p"$'\n'* ]] || return 1
    done
    for p in "${safe[@]}"; do
        [[ ${p%%:*} == nginx-common ]] || continue
        nginx_deb_purge_safe "${safe[@]}" || {
            ui_warn '已保留 Nginx 软件包。请检查配置、日志和缓存目录中是否有需要保留的文件。'
            return 1
        }
        break
    done
    # Pin the native/all architecture as well as the package name. dpkg must
    # not select a foreign replacement that appeared after the simulation.
    arch=$(dpkg --print-architecture) && [[ -n $arch ]] || return 1
    qualified=$(timeout -k 2 15 dpkg-query -W -f='${Package} ${Architecture} ${db:Status-Want}\n' -- "${safe[@]}") || return 1
    while read -r name package_arch want; do
        [[ $package_arch == "$arch" || $package_arch == all ]] || continue
        # An explicit dpkg --purge ignores hold, even without --force-hold.
        case $want in
            hold) ui_warn "软件包 $name 已设置 hold，已跳过清理。"; return 1 ;;
            install|deinstall|purge|unknown) ;;
            *) return 1 ;;
        esac
        in_list "$name" "${safe[@]}" && [[ -z ${by_name[$name]:-} ]] || return 1
        by_name[$name]="$name:$package_arch"
    done <<< "$qualified"
    for p in "${safe[@]}"; do
        [[ -n ${by_name[$p]:-} ]] || return 1
        targets+=("${by_name[$p]}")
    done
    pkg_remove "${targets[@]}" || return 1
    installed=$(pkg_snapshot native-present) || return 1
    mapfile -t installed_names <<< "$installed"
    for p in "${safe[@]}"; do in_list "$p" "${installed_names[@]}" && return 1; done
    return 0
}

json_words() { tr -s ' ' '\n' <<< "$1" | jq -R . | jq -cs 'map(select(. != ""))'; }

ensure_deps() {
    local c refresh_log install_log
    local -a need=() missing=()
    local -A pkg_of=(
        [curl]=curl [jq]=jq [openssl]=openssl [unzip]=unzip [tar]=tar [xz]=xz-utils [gzip]=gzip
        [sha256sum]=coreutils [timeout]=coreutils [shuf]=coreutils [base64]=coreutils [date]=coreutils
        [flock]=util-linux [setpriv]=util-linux [ss]=iproute2 [ip]=iproute2 [pgrep]=procps
        [cmp]=diffutils [getent]=libc-bin [perl]=perl-base [useradd]=passwd [userdel]=passwd [groupdel]=passwd
    )
    pkg_installed ca-certificates || need+=(ca-certificates)
    for c in "${!pkg_of[@]}"; do
        if ! have "$c"; then need+=("${pkg_of[$c]}"); missing+=("$c"); fi
    done
    (( ${#need[@]} )) || return 0
    mapfile -t need < <(printf '%s\n' "${need[@]}" | sort -u)
    ui_line "正在安装依赖：${need[*]}"
    if refresh_log=$(pkg_refresh 2>&1 | tail -n 6 | terminal_text); then refresh_log=''; fi
    if ! install_log=$(pkg_install --no-remove "${need[@]}" 2>&1 | tail -n 12 | terminal_text); then
        die "依赖安装失败：${need[*]}" ${refresh_log:+"更新软件源：$refresh_log"} ${install_log:+"安装依赖：$install_log"}
        return 1
    fi
    hash -r
    for c in "${missing[@]}"; do
        have "$c" || { die "已安装 ${pkg_of[$c]}，命令 $c 仍不可用，请检查软件包和 PATH。"; return 1; }
    done
}


svc_exists() {
    local load rc=0
    load=$(timeout -k 2 5 systemctl show "$1" -p LoadState --value 2>>"${STEP_LOG:-/dev/null}") || rc=$?
    case $rc:$load in
        0:not-found|4:not-found) return 1 ;;
        0:loaded|0:masked|0:bad-setting|0:error|0:stub|0:merged) return 0 ;;
        *) return 2 ;;
    esac
}
svc_active() {
    local active rc=0
    active=$(timeout -k 2 5 systemctl show "$1" -p ActiveState --value 2>>"${STEP_LOG:-/dev/null}") || rc=$?
    case $rc:$active in
        0:active|0:reloading|0:refreshing) return 0 ;;
        0:inactive|4:inactive|0:failed|0:activating|0:deactivating|0:maintenance) return 1 ;;
        *) return 2 ;;
    esac
}
svc_command() (
    umask 022
    timeout -k 5 45 systemctl "$@" >/dev/null 3>&- 4>&- 5>&- 8>&- 9>&-
)
svc_do() { svc_command "$@" 2>>"${STEP_LOG:-/dev/null}"; }
# Confirm the same managed unit is idle immediately before bypassing a failed stop
# or accepting a damaged unit for a repair snapshot. Missing/duplicate fields fail.
svc_broken_idle() {
    local -n detail_out=$5
    local s=$1 load=$2 active=$3 enabled=$4 data line key value reason='' rc=0
    detail_out=''
    local -A required=([Id]="$s.service" [FragmentPath]="$SYSTEMD_DIR/$s.service"
        [LoadState]="$load" [ActiveState]="$active" [UnitFileState]="$enabled"
        [Job]='' [MainPID]=0 [ControlPID]=0 [ControlGroup]='')
    in_list "$s" "${MANAGED_SERVICES[@]}" || return 1
    if [[ ( $load != bad-setting && $load != error ) || ( $active != inactive && $active != failed ) ]]; then
        reason='首次查询无法同时确认单元加载异常且已停止。'
    else
        data=$(timeout -k 2 5 systemctl show "$s" --all -p Id -p FragmentPath -p LoadState -p ActiveState \
            -p UnitFileState -p Job -p MainPID -p ControlPID -p ControlGroup 2>>"${STEP_LOG:-/dev/null}") || rc=$?
        if (( rc )); then
            reason="systemctl show 查询失败（退出码 $rc）。"
        else
            while IFS= read -r line; do
                [[ $line == *=* ]] || { reason='属性行格式异常。'; break; }
                key=${line%%=*} value=${line#*=}
                case $key in
                    Id|FragmentPath|LoadState|ActiveState|UnitFileState|Job|MainPID|ControlPID|ControlGroup) ;;
                    *) reason='查询返回了未请求的属性。'; break ;;
                esac
                [[ ${required[$key]+set} ]] || { reason="属性 $key 重复。"; break; }
                if [[ $value != "${required[$key]}" ]]; then
                    case $key in
                        Id|FragmentPath) reason="属性 $key 与托管单元不符，无法确认归属。" ;;
                        Job) reason='Job 非空，systemd 仍报告有作业。' ;;
                        MainPID|ControlPID) reason="$key 非零，无法确认进程已退出。" ;;
                        ControlGroup) reason='ControlGroup 非空，无法确认控制组已释放。' ;;
                        *) reason="两次查询的 $key 不一致。" ;;
                    esac
                    break
                fi
                unset 'required[$key]'
            done <<< "$data"
            if [[ -z $reason ]]; then
                for key in "${!required[@]}"; do reason="缺少属性 $key。"; break; done
            fi
        fi
    fi
    [[ -n $reason ]] || return 0
    # The forward error handler displays the step log. Recovery and logless calls
    # pass the reason back so the caller can finish its step before printing it.
    if (( ! IN_ROLLBACK )) && [[ -n $STEP_LOG && $STEP_LOG != /dev/null ]]; then
        if printf '%s\n' "$s：$reason" >> "$STEP_LOG"; then return 1; fi
    fi
    detail_out="$s：$reason"
    return 1
}

svc_fail() {
    local dir="$SYSTEMD_DIR/$1.service.d" file
    shift
    for file in "$dir"/*.conf; do
        if [[ -f $file || -L $file ]]; then
            set -- "$@" "请检查本地覆盖配置：$dir/"
            break
        fi
    done
    die "$@"
}

svc_stop_disable() {
    local state enabled load active raw detail='' native='' rc=0 exists_rc=0
    svc_state_line state "$1" stop || return 1
    [[ -n $state ]] || return 0
    read -r _ _ enabled load active raw <<< "$state"
    # Always request stop, including for inactive units with a queued restart.
    if (( IN_ROLLBACK )); then
        # The forward step log has already been shown or is unavailable.
        native=$(svc_command stop "$1" 2>&1) || rc=$?
    else
        svc_do stop "$1" || rc=$?
    fi
    if (( rc != 0 )); then
        # systemd may collect a cached unit between the state query and stop.
        if (( rc == 5 )) && [[ $enabled == removed && ! -e $SYSTEMD_DIR/$1.service && ! -L $SYSTEMD_DIR/$1.service ]]; then
            svc_exists "$1" || exists_rc=$?
            (( exists_rc != 1 )) || return 0
        fi
        # systemctl reports NoSuchUnit (5) for certain inactive, invalid units.
        if (( rc != 5 )) || [[ -z $load ]] || ! svc_broken_idle "$1" "$load" "$active" "$raw" detail; then
            if [[ -n $native ]]; then native=$(printf '%s\n' "$native" | tail -n 3 | terminal_text); fi
            svc_fail "$1" "未能停止服务 $1（退出码 $rc），已中止文件修改。" ${detail:+"$detail"} ${native:+"systemctl：$native"}
            return 1
        fi
    fi
    [[ ${2:-disable} != runtime-only ]] || return 0
    case $enabled in
        1) svc_do disable "$1" || { die "未能取消 $1 的开机自启。"; return 1; } ;;
        runtime) svc_do disable --runtime "$1" || { die "无法取消 $1 的临时自启。"; return 1; } ;;
    esac
    return 0
}
svc_reload_units() {
    timeout -k 5 15 systemctl daemon-reload
}

write_service() {
    local name=$1 cmd=$2 args=$3 desc=$4 user=$5 lowport=$6 env=${7:-} rw=${8:-} run=${9:-}
    local file
    local -a lines
    file=$STAGE/$name.service
    lines=("$MANAGED_TAG" '[Unit]' "Description=$desc" 'After=network-online.target' 'Wants=network-online.target' ''
        '[Service]' 'Type=simple')
    if [[ -n $run ]]; then lines+=("RuntimeDirectory=$run" 'RuntimeDirectoryMode=0755' 'RuntimeDirectoryPreserve=no'); fi
    if [[ $user != root ]]; then lines+=("User=$user" "Group=$user"); fi
    if [[ -n $env ]]; then lines+=("Environment=$env"); fi
    lines+=("ExecStart=$cmd $args" 'Restart=on-failure' 'RestartSec=3' 'TimeoutStartSec=30' 'TimeoutStopSec=15' 'LimitNOFILE=1048576')
    if [[ $user != root ]]; then
        if (( lowport )); then lines+=('AmbientCapabilities=CAP_NET_BIND_SERVICE' 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE')
        else lines+=('CapabilityBoundingSet='); fi
        lines+=('NoNewPrivileges=true')
    elif [[ $name == zxray-nginx ]]; then
        # Nginx binds the public port and signals workers after their UID/GID switch.
        lines+=('NoNewPrivileges=true' 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID CAP_KILL CAP_CHOWN')
    fi
    lines+=('ProtectSystem=full' 'ProtectHome=true' 'PrivateTmp=true')
    if [[ -n $rw ]]; then lines+=("ReadWritePaths=$rw"); fi
    lines+=('' '[Install]' 'WantedBy=multi-user.target')
    printf '%s\n' "${lines[@]}" > "$file" || return 1
    atomic_install "$file" "$SYSTEMD_DIR/$name.service" 644
}

verify_service_user() {
    local uid gid record name _group_passwd group_gid members groups
    uid=$(timeout -k 2 5 id -u "$SERVICE_USER" 2>/dev/null) \
        && gid=$(timeout -k 2 5 id -g "$SERVICE_USER" 2>/dev/null) \
        && record=$(timeout -k 2 5 getent group "$SERVICE_USER" 2>/dev/null) || {
        die "无法核实运行账户 $SERVICE_USER 的权限。"; return 1;
    }
    IFS=: read -r name _group_passwd group_gid members <<< "$record"
    [[ $record != *$'\n'* && $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ && ! $uid =~ ^0+$ && ! $gid =~ ^0+$ \
        && $name == "$SERVICE_USER" && $group_gid == "$gid" ]] || {
        die "运行账户 $SERVICE_USER 的权限不安全。" '需要非 root 用户，并使用同名的普通主组。'; return 1;
    }
    # systemd and setpriv --init-groups inherit all supplementary memberships.
    groups=$(timeout -k 2 5 id -G "$SERVICE_USER" 2>/dev/null) && [[ $groups == "$gid" ]] || {
        die "运行账户 $SERVICE_USER 只能属于同名主组。请运行 id -G $SERVICE_USER 检查。"; return 1;
    }
    service_group_private "$gid" "$members" || {
        die "无法确认 $SERVICE_USER 是同名组的唯一用户。" '请检查组成员以及使用该主组的其他账户。'; return 1;
    }
}

ensure_service_user() {
    local nologin=/usr/sbin/nologin rc=0
    timeout -k 2 5 getent passwd "$SERVICE_USER" >/dev/null 2>&1 || rc=$?
    case $rc in
        0) verify_service_user; return $? ;;
        2) ;;
        *) die "无法查询运行账户 $SERVICE_USER，已停止创建。"; return 1 ;;
    esac
    rc=0
    timeout -k 2 5 getent group "$SERVICE_USER" >/dev/null 2>&1 || rc=$?
    case $rc in
        0) die "同名用户组 $SERVICE_USER 已存在，已停止创建运行账户。"; return 1 ;;
        2) ;;
        *) die "无法查询用户组 $SERVICE_USER，已停止创建。"; return 1 ;;
    esac
    [[ -f $TX/ready ]] || { die '缺少账户恢复记录，已停止创建。'; return 1; }
    # Record intent before either tool can partially create an account/group.
    touch "$TX/created-user" "$TX/created-group" || return 1
    [[ -x $nologin ]] || nologin=/sbin/nologin
    [[ -x $nologin ]] || nologin=/bin/false
    timeout -k 2 15 useradd --system --no-create-home --home-dir /nonexistent --shell "$nologin" --user-group "$SERVICE_USER" || return 1
    verify_service_user || return 1
    SERVICE_USER_CREATED=1
}

service_group_private() {
    local gid=$1 members=$2 accounts member
    local -a group_members=()
    IFS=, read -r -a group_members <<< "$members"
    for member in "${group_members[@]}"; do
        [[ -z $member || $member == "$SERVICE_USER" ]] || return 1
    done
    accounts=$(timeout -k 2 5 getent passwd 2>/dev/null) && [[ -n $accounts ]] || return 1
    awk -F: -v g="$gid" -v u="$SERVICE_USER" '$4 == g && $1 != u {found=1} END {exit found ? 1 : 0}' <<< "$accounts"
}

service_group_removable() {
    local expected_gid=${1:-} rc=0 record name _group_passwd gid members
    record=$(timeout -k 2 5 getent group "$SERVICE_USER" 2>/dev/null) || rc=$?
    (( rc != 2 )) || return 2
    (( rc == 0 )) || return 1
    IFS=: read -r name _group_passwd gid members <<< "$record"
    [[ $record != *$'\n'* && $name == "$SERVICE_USER" && $gid =~ ^[0-9]+$ && ! $gid =~ ^0+$ ]] || return 1
    [[ -z $expected_gid || $gid == "$expected_gid" ]] || return 1
    # A once-private group may later be shared. Preserve its other users.
    service_group_private "$gid" "$members" || {
        ui_warn "无法确认用户组 $SERVICE_USER 仅供运行账户使用，保留账户和组。"; return 1;
    }
}

service_user_busy() {
    local uid=$1 status key real effective saved fs
    [[ -r /proc/self/status ]] || return 0
    for status in /proc/[0-9]*/status; do
        while read -r key real effective saved fs; do
            case $key in
                State:) [[ $real != Z ]] || break ;;
                Uid:)
                    [[ $uid == "$real" || $uid == "$effective" || $uid == "$saved" || $uid == "$fs" ]] && return 0
                    break ;;
            esac
        done 2>/dev/null < "$status" || { [[ ! -d ${status%/*} ]] || return 0; }
    done
    return 1
}

remove_service_user() {
    local expected=${1:-} expected_gid='' rc=0 group_rc=0 record name _passwd uid gid _gecos home shell groups group
    if [[ -n $expected ]]; then
        [[ $expected =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]] || return 1
        expected_gid=${expected#*:}
    fi
    record=$(timeout -k 2 5 getent passwd "$SERVICE_USER" 2>/dev/null) || rc=$?
    (( rc == 0 || rc == 2 )) || return 1
    if (( rc == 0 )); then
        IFS=: read -r name _passwd uid gid _gecos home shell <<< "$record"
        [[ $record != *$'\n'* && $name == "$SERVICE_USER" && $uid =~ ^[0-9]+$ && ! $uid =~ ^0+$ \
            && $gid =~ ^[0-9]+$ && ! $gid =~ ^0+$ ]] || return 1
        # Keep accounts that were recreated or converted to another use.
        [[ -z $expected || $uid:$gid == "$expected" ]] || return 1
        [[ $home == /nonexistent ]] || return 1
        case $shell in /usr/sbin/nologin|/sbin/nologin|/bin/false) ;; *) return 1 ;; esac
        groups=$(timeout -k 2 5 id -G "$SERVICE_USER" 2>/dev/null) && [[ $groups =~ ^[0-9]+([[:blank:]]+[0-9]+)*$ ]] || return 1
        for group in $groups; do [[ $group == "$gid" ]] || return 1; done
        service_user_busy "$uid" && return 1
        expected_gid=$gid
    fi
    # userdel may also remove the private group. Check sharing first.
    service_group_removable "$expected_gid" || group_rc=$?
    (( group_rc == 0 || (group_rc == 2 && rc == 2) )) || return 1
    if (( rc == 0 )); then
        timeout -k 2 15 userdel "$SERVICE_USER" 2>/dev/null || return 1
        rc=0
        timeout -k 2 5 getent passwd "$SERVICE_USER" >/dev/null 2>&1 || rc=$?
    fi
    (( rc == 2 )) || return 1
    group_rc=0
    service_group_removable "$expected_gid" || group_rc=$?
    (( group_rc != 2 )) || return 0
    (( group_rc == 0 )) || return 1
    timeout -k 2 15 groupdel "$SERVICE_USER" 2>/dev/null || return 1
    rc=0
    timeout -k 2 5 getent group "$SERVICE_USER" >/dev/null 2>&1 || rc=$?
    (( rc == 2 ))
}

selinux_enforcing() {
    have getenforce && [[ $(getenforce 2>/dev/null || true) == Enforcing ]]
}

install_bin() {
    atomic_install "$1" "$2" 755 replace-link || return 1
    if have getenforce && [[ $(getenforce 2>/dev/null || true) != Disabled ]] && have chcon; then
        chcon -t bin_t -- "$2" 2>/dev/null || true
    fi
}

service_readable_files() {
    local check='
        if [ "$1" = --exec ]; then
            shift
            test -x "$1" || { printf "%s\n" "$1"; exit 1; }
            shift
        fi
        for f do test -r "$f" || { printf "%s\n" "$f"; exit 1; }; done'
    timeout -k 2 10 setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
        /bin/sh -c "$check" _ "$@" 2>>"${STEP_LOG:-/dev/null}" 3>&- 4>&- 5>&- 8>&- 9>&-
}

check_service_access() {
    local bad rc=0
    bad=$(service_readable_files --exec "$@") || rc=$?
    (( rc != 0 )) || return 0
    if [[ -n $bad && $bad == "$1" ]]; then die "运行用户 $SERVICE_USER 无法执行 $bad。" '请检查核心的执行权限和上级目录的访问权限。'
    elif [[ -n $bad ]]; then die "运行用户 $SERVICE_USER 读不到 $bad。" '请检查文件的读取权限和上级目录的访问权限。'
    elif (( rc == 127 )); then die '无法运行 setpriv，请检查 util-linux 软件包。'
    else die '运行用户权限检查失败或超时。'; fi
    return 1
}


fw_kind() {
    if have ufw && [[ $(fw_cmd ufw status 2>/dev/null || true) == *'Status: active'* ]]; then printf 'ufw'
    elif have firewall-cmd && [[ $(fw_cmd firewall-cmd --state 2>/dev/null || true) == running ]]; then printf 'firewalld'; fi
    return 0
}

fw_cmd() { LC_ALL=C LANGUAGE=C timeout -k 2 15 "$@" 8>&-; }

fw_ufw_v6() {
    [[ -r $ROOT/etc/default/ufw ]] || return 2
    awk -F= '/^[ \t]*IPV6[ \t]*=/ {
        v=$2; sub(/[ \t]*#.*/, "", v); gsub(/[ \t"\047]/, "", v); v=tolower(v)
      } END {if (v == "yes") exit 0; if (v == "no") exit 1; exit 2}' "$ROOT/etc/default/ufw"
}

# UFW accepts comma-separated ports and inclusive ranges, e.g. 80,443,8080:8090.
readonly UFW_PORT_MATCH_AWK='
    function covers(spec, port,    fields, limits, i, n) {
        if (spec == "any" || spec == "Anywhere") return 1
        n = split(spec, fields, ",")
        for (i = 1; i <= n; i++) {
            if (fields[i] ~ /^[0-9]+$/ && fields[i] + 0 == port + 0) return 1
            if (fields[i] ~ /^[0-9]+:[0-9]+$/) {
                split(fields[i], limits, ":")
                if (limits[1] + 0 <= port + 0 && port + 0 <= limits[2] + 0) return 1
            }
        }
        return 0
    }'

fw_ufw_saved_has() {
    local kind=$1 rule=$2 exact=${3:-0} file net
    case $kind in
        ufw-v4) file=$ROOT/etc/ufw/user.rules; net=0.0.0.0/0 ;;
        ufw-v6) file=$ROOT/etc/ufw/user6.rules; net=::/0 ;;
        *) return 2 ;;
    esac
    [[ -f $file && -r $file && ! -L $file ]] || return 2
    # 0 accepts covering rules; 1 finds only the original rule; 2 checks an exact restore.
    # UFW reads these tuple records too. Read only; all changes still use ufw.
    awk -v proto="${rule#*/}" -v port="${rule%/*}" -v net="$net" -v exact="$exact" "$UFW_PORT_MATCH_AWK"'
      /^### tuple ###[ \t]+/ {
        commented=($0 ~ /[ \t]+comment=./)
        sub(/^### tuple ###[ \t]+/, ""); sub(/[ \t]+comment=.*/, "")
        if ((NF != 6 && NF != 7) || $4 != net || $5 != "any" || $6 != net) next
        if (!covers($3, port) || ($2 != proto && $2 != "any") || (NF == 7 && $7 != "in")) next
        same=($3 == port && $2 == proto)
        if ($1 == "allow" || $1 ~ /^allow_log(-all)?$/) {
            if (!exact) found=1
            else if (same && !commented && $1 == "allow") found=1
            else if (exact == 2 && same) conflict=1
        } else if (exact != 1 && $1 ~ /^(deny|reject|limit)(_log(-all)?)?$/) conflict=1
      } END {if (exact == 2 && found) exit 0; if (conflict) exit 3; exit !found}' "$file"
}

fw_ufw() {
    local action=$1 kind=$2 rule=$3 net rows family rc=0 exact=0
    [[ $rule =~ ^[0-9]+/(tcp|udp)$ ]] && valid_port "${rule%/*}" || return 2
    case $kind in
        ufw-v4) net=0.0.0.0/0; family=4 ;;
        ufw-v6) net=::/0; family=6 ;;
        *) return 2 ;;
    esac
    if [[ $action == query || $action == query-exact || $action == query-restore ]]; then
        case $action in query-exact) exact=1 ;; query-restore) exact=2 ;; esac
        rows=$(fw_cmd ufw status 2>/dev/null) || return 2
        case ${rows%%$'\n'*} in
            'Status: inactive') fw_ufw_saved_has "$kind" "$rule" "$exact"; return $? ;;
            'Status: active') ;;
            *) return 2 ;;
        esac
        # Accept only unrestricted inbound rules in the requested family.
        awk -v r="$rule" -v p="${rule%/*}" -v family="$family" -v exact="$exact" -v proto="${rule#*/}" "$UFW_PORT_MATCH_AWK"'
          {
            if ($1 != r) {
                if (exact == 1) next
                n = split($1, dest, "/")
                if (n > 2 || (n == 2 && dest[2] != proto) || !covers(dest[1], p)) next
            }
            commented=($0 ~ /[ \t]+#/)
            sub(/[ \t]+#.*/, "")
            logged=($0 ~ /\(log(-all)?\)/)
            v6=($2 == "(v6)"); i=(v6 ? 3 : 2)
            if ((v6 ? 6 : 4) != family) next
            action=$i
            i++; if ($i == "IN") i++
            if ($i != "Anywhere") next
            if (action == "ALLOW") {
                if (!exact) found=1
                else if ($1 == r && !commented && !logged) found=1
                else if (exact == 2 && $1 == r) conflict=1
            } else if (exact != 1 && (action == "DENY" || action == "REJECT" || action == "LIMIT")) conflict=1
          } END {if (exact == 2 && found) exit 0; if (conflict) exit 3; exit !found}' <<< "$rows"
        return $?
    fi
    local -a ufw_args=(allow proto "${rule#*/}" from "$net" to "$net" port "${rule%/*}")
    case $action in
        add) ;;
        remove)
            if [[ $kind == ufw-v6 ]]; then
                fw_ufw_v6 || rc=$?
                if (( rc == 1 )); then
                    die 'UFW 已禁用 IPv6，旧规则仍在。' '请在 /etc/default/ufw 中设置 IPV6=yes，再重试清理。'; return 1
                elif (( rc != 0 )); then die '无法读取 UFW 的 IPv6 设置。'; return 1; fi
            fi
            ufw_args=(--force delete "${ufw_args[@]}") ;;
        *) return 2 ;;
    esac
    fw_cmd ufw "${ufw_args[@]}" >/dev/null 2>>"${STEP_LOG:-/dev/null}"
}

fw_firewalld() {
    local action=$1 kind=$2 rule=$3 scope=${2%%@*} zone='' status rc=0
    local -a cmd=(firewall-cmd -q) opts=()
    [[ $rule =~ ^[0-9]+/(tcp|udp)$ ]] && valid_port "${rule%/*}" || return 2
    if [[ $kind == *@* ]]; then
        zone=${kind#*@}
        [[ $zone =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || return 2
        opts+=(--zone="$zone")
    fi
    case $scope in
        firewalld-runtime) ;;
        firewalld-permanent) opts+=(--permanent) ;;
        *) return 2 ;;
    esac
    case $action in query|query-remove|add|remove) ;; *) return 2 ;; esac
    status=$(fw_cmd firewall-cmd --state 2>/dev/null) || rc=$?
    if [[ $status != running || $rc != 0 ]]; then
        # Only a definite stopped daemon permits offline configuration.
        (( rc == 252 )) || return 2
        if [[ $scope == firewalld-runtime ]]; then
            case $action in query|query-remove) return 1 ;; remove) return 0 ;; *) return 2 ;; esac
        fi
        have firewall-offline-cmd || return 2
        cmd=(firewall-offline-cmd -q)
        opts=(); [[ -z $zone ]] || opts+=(--zone="$zone")
    fi
    if [[ $action == query-remove || $action == remove ]]; then
        rc=0
        fw_cmd "${cmd[@]}" "${opts[@]}" --query-port="$rule" >/dev/null 2>&1 || rc=$?
        # INVALID_ZONE means an explicitly recorded zone has already gone.
        if [[ -n $zone && $rc == 112 ]]; then rc=1; fi
        [[ $action != query-remove ]] || return "$rc"
        (( rc != 1 )) || return 0
        (( rc == 0 )) || return "$rc"
    fi
    rc=0
    fw_cmd "${cmd[@]}" "${opts[@]}" "--$action-port=$rule" 2>>"${STEP_LOG:-/dev/null}" || rc=$?
    if [[ $action == remove && -n $zone && $rc == 112 ]]; then return 0; fi
    return "$rc"
}

fw_has() {
    local first=0 second=0 v6=0
    case $1 in
        ufw)
            fw_ufw query ufw-v4 "$2" || first=$?
            fw_ufw_v6 || v6=$?
            case $v6 in
                0) fw_ufw query ufw-v6 "$2" || second=$? ;;
                1) ;;
                *) second=2 ;;
            esac ;;
        firewalld)
            fw_firewalld query firewalld-runtime "$2" || first=$?
            fw_firewalld query firewalld-permanent "$2" || second=$? ;;
        ufw-v4|ufw-v6) fw_ufw query "$1" "$2"; return $? ;;
        firewalld-runtime@*|firewalld-permanent@*) fw_firewalld query "$1" "$2"; return $? ;;
        *) return 2 ;;
    esac
    if [[ $1 == ufw ]] && (( first == 3 || second == 3 )); then return 3; fi
    if (( first > 1 || second > 1 )); then return 2; fi
    (( first == 0 && second == 0 ))
}

fw_add() {
    [[ $2 =~ ^[0-9]+/(tcp|udp)$ ]] && valid_port "${2%/*}" || return 1
    case $1 in
        ufw) fw_cmd ufw allow "$2" >/dev/null 2>>"${STEP_LOG:-/dev/null}" ;;
        ufw-v4|ufw-v6) fw_ufw add "$1" "$2" ;;
        firewalld)
            # Legacy metadata owned both scopes in the then-default zone.
            fw_firewalld add firewalld-permanent "$2" && fw_firewalld add firewalld-runtime "$2" ;;
        firewalld-runtime@*|firewalld-permanent@*) fw_firewalld add "$1" "$2" ;;
        *) return 1 ;;
    esac
}

fw_del() {
    [[ $2 =~ ^[0-9]+/(tcp|udp)$ ]] && valid_port "${2%/*}" || return 1
    case $1 in
        ufw)
            have ufw || { die '找不到 ufw 命令，无法核查旧规则。' '请恢复 UFW 管理工具后重试。'; return 1; }
            fw_cmd ufw --force delete allow "$2" >/dev/null 2>>"${STEP_LOG:-/dev/null}" || return 1 ;;
        ufw-v4|ufw-v6)
            have ufw || { die '找不到 ufw 命令，无法核查旧规则。' '请恢复 UFW 管理工具后重试。'; return 1; }
            fw_ufw remove "$1" "$2" || return 1 ;;
        firewalld)
            fw_firewalld remove firewalld-permanent "$2" && fw_firewalld remove firewalld-runtime "$2" || return 1 ;;
        firewalld-runtime@*|firewalld-permanent@*) fw_firewalld remove "$1" "$2" || return 1 ;;
        *) return 1 ;;
    esac
    return 0
}

fw_wanted() {
    public_ports | awk '{print $2 "/" $1}' | sort -t/ -k1,1n -k2,2 -u
}

fw_recorded() {
    jq -rs '
        if length != 1 then error("invalid state") else .[0].meta.fw_rules end
        | if . == null then [] else . end
        | if type == "array" and all(.[];
              type == "string" and (test("[[:cntrl:]]") | not)
              and test("^(ufw(-v[46])?|firewalld(-(runtime|permanent)@[A-Za-z0-9][A-Za-z0-9_.-]{0,63})?):[0-9]{1,5}/(tcp|udp)$")
              and (split(":")[1] | split("/")[0] | tonumber | . >= 1 and . <= 65535))
          then .[] else error("invalid firewall records") end' "$1"
}

fw_rule_scopes() {
    local kind=$1 zone status rc=0
    case $kind in
        ufw) printf '%s\n' ufw-v4 ufw-v6 ;;
        firewalld)
            status=$(fw_cmd firewall-cmd --state 2>/dev/null) || rc=$?
            if [[ $status == running && $rc == 0 ]]; then
                zone=$(fw_cmd firewall-cmd --get-default-zone) || return 1
            elif (( rc == 252 )) && have firewall-offline-cmd; then
                zone=$(fw_cmd firewall-offline-cmd --get-default-zone) || return 1
            else return 1; fi
            [[ $zone =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || return 1
            printf '%s\n' "firewalld-permanent@$zone" "firewalld-runtime@$zone" ;;
        ufw-v4|ufw-v6|firewalld-runtime@*|firewalld-permanent@*) printf '%s\n' "$kind" ;;
        *) return 1 ;;
    esac
}

fw_mutate() {
    local action=$1 kind=$2 rule=$3 expanded scope rc journal record check_only=0 restoring=0
    local -a parts=() changes=()
    case $action in
        add|remove) ;;
        check-remove) action=remove; check_only=1 ;;
        restore-add) action=add; restoring=1 ;;
        restore-remove) action=remove; restoring=1 ;;
        *) return 1 ;;
    esac
    [[ $rule =~ ^[0-9]+/(tcp|udp)$ ]] && valid_port "${rule%/*}" || return 1
    if [[ $action == remove ]]; then
        case $kind in
            ufw|ufw-v4|ufw-v6)
                have ufw || { die '找不到 ufw 命令，无法核查旧规则。' '请恢复 UFW 管理工具后重试。'; return 1; } ;;
            firewalld|firewalld-runtime@*|firewalld-permanent@*)
                if ! have firewall-cmd && ! have firewall-offline-cmd; then
                    die '找不到 firewalld 管理命令，无法核查旧规则。' '请恢复 firewalld 管理工具后重试。'; return 1
                fi ;;
        esac
    fi
    expanded=$(fw_rule_scopes "$kind") || { die '无法确定防火墙规则的作用域。'; return 1; }
    mapfile -t parts <<< "$expanded"
    # Query every part first: legacy records can span two independent scopes.
    for scope in "${parts[@]}"; do
        if [[ $scope == ufw-v6 ]]; then
            rc=0; fw_ufw_v6 || rc=$?
            if (( rc == 1 )); then
                if [[ $action == remove ]] || (( restoring )); then
                    rc=0; fw_ufw_saved_has ufw-v6 "$rule" 1 || rc=$?
                    # A write-ahead journal can describe a change that never ran.
                    if [[ $action == remove && $rc == 1 || $action == add && $rc == 0 ]]; then continue; fi
                    if (( rc > 1 )); then
                        die '无法核实 UFW 的 IPv6 持久规则，已保留恢复记录。' '请检查 /etc/ufw/user6.rules 后重试。'; return 1
                    fi
                fi
                die "UFW 的 IPv6 已禁用，无法调整规则 $rule。" '请在 /etc/default/ufw 中设置 IPV6=yes，再重试。'; return 1
            elif (( rc != 0 )); then die '无法读取 UFW 的 IPv6 设置。'; return 1; fi
        fi
        rc=0
        if [[ $action == remove && $scope == ufw-* ]]; then fw_ufw query-exact "$scope" "$rule" || rc=$?
        elif (( restoring )) && [[ $action == add && $scope == ufw-* ]]; then fw_ufw query-restore "$scope" "$rule" || rc=$?
        elif [[ $action == remove && $scope == firewalld-*@* ]]; then fw_firewalld query-remove "$scope" "$rule" || rc=$?
        else fw_has "$scope" "$rule" || rc=$?; fi
        if (( rc == 3 )) && [[ $scope == ufw* ]]; then
            if (( restoring )); then die "原 UFW 规则 $rule 与当前策略冲突，请核查后重试。"
            else die "端口 $rule 已有 UFW 拒绝或限速规则，请先手动调整。"; fi
            return 1
        fi
        (( rc <= 1 )) || { die "无法查询防火墙规则 $scope:$rule。"; return 1; }
        if [[ $action == add && $rc == 1 || $action == remove && $rc == 0 ]]; then changes+=("$scope"); fi
    done
    (( ! check_only )) || return 0
    (( ${#changes[@]} )) || return 0
    [[ -n $TX && -f $TX/ready ]] || { die '缺少防火墙恢复记录，已停止修改。'; return 1; }
    for scope in "${changes[@]}"; do
        record=$scope:$rule
        # Retain the first state if one transaction touches a rule repeatedly.
        if (( ! restoring )) && ! grep -Fxq -- "$record" "$TX/fw-added" 2>/dev/null && ! grep -Fxq -- "$record" "$TX/fw-removed" 2>/dev/null; then
            if [[ $action == add ]]; then journal=$TX/fw-added; else journal=$TX/fw-removed; fi
            printf '%s\n' "$record" >> "$journal" || { die '无法写入防火墙恢复记录，已停止修改。'; return 1; }
        fi
        if [[ $action == add ]]; then
            fw_add "$scope" "$rule" || { die "防火墙未能放行 $rule。"; return 1; }
        else
            fw_del "$scope" "$rule" || { die "防火墙未能删除 $rule，已保留恢复记录。"; return 1; }
        fi
    done
}

fw_sync() {
    local kind r scope zone='' rc records mode auto=0 v6_disabled=0
    local -a old=() keep=() want=() scopes=() split_old=()
    kind=$(fw_kind)
    records=$(fw_recorded "$DRAFT") || { die '无法读取托管的防火墙规则记录。'; return 1; }
    if [[ -n $records ]]; then mapfile -t old <<< "$records"; fi
    mode=$(jq -er '(if .firewall == null then "auto" else .firewall end)
        | select(. == "auto" or . == "off")' "$DRAFT") && [[ -n $mode ]] || { die '防火墙配置无效。'; return 1; }
    [[ $mode != auto ]] || auto=1
    if (( auto )) && [[ -z $kind ]]; then
        (( ${#old[@]} == 0 )) || ui_warn '未检测到可用的防火墙，已保留原规则记录。防火墙可用后请重新应用配置。'
        return 0
    fi
    if (( auto )); then
        records=$(fw_wanted) && [[ -n $records ]] || { die '无法读取对外端口，已停止修改防火墙。'; return 1; }
        mapfile -t want <<< "$records"
    fi
    if [[ $kind == ufw ]] || have ufw; then rc=0; fw_ufw_v6 || rc=$?; (( rc != 1 )) || v6_disabled=1; fi
    if (( v6_disabled )); then
        # Defer only IPv6; legacy records must not pin obsolete IPv4 rules.
        for r in "${old[@]}"; do
            [[ -n $r ]] || continue
            if [[ ${r%%:*} == ufw ]]; then
                for scope in ufw-v4 ufw-v6; do
                    in_list "$scope:${r#*:}" "${split_old[@]}" || split_old+=("$scope:${r#*:}")
                done
            else
                in_list "$r" "${split_old[@]}" || split_old+=("$r")
            fi
        done
        old=("${split_old[@]}")
    fi
    if [[ $kind == firewalld && ${#want[@]} -gt 0 ]]; then
        zone=$(fw_cmd firewall-cmd --get-default-zone) || { die '无法识别防火墙区域。'; return 1; }
        [[ $zone =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || { die '无法识别防火墙区域。'; return 1; }
        scopes=("firewalld-runtime@$zone" "firewalld-permanent@$zone")
    elif [[ $kind == ufw && ${#want[@]} -gt 0 ]]; then
        scopes=(ufw-v4)
        rc=0; fw_ufw_v6 || rc=$?
        case $rc in
            0) scopes+=(ufw-v6) ;;
            1) ;;
            *) die '无法读取 UFW 的 IPv6 设置，请检查 /etc/default/ufw。'; return 1 ;;
        esac
    elif [[ -n $kind ]]; then scopes=("$kind"); fi
    # Reject conflicts or query failures before changing any address family.
    for r in "${want[@]}"; do
        for scope in "${scopes[@]}"; do
            rc=0; fw_has "$scope" "$r" || rc=$?
            (( rc > 1 )) || continue
            if (( rc == 3 )) && [[ $scope == ufw* ]]; then
                die "端口 $r 已有 UFW 拒绝或限速规则，请先手动调整。"
            else die '无法查询防火墙规则，请检查防火墙状态。'; fi
            return 1
        done
    done
    for r in "${old[@]}"; do
        [[ -n $r ]] || continue
        scope=${r%%:*}
        if (( v6_disabled )) && [[ $scope == ufw-v6 ]]; then
            rc=0; fw_ufw_saved_has ufw-v6 "${r#*:}" 1 || rc=$?
            # Drop only ownership that a readable rules file proves absent.
            (( rc != 1 )) || continue
            keep+=("$r")
            if [[ $kind != ufw ]] || ! in_list "${r#*:}" "${want[@]}"; then
                ui_warn "已保留旧端口 ${r#*:} 的 UFW IPv6 规则。恢复 IPv6 后请重新应用配置。"
            fi
            continue
        fi
        if { [[ $scope == "$kind" ]] || in_list "$scope" "${scopes[@]}"; } && in_list "${r#*:}" "${want[@]}"; then
            rc=0; fw_has "$scope" "${r#*:}" || rc=$?
            if (( rc == 1 )); then fw_mutate add "$scope" "${r#*:}" || return 1
            elif (( rc == 3 )) && [[ $scope == ufw* ]]; then
                die "端口 ${r#*:} 已有 UFW 拒绝或限速规则，请先手动调整。"; return 1
            elif (( rc != 0 )); then die '无法查询防火墙规则，请检查防火墙状态。'; return 1; fi
            keep+=("$r")
            continue
        fi
        fw_mutate remove "$scope" "${r#*:}" || return 1
    done
    for r in "${want[@]}"; do
        for scope in "${scopes[@]}"; do
            in_list "$scope:$r" "${keep[@]}" && continue
            # Legacy records already own both firewalld scopes / UFW families.
            in_list "$kind:$r" "${keep[@]}" && continue
            rc=0
            fw_has "$scope" "$r" || rc=$?
            (( rc != 0 )) || continue
            if (( rc == 3 )) && [[ $scope == ufw* ]]; then
                die "端口 $r 已有 UFW 拒绝或限速规则，请先手动调整。"; return 1
            fi
            (( rc == 1 )) || { die '无法查询防火墙规则，请检查防火墙状态。'; return 1; }
            fw_mutate add "$scope" "$r" || return 1
            in_list "$kind:$r" "${keep[@]}" || keep+=("$scope:$r")
        done
    done
    records=$(printf '%s\n' "${keep[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))') || return 1
    st_set .meta.fw_rules "$records"
}

fw_undo_tx() {
    local r failed=0
    if [[ -s $TX/fw-added ]]; then
        while IFS= read -r r; do [[ -z $r ]] || fw_mutate restore-remove "${r%%:*}" "${r#*:}" || failed=1; done < "$TX/fw-added"
    fi
    if [[ -s $TX/fw-removed ]]; then
        # Restoring ALLOW must not overwrite an administrator's DENY/LIMIT.
        while IFS= read -r r; do [[ -z $r ]] || fw_mutate restore-add "${r%%:*}" "${r#*:}" || failed=1; done < "$TX/fw-removed"
    fi
    (( ! failed ))
}

fw_remove_recorded() {
    local r rules failed=0
    rules=$(fw_recorded "$1") || { die '无法读取托管的防火墙规则记录。'; return 1; }
    while IFS= read -r r; do
        [[ -n $r ]] || continue
        fw_mutate check-remove "${r%%:*}" "${r#*:}" || return 1
    done <<< "$rules"
    while IFS= read -r r; do
        [[ -n $r ]] || continue
        if fw_mutate remove "${r%%:*}" "${r#*:}"; then
            :
        else
            failed=1
            ui_warn "未能删除防火墙规则 $r。"
        fi
    done <<< "$rules"
    if (( failed )); then
        die '部分防火墙规则未能删除，卸载已中止。' '请检查防火墙状态后重试卸载。'
        return 1
    fi
    return 0
}

show_lock_holders() {
    local fd pid info tty state count=0
    for fd in /proc/[0-9]*/fd/9; do
        [[ $fd -ef $LOCK_FILE ]] || continue
        pid=${fd#/proc/}; pid=${pid%%/*}
        [[ $pid != "$BASHPID" ]] || continue
        # Another opener (including a waiter) need not own the flock.
        { grep -Eq '^lock:[[:space:]]+[0-9]+:[[:space:]]+FLOCK[[:space:]]+ADVISORY[[:space:]]+WRITE[[:space:]]' "/proc/$pid/fdinfo/9"; } 2>/dev/null || continue
        info=$(LC_ALL=C ps -p "$pid" -o tty= -o stat= 2>/dev/null) || continue
        read -r tty state <<< "$info"
        [[ $tty =~ ^[a-zA-Z0-9_./?-]+$ && -n $state ]] || continue
        case $state in T*) state='已暂停' ;; *) state='持锁' ;; esac
        ui_note "PID $pid  终端 $tty  $state"
        count=$((count + 1))
        (( count < 3 )) || break
    done
    if (( ! count )); then
        if have fuser; then ui_note "运行 fuser -v $LOCK_FILE 可查看打开锁文件的进程。"
        else ui_note '暂未查到持锁进程的详情。'; fi
    fi
}

acquire_lock() {
    local rc=0
    [[ $LOCK_OWNER != "$BASHPID" ]] || return 0
    if [[ -L $LOCK_FILE || ( -e $LOCK_FILE && ! -f $LOCK_FILE ) ]]; then
        fatal "锁文件路径异常：$LOCK_FILE"
    fi
    exec 9>> "$LOCK_FILE" || fatal "无法打开锁文件：$LOCK_FILE"
    # Wait briefly for a previous instance to finish its exit or rollback.
    flock -w 2 -E 42 9 || rc=$?
    case $rc in
        0)
            [[ ! -L $LOCK_FILE && /proc/$BASHPID/fd/9 -ef $LOCK_FILE ]] || fatal '管理锁路径已变化，请重新打开。'
            LOCK_OWNER=$BASHPID ;;
        42)
            exec 9>&-
            [[ ${1:-} != draft ]] || return 42
            ui_err '管理锁仍被占用。'
            {
                show_lock_holders
                ui_note '若旧菜单已暂停，请回原终端运行 jobs -l，用 fg %作业号 恢复后退出菜单。'
                ui_note '若安装、更新或回滚仍在进行，请等它结束后重试。'
            } 4>&5
            exit 42 ;;
        *) fatal "无法取得管理锁（flock 退出码 $rc）：$LOCK_FILE" ;;
    esac
}


release_lock() {
    [[ $LOCK_OWNER == "$BASHPID" ]] || return 0
    (( ! TX_ACTIVE )) || { die '事务尚未结束，无法释放管理锁。'; return 1; }
    flock -u 9 || { die '释放管理锁失败。'; return 1; }
    exec 9>&-
    LOCK_OWNER=''
}

# Compare only deployment inputs. Updating the homepage cache must not stale an editor.
draft_generation() {
    local f presence='' LC_ALL=C TZ=UTC
    local -a files=()
    export LC_ALL TZ
    for f in "$STATE" "$DATA_DIR/state.prev.json" "$SNI_POOL_FILE" "$CONFIG_FILE" "$SS_CONFIG" "$SS_ACL" \
        "$NGINX_DIR/nginx.conf" "$CORE_BIN" "$SS_BIN" "$PUBLIC_XRAY" "$SELF_SCRIPT_PATH" "$QUICK_BIN" \
        "$SYSTEMD_DIR/xray.service" "$SYSTEMD_DIR/zxray-ss.service" "$SYSTEMD_DIR/zxray-nginx.service" \
        "$ROOT/etc/logrotate.d/zxray" "$SYSCTL_FILE" "$DATA_DIR/bbr-original.json" "$XRAY_ASSET_DIR/"{geoip.dat,geosite.dat,.zxray-full-geo} \
        "$NODES_JSON" "$INFO_FILE" "$SUB_FILE" "$SUB_B64"; do
        if [[ -e $f || -L $f ]]; then
            if [[ ! -f $f && ! -L $f ]]; then
                printf '部署文件类型异常：%s\n' "$f" >&2
                return 1
            fi
            presence+=1
            files+=("$f")
        else
            presence+=0
        fi
    done
    printf '%s\n' "$presence"
    (( ${#files[@]} == 0 )) || stat -c '%d:%i:%s:%z' -- "${files[@]}"
}

pause_draft_lock() {
    [[ -z $DRAFT_GENERATION ]] || return 0
    [[ $LOCK_OWNER == "$BASHPID" ]] || return 1
    DRAFT_GENERATION=$(draft_generation) || { die '无法核对当前配置文件。'; return 1; }
    release_lock
}

resume_draft_lock() {
    local generation rc
    if [[ -z $DRAFT_GENERATION ]]; then [[ $LOCK_OWNER == "$BASHPID" ]]; return; fi
    if (( ! ASSUME_YES )) && input_is_tty; then
        while :; do
            rc=0; acquire_lock draft || rc=$?
            (( rc == 42 )) || break
            ask_yes '另一项操作正在进行。保留当前选择并重试' || exit "$RC_QUIET"
        done
        (( rc == 0 )) || return "$rc"
    else
        acquire_lock
    fi
    check_private_dirs || return 1
    if [[ -e $TX || -L $TX ]] || ! generation=$(draft_generation) || [[ $generation != "$DRAFT_GENERATION" ]]; then
        die '部署已变化或无法核实。请回到主页，重新打开此操作。'
        return 1
    fi
    verify_running_script || return 1
    select_core_path
    DRAFT_GENERATION=''
}

svc_state_line() {
    # Keep failures in the shell that owns the current step and spinner.
    local -n state_out=$1
    state_out=''
    shift
    local detail='' s=$1 purpose=${2:-snapshot} op a=0 e=0 rc=0 data key value id='' load='' active='' enabled='' seen=0
    case $purpose in
        snapshot|repair) op='备份服务状态' ;;
        verify) op='核对恢复结果' ;;
        stop) op='停止服务' ;;
        package) op='检查软件包占用' ;;
        update) op='检查更新前的服务状态' ;;
        *) die "未知的服务状态查询用途：$purpose。"; return 1 ;;
    esac
    data=$(timeout -k 2 5 systemctl show "$s" --all -p Id -p LoadState -p ActiveState -p UnitFileState 2>>"${STEP_LOG:-/dev/null}") || rc=$?
    (( rc == 0 || rc == 4 )) || {
        die "无法$op：查询 $s 失败或超时。"; return 1;
    }
    while IFS='=' read -r key value; do
        case $key in
            Id) (( (seen & 8) == 0 )) || break; id=$value; seen=$((seen | 8)) ;;
            LoadState) (( (seen & 1) == 0 )) || break; load=$value; seen=$((seen | 1)) ;;
            ActiveState) (( (seen & 2) == 0 )) || break; active=$value; seen=$((seen | 2)) ;;
            UnitFileState) (( (seen & 4) == 0 )) || break; enabled=$value; seen=$((seen | 4)) ;;
            *) break ;;
        esac
        key=''
    done <<< "$data"
    [[ $seen == 15 && -z $key && -n $id ]] || { die "无法$op：服务 $s 的状态信息不完整。"; return 1; }
    # A query by alias can report the canonical unit's own enablement.
    [[ $id == "$s.service" ]] || { die "无法$op：$s 实际指向 $id。"; return 1; }
    if [[ $load == not-found && $active == inactive && -z $enabled ]]; then return 0; fi
    (( rc == 0 )) || { die "无法$op：服务 $s 的查询结果与退出状态不一致。"; return 1; }
    case $load in
        loaded|masked) ;;
        bad-setting|error)
            [[ $purpose != package ]] || return 1
            if [[ $purpose != stop ]]; then
                if [[ $purpose != repair && ! ( $purpose == verify && ${3:-1} == 0 ) ]]; then
                    svc_fail "$s" "无法$op：服务 $s 加载异常（$load）。"; return 1
                fi
                case $enabled in
                    enabled|disabled|static) ;;
                    *) svc_fail "$s" "无法$op：损坏单元 $s 的启用方式无法原样恢复（${enabled:-未知}）。"; return 1 ;;
                esac
                svc_broken_idle "$s" "$load" "$active" "$enabled" detail || {
                    svc_fail "$s" "无法$op：未能确认损坏单元 $s 已停止且没有待执行作业。" ${detail:+"$detail"}; return 1;
                }
            fi ;;
        *) die "无法$op：服务 $s 的加载状态为 ${load:-未知}。"; return 1 ;;
    esac
    case $active in
        active|reloading) a=1 ;;
        inactive|failed) a=0 ;;
        activating|deactivating|refreshing|maintenance)
            if [[ $purpose == stop ]]; then a=1
            else die "无法$op：服务 $s 正在切换状态，请稍后重试。"; return 1; fi ;;
        *) die "无法$op：服务 $s 的运行状态为 ${active:-未知}。"; return 1 ;;
    esac
    if [[ $purpose == package || $purpose == update ]]; then
        # Only the caller's explicit list of idle, unconfigured states permits a purge.
        state_out="$s $a $enabled"
        return
    fi
    if [[ ( $purpose == snapshot || $purpose == repair ) && $a == 1 && ( $load == masked || $enabled == masked || $enabled == masked-runtime ) ]]; then
        die "服务 $s 已屏蔽但仍在运行，回滚时无法重启。请按需解除屏蔽或停止服务，再重试。"; return 1
    fi
    case $enabled in
        enabled) e=1 ;;
        enabled-runtime)
            if [[ $purpose == snapshot || $purpose == repair ]]; then
                die "服务 $s 仅临时启用（enabled-runtime），快照无法还原此状态。请按需设置为长期启用或停用，再重试。"; return 1
            fi
            e=runtime ;;
        disabled|static|masked|masked-runtime|indirect|generated|transient|linked|linked-runtime) e=0 ;;
        alias) die "无法$op：$s 是其他单元的别名。"; return 1 ;;
        bad|'')
            if [[ $purpose == stop && ( $load == bad-setting || $load == error ) ]]; then
                e=unknown
            elif [[ $purpose == stop && $IN_ROLLBACK == 1 && $load == loaded && -z $enabled ]] &&
                in_list "$s" "${MANAGED_SERVICES[@]}" && [[ -f $TX/ready && ! -L $TX/ready &&
                ! -e $SYSTEMD_DIR/$s.service && ! -L $SYSTEMD_DIR/$s.service ]]; then
                # The transaction removed this unit on disk, but systemd may still cache it until reload.
                local fragment
                fragment=$(timeout -k 2 5 systemctl show "$s" -p FragmentPath --value 2>>"${STEP_LOG:-/dev/null}") &&
                    [[ $fragment == "$SYSTEMD_DIR/$s.service" ]] || { die "无法核实缓存单元 $s 的归属。"; return 1; }
                e=removed
            else
                die "无法$op：服务 $s 的启动方式为 ${enabled:-未知}。"; return 1
            fi ;;
        *) die "无法$op：服务 $s 的启动方式为 $enabled。"; return 1 ;;
    esac
    if [[ $purpose == stop && $a == 0 && ( $load == bad-setting || $load == error ) ]]; then
        state_out="$s $a $e $load $active $enabled"
    else
        state_out="$s $a $e"
    fi
}

# Preserve command paths already occupied by another installer.
foreign_command_at() {
    [[ -e $1 || -L $1 ]] || return 1
    case $1 in
        "$QUICK_BIN") ! is_manager_launcher "$1" ;;
        "$PUBLIC_XRAY") (( ! LEGACY_CORE_OWNED )) && ! is_core_link && ! is_manager_launcher "$1" ;;
        *) return 1 ;;
    esac
}

# Standard Xray directories may contain another instance's configs and assets.
tx_shared_xray_dir() (
    local action=$1 dir=$2 backup=$3 manifest=$4 file src dest mask='' expected mode owner left item=0
    local -a files=()
    case $dir in
        "$CONFIG_DIR") files=(config.json) ;;
        "$XRAY_ASSET_DIR") files=(geoip.dat geosite.dat .zxray-full-geo) ;;
        *) return 1 ;;
    esac
    [[ ! -L $dir && ( ! -e $dir || -d $dir ) ]] || { ui_err "共享目录路径冲突：$dir"; return 1; }
    if [[ $action == save ]]; then
        mkdir -m 700 -- "$backup" || return 1
        for file in "${files[@]}"; do
            src=$dir/$file
            if [[ -L $src || -f $src ]]; then cp -a -- "$src" "$backup/$file" || return 1; mask+=1
            elif [[ ! -e $src ]]; then mask+=0
            else ui_err "托管文件位置出现目录或特殊文件：$src"; return 1; fi
        done
        owner=$(stat -c '%u:%g' -- "$dir") && mode=$(stat -c %a -- "$dir") || return 1
        printf '%s %s %s\n' "$mask" "$owner" "$mode" > "$manifest"
        return
    fi
    if [[ -e $backup || -L $backup ]]; then
        [[ ! -L $backup && -d $backup && ! -L $manifest && -f $manifest ]] || return 1
        read -r expected owner mode < "$manifest" || return 1
        [[ $owner =~ ^[0-9]+:[0-9]+$ && $mode =~ ^[0-7]{1,4}$ ]] || return 1
    else
        [[ ! -e $manifest && ! -L $manifest ]] || return 1
        expected=$(printf '%0*d' "${#files[@]}" 0)
    fi
    for file in "${files[@]}"; do
        src=$backup/$file dest=$dir/$file
        if [[ -L $src || -f $src ]]; then mask+=1
        elif [[ ! -e $src ]]; then mask+=0
        else return 1; fi
        if [[ -L $dest ]]; then
            [[ -L $src ]] && cmp -s <(readlink -- "$src") <(readlink -- "$dest") || {
                ui_err "托管文件位置出现其他符号链接：$dest"; return 1;
            }
        elif [[ -e $dest && ! -f $dest ]]; then
            ui_err "托管文件位置出现目录或特殊文件：$dest"; return 1
        fi
    done
    [[ $mask == "$expected" ]] || { ui_err "共享目录的快照文件不完整：$dir"; return 1; }
    [[ $action == restore ]] || return 0
    if [[ -d $backup ]]; then
        (umask 077 && mkdir -p -- "$dir") || return 1
    elif [[ ! -d $dir ]]; then return 0; fi
    for file in "${files[@]}"; do
        src=$backup/$file dest=$dir/$file
        tx_restore_file "$src" "$dest" "${backup##*/}-$item" || return 1
        item=$(( item + 1 ))
    done
    if [[ -d $backup ]]; then
        chown -- "$owner" "$dir" && chmod -- "$mode" "$dir" || return 1
    elif ! rmdir -- "$dir" 2>/dev/null; then
        for left in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do [[ -e $left || -L $left ]] && return 0; done
        return 1
    fi
)

tx_begin() {
    check_service_ownership || return 1
    if [[ -e $TX || -L $TX ]]; then
        die '上次操作未完成。请重新运行脚本并恢复快照。' "快照目录：$TX"
        return 1
    fi
    check_transaction_mounts "$DATA_DIR" "$SELF_DIR" "$NGINX_RUN" || return 1
    local i p s c purpose=${1:-snapshot}
    local -a service_records=() backed_up=()
    # Collect state before creating a recoverable transaction. Query failures
    # must not silently turn a running/enabled service into an absent one.
    for s in "${MANAGED_SERVICES[@]}"; do
        svc_state_line c "$s" "$purpose" || return 1
        [[ -z $c ]] || service_records+=("$c")
    done
    # Publish a complete ownership marker with a single rename. Both
    # paths share the staging filesystem. A crash before the rename leaves TX empty.
    printf '%s\n' "$MANAGED_TAG" > "$STAGE/tx-owner" || return 1
    mkdir -m 700 -- "$TX" || return 1
    mv -fT -- "$STAGE/tx-owner" "$TX/owner" || return 1
    mkdir -m 700 -- "$TX/backup" || return 1
    : > "$TX/created-dirs" || return 1
    printf '%s\n' "${MANAGED_PATHS[@]}" > "$TX/paths" || return 1
    for i in "${!MANAGED_PATHS[@]}"; do
        p=${MANAGED_PATHS[$i]}
        backed_up[$i]=0
        # A separate installer may also populate an empty command slot mid-update.
        if [[ $p == "$QUICK_BIN" || ( $p == "$PUBLIC_XRAY" && $LEGACY_CORE_OWNED == 0 ) ]]; then
            : > "$TX/check-command-$i" || return 1
            foreign_command_at "$p" && continue
        fi
        if [[ -e $p || -L $p ]]; then
            if [[ $p == "$CONFIG_DIR" || $p == "$XRAY_ASSET_DIR" ]]; then
                tx_shared_xray_dir save "$p" "$TX/backup/$i" "$TX/shared-$i" || return 1
            else
                if [[ $p != "$DATA_DIR" && $p != "$SELF_DIR" && ! -L $p && ! -f $p ]]; then
                    die "托管路径应为普通文件或符号链接：$p"; return 1
                fi
                cp -a -- "$p" "$TX/backup/$i" || return 1
            fi
            backed_up[$i]=1
        fi
    done
    : > "$TX/services" || return 1
    for c in "${service_records[@]}"; do printf '%s\n' "$c" >> "$TX/services" || return 1; done
    # tx_snapshot_sysctl records these lazily before configure/restore changes them.
    : > "$TX/cc" || return 1
    : > "$TX/qdisc" || return 1
    : > "$TX/new-packages" || return 1
    printf 'systemd\n' > "$TX/init" || return 1
    printf '%s\n' "${backed_up[@]}" > "$TX/backup-map" || return 1
    printf '%s\n' 'backup-map-v2' | atomic_write "$TX/ready" 600 || return 1
    TX_ACTIVE=1
}

tx_systemd_snapshot() {
    [[ ! -L $TX/init && -f $TX/init ]] && cmp -s -- "$TX/init" <(printf 'systemd\n')
}

tx_load_paths() {
    local -n result=$1
    [[ ! -L $TX/paths && -f $TX/paths ]] || return 1
    result=("${MANAGED_PATHS[@]}")
    if cmp -s -- "$TX/paths" <(printf '%s\n' "${result[@]}"); then return 0; fi
    # The last three backup indices were 11–13 in 0.2.x.
    result=("${MANAGED_PATHS[@]:0:8}" "$ROOT/etc/init.d/xray" "$ROOT/etc/init.d/zxray-ss"
        "$ROOT/etc/init.d/zxray-nginx" "${MANAGED_PATHS[@]:8}")
    cmp -s -- "$TX/paths" <(printf '%s\n' "${result[@]}")
}

tx_retired_file_matches() {
    local file=$1 backup=$2 saved current
    [[ ! -L $ROOT/etc && ! -L $ROOT/etc/init.d ]] || return 1
    saved=$(stat -c '%u:%g:%a' -- "$backup") && current=$(stat -c '%u:%g:%a' -- "$file" 2>/dev/null) &&
        [[ $saved == "$current" ]] || return 1
    if [[ -L $backup && -L $file ]]; then
        saved=$(readlink -- "$backup" && printf x) && current=$(readlink -- "$file" && printf x) &&
            [[ $saved == "$current" ]]
    else
        [[ ! -L $backup && -f $backup && ! -L $file && -f $file ]] && cmp -s -- "$backup" "$file"
    fi
}

tx_check_retired_backups() {
    local file i=8
    [[ -e $TX/backup || -L $TX/backup ]] || return 0
    [[ -d $TX/backup && ! -L $TX/backup ]] || return 1
    for file in "$@"; do
        if [[ -e $TX/backup/$i || -L $TX/backup/$i ]] && ! tx_retired_file_matches "$file" "$TX/backup/$i"; then
            ui_err "旧快照与当前文件不一致：$file"
            ui_note "备份位于 $TX/backup/$i。请核实原文件，恢复后再重试。"; return 1
        fi
        i=$((i + 1))
    done
}

tx_discard_incomplete() {
    local old_layout=0 p mode
    local -a paths=()
    [[ -e $TX || -L $TX ]] || return 0
    [[ -d $TX && ! -L $TX && ! -e $TX/ready && ! -L $TX/ready ]] || return 1
    check_transaction_mounts "$TX" || return 1
    if [[ -e $TX/init || -L $TX/init ]]; then
        [[ ! -L $TX/init && -f $TX/init ]] && { [[ ! -s $TX/init ]] || tx_systemd_snapshot; } || return 1
    fi
    if tx_load_paths paths && (( ${#paths[@]} != ${#MANAGED_PATHS[@]} )); then
        old_layout=1
        tx_check_retired_backups "${paths[@]:8:3}" || return 1
    fi
    if [[ ! -f $TX/owner || -L $TX/owner || $(cat -- "$TX/owner") != "$MANAGED_TAG" ]]; then
        # Before 0.2.9 an unfinished backup had no owner marker. Its path list identifies it.
        if (( old_layout )) && [[ -d $TX/backup && ! -L $TX/backup ]]; then
            printf '%s\n' "$MANAGED_TAG" | atomic_write "$TX/owner" 600 || return 1
        elif [[ -O $TX && -f $TX/owner && ! -L $TX/owner && ! -s $TX/owner ]] &&
            [[ $(stat -c '%u:%a:%h' -- "$TX/owner") == "$EUID:600:1" ]]; then
            # Old versions could die after opening owner but before writing its tag.
            # Only the exact layout before backup starts qualifies for this repair.
            mode=$(stat -c %a -- "$TX") && [[ $mode == 700 || $mode == 2700 ]] || return 1
            for p in "$TX"/* "$TX"/.[!.]* "$TX"/..?*; do
                [[ $p == "$TX/owner" || ( ! -e $p && ! -L $p ) ]] || return 1
            done
            rm -f -- "$TX/owner" && rmdir -- "$TX"; return
        else
            rmdir -- "$TX" 2>/dev/null; return
        fi
    fi
    # Keep owner until the last child is gone, including after an interrupted cleanup.
    for p in "$TX"/* "$TX"/.[!.]* "$TX"/..?*; do
        [[ $p != "$TX/owner" && ( -e $p || -L $p ) ]] || continue
        rm -rf -- "$p" || return 1
    done
    rm -f -- "$TX/owner" && rmdir -- "$TX"
}

check_transaction_mounts() {
    local dir encoded mount seen=0
    local -a dirs=()
    for dir in "$@"; do
        [[ ! -L $dir && -d $dir ]] || continue
        dir=$(cd -P -- "$dir" && pwd -P) || return 1
        dirs+=("$dir")
    done
    (( ${#dirs[@]} )) || return 0
    while read -r _ _ _ _ encoded _; do
        seen=1
        # mountinfo uses exactly three octal digits. Decode the backslash last.
        mount=${encoded//\\040/$' '}
        mount=${mount//\\011/$'\t'}
        mount=${mount//\\012/$'\n'}
        mount=${mount//\\134/$'\\'}
        for dir in "${dirs[@]}"; do
            if [[ $mount == "$dir" || $mount == "$dir/"* ]]; then
                die "托管目录中存在挂载点：$mount" '确认该挂载点可以卸载后，请卸载并重试。'; return 1
            fi
        done
    done < /proc/self/mountinfo || return 1
    (( seen )) || { die '无法确认托管目录的挂载状态。'; return 1; }
}

# Publish a complete file in one rename. A partial unit or launcher could
# otherwise be classified as foreign on the next recovery attempt.
tx_restore_file() (
    local backup=$1 dest=$2 parent=${2%/*} slot=${3:-${1##*/}} tmp reservation name saved='' identity
    local -a entries=()
    [[ $slot =~ ^[0-9]+(-[0-9]+)?$ ]] || return 1
    if [[ ! -e $backup && ! -L $backup ]]; then rm -f -- "$dest"; return; fi
    (umask 022 && mkdir -p -- "$parent") || return 1
    # Reserve this exact sibling before creating it. A retry can remove a
    # partial copy even when /etc or /usr/local is on a separate filesystem.
    reservation=$TX/restore-file-$slot
    if [[ -e $reservation || -L $reservation ]]; then
        [[ -f $reservation && ! -L $reservation ]] && read -r name saved < "$reservation" || return 1
        [[ $name =~ ^[.]zxray-restore[.][A-Za-z0-9]{12}$ && ( -z $saved || $saved =~ ^[0-9]+:[0-9]+$ ) ]] || return 1
    else
        name=$(mktemp -- "$TX/.zxray-restore.XXXXXXXXXXXX") || return 1
        name=${name##*/}
        [[ ! -e $parent/$name && ! -L $parent/$name ]] || return 1
        printf '%s\n' "$name" | atomic_write "$reservation" 600 || return 1
    fi
    tmp=$parent/$name
    if [[ ! -e $tmp && ! -L $tmp ]]; then
        if [[ -n $saved ]]; then
            printf '%s\n' "$name" | atomic_write "$reservation" 600 || return 1
            saved=''
        fi
        mkdir -m 700 -- "$tmp" || return 1
    fi
    [[ ! -L $tmp && -d $tmp && -O $tmp && $(stat -c %a -- "$tmp") =~ ^2?700$ ]] || return 1
    identity=$(stat -c '%d:%i' -- "$tmp") || return 1
    if [[ -z $saved ]]; then
        shopt -s nullglob dotglob
        entries=("$tmp"/*)
        (( ${#entries[@]} == 0 )) || return 1
        printf '%s %s\n' "$name" "$identity" | atomic_write "$reservation" 600 || return 1
    else
        [[ $saved == "$identity" ]] || return 1
    fi
    rm -f -- "$tmp/file" && cp -a -- "$backup" "$tmp/file" &&
        mv -fT -- "$tmp/file" "$dest" && rmdir -- "$tmp"
)

tx_rollback() {
    local IN_ROLLBACK=1
    if [[ ! -f $TX/ready || -L $TX/ready ]]; then
        tx_discard_incomplete || { KEEP_TX=1; ui_err "无法识别事务目录，已保留：$TX"; return 1; }
        TX_ACTIVE=0
        return 0
    fi
    ui_warn '正在恢复到操作前的状态…'
    local i p s active enabled current_state format=backup-map-v2 failed=0 shared_layout=0
    local -a paths=() backed_up=()
    [[ ! -L $TX/ready && -f $TX/paths && -s $TX/paths && ! -L $TX/paths && -f $TX/services &&
        ! -L $TX/services && -d $TX/backup && ! -L $TX/backup ]] || { KEEP_TX=1; ui_err '快照记录不完整，已停止恢复。'; return 1; }
    tx_systemd_snapshot || { KEEP_TX=1; ui_err '无法确认快照使用 systemd，恢复已停止。'; return 1; }
    tx_load_paths paths || { KEEP_TX=1; ui_err '快照路径或顺序不符，已停止恢复。'; return 1; }
    if (( ${#paths[@]} != ${#MANAGED_PATHS[@]} )); then
        format=backup-map-v1
        # Keep the original slot numbers without restoring retired files.
        tx_check_retired_backups "${paths[@]:8:3}" || { KEEP_TX=1; return 1; }
        paths[8]=''; paths[9]=''; paths[10]=''
        [[ ! -L $TX/caps && -f $TX/caps && ! -s $TX/caps ]] || {
            KEEP_TX=1; ui_err '旧快照的核心权限记录异常，已停止恢复。'; return 1
        }
    elif [[ -e $TX/caps || -L $TX/caps ]]; then
        KEEP_TX=1; ui_err '快照含有非预期的核心权限记录，已停止恢复。'; return 1
    fi
    # Old snapshots used an empty ready file. New ones distinguish missing backups from originally absent paths.
    if [[ $format == backup-map-v2 || -s $TX/ready || -e $TX/backup-map || -L $TX/backup-map ]]; then
        shared_layout=1
        for p in cc qdisc new-packages created-dirs; do
            [[ ! -L $TX/$p && -f $TX/$p ]] || { KEEP_TX=1; ui_err "快照缺少有效记录：$p"; return 1; }
        done
        if ! cmp -s -- "$TX/ready" <(printf '%s\n' "$format") || [[ ! -f $TX/backup-map || -L $TX/backup-map ]] ||
            ! mapfile -t backed_up < "$TX/backup-map" || (( ${#backed_up[@]} != ${#paths[@]} )); then
            KEEP_TX=1; ui_err '无法核实快照文件清单，已停止恢复。'; return 1
        fi
        for i in "${!paths[@]}"; do
            if [[ -e $TX/backup/$i || -L $TX/backup/$i ]]; then p=1; else p=0; fi
            [[ ${backed_up[$i]} == "$p" ]] || { KEEP_TX=1; ui_err "快照与清单不符（第 $i 项），已停止恢复。"; return 1; }
            if [[ ${paths[$i]} == "$CONFIG_DIR" || ${paths[$i]} == "$XRAY_ASSET_DIR" ]]; then
                tx_shared_xray_dir check "${paths[$i]}" "$TX/backup/$i" "$TX/shared-$i" || {
                    KEEP_TX=1; ui_err "无法核实共享目录快照：${paths[$i]}。"; return 1;
                }
            fi
        done
    elif [[ -e $TX/shared-2 || -L $TX/shared-2 || -e $TX/shared-4 || -L $TX/shared-4 ]]; then
        KEEP_TX=1; ui_err '共享目录快照缺少文件清单，已停止恢复。'; return 1
    fi
    local -a recursive=("$DATA_DIR" "$SELF_DIR" "$TX" "$NGINX_RUN")
    if (( ! shared_layout )); then recursive+=("$CONFIG_DIR" "$XRAY_ASSET_DIR"); fi
    check_transaction_mounts "${recursive[@]}" || { KEEP_TX=1; return 1; }
    for i in "${!paths[@]}"; do
        p=${paths[$i]}
        [[ -n $p ]] || continue
        if [[ -f $TX/check-command-$i ]] && foreign_command_at "$p"; then continue; fi
        case $p in "$DATA_DIR"|"$SELF_DIR"|"$CONFIG_DIR"|"$XRAY_ASSET_DIR") continue ;; esac
        if [[ ! -L $p && -e $p && ! -f $p ]]; then
            KEEP_TX=1; ui_err "托管路径应为普通文件或符号链接：$p"; return 1
        fi
        if [[ ! -L $TX/backup/$i && -e $TX/backup/$i && ! -f $TX/backup/$i ]]; then
            KEEP_TX=1; ui_err "快照文件类型异常（第 $i 项）：$p"; return 1
        fi
    done
    while read -r s active enabled; do
        [[ -n $s ]] || continue
        if ! in_list "$s" "${MANAGED_SERVICES[@]}" || [[ $active != [01] || $enabled != [01] ]]; then
            KEEP_TX=1; ui_err '快照服务记录异常，已停止恢复。'; return 1
        fi
    done < "$TX/services"
    stop_owned_services || { KEEP_TX=1; return 1; }
    for i in "${!paths[@]}"; do
        p=${paths[$i]}
        [[ -n $p ]] || continue
        if (( shared_layout )) && [[ $p == "$CONFIG_DIR" || $p == "$XRAY_ASSET_DIR" ]]; then
            tx_shared_xray_dir restore "$p" "$TX/backup/$i" "$TX/shared-$i" || failed=1
            continue
        fi
        if [[ -f $TX/check-command-$i ]] && foreign_command_at "$p"; then
            if [[ -e $TX/backup/$i || -L $TX/backup/$i ]]; then
                ui_warn "$p 已被其他程序占用。请移走冲突文件后重试恢复。"
                failed=1
            fi
            continue
        fi
        case $p in
            "$DATA_DIR"|"$SELF_DIR"|"$CONFIG_DIR"|"$XRAY_ASSET_DIR") ;;
            *) tx_restore_file "$TX/backup/$i" "$p" || failed=1; continue ;;
        esac
        rm -rf -- "$p" || { failed=1; continue; }
        if [[ -e $TX/backup/$i || -L $TX/backup/$i ]]; then
            (umask 022 && mkdir -p -- "$(dirname -- "$p")") || { failed=1; continue; }
            cp -a -- "$TX/backup/$i" "$p" || failed=1
        fi
    done
    select_core_path
    if [[ -f $TX/nginx-masked ]]; then
        if timeout -k 2 15 systemctl unmask nginx >/dev/null 2>&1; then rm -f -- "$TX/nginx-masked"
        else failed=1; fi
    fi
    local receipt=''
    if [[ -f $TX/pkgs-before ]]; then
        # Older snapshots have no dpkg receipt. A database difference alone is unsafe.
        record_nginx_install receipt || { receipt=''; ui_warn '安装记录不完整，仅回收已确认由本次操作新增的软件包。'; }
    fi
    if [[ -s $TX/new-packages ]]; then
        local -a pkgs=() removable=()
        mapfile -t pkgs < "$TX/new-packages"
        for p in "${pkgs[@]}"; do
            if [[ -f $TX/shared-nginx && $p == *nginx* ]]; then
                ui_note "保留系统 Nginx 模块：$p"
            else
                removable+=("$p")
            fi
        done
        # Shared dependencies may legitimately remain; restoring service files
        # must not be retried forever solely because their packages were kept.
        if ! pkg_remove_safe --rollback "${removable[@]}" >/dev/null 2>&1; then
            if pkg_rollback_partial "$receipt" "${removable[@]}" >/dev/null 2>&1; then
                pkg_remove_safe --rollback "${removable[@]}" >/dev/null 2>&1 || true
            fi
            pkg_report_retained "${removable[@]}"
        fi
    fi
    if [[ ! -s $TX/services && ( -f $TX/created-user || -f $TX/created-group ) ]]; then
        remove_service_user || failed=1
    fi
    if ! svc_reload_units || ! check_service_ownership; then failed=1; fi
    if [[ -s $TX/cc ]]; then restore_sysctl_value net.ipv4.tcp_congestion_control "$(cat "$TX/cc")" || failed=1; fi
    if [[ -s $TX/qdisc ]]; then restore_sysctl_value net.core.default_qdisc "$(cat "$TX/qdisc")" || failed=1; fi
    fw_undo_tx || failed=1
    while read -r s active enabled; do
        # Keep services stopped if the binaries, configuration or rules are still incomplete.
        (( ! failed )) || break
        [[ -n $s ]] || continue
        if ! in_list "$s" "${MANAGED_SERVICES[@]}" || [[ $active != [01] || $enabled != [01] ]]; then failed=1; continue; fi
        # Reload can change which unit a name resolves to, including on a legacy snapshot.
        svc_state_line current_state "$s" verify "$active" || { failed=1; break; }
        if [[ -z $current_state ]]; then
            ui_err "恢复后的服务 $s 不存在。"; failed=1; break
        fi
        if [[ $enabled == 0 && $current_state != "$s "[01]' 0' ]]; then
            ui_err "服务 $s 的启用状态与快照不符。"; failed=1; break
        fi
        if [[ $enabled == 1 && $current_state != "$s "[01]' 1' ]]; then
            svc_do enable "$s" >/dev/null 2>&1 || {
                svc_fail "$s" "恢复服务 $s 的开机自启失败。" || failed=1; break
            }
            svc_state_line current_state "$s" verify "$active" || { failed=1; break; }
            if [[ $current_state != "$s "[01]' 1' ]]; then
                ui_err "恢复后未能确认服务 $s 已启用开机自启。"; failed=1; break
            fi
        fi
        if [[ $active == 1 ]]; then
            svc_do start "$s" >/dev/null 2>&1 || {
                svc_fail "$s" "恢复服务 $s 的运行状态失败。" || failed=1; break
            }
            svc_state_line current_state "$s" verify || { failed=1; break; }
        fi
        if [[ $current_state != "$s $active $enabled" ]]; then
            ui_err "服务 $s 的运行或自启状态与快照不符。"; failed=1; break
        fi
    done < "$TX/services"
    if [[ -s $TX/created-dirs ]]; then remove_created_dirs < "$TX/created-dirs"; fi
    if (( failed )); then
        KEEP_TX=1
        ui_err '恢复未完成。请保留快照，重新运行脚本重试。'
        ui_note "快照目录：$TX"
        return 1
    fi
    tx_finish || return 1
    ui_line '已恢复到操作前的状态。'
}

tx_finish() {
    # Removing ready is the commit point. After this point cleanup must not undo the restored/committed state.
    rm -f -- "$TX/ready" || { KEEP_TX=1; ui_err "无法移除事务标记，恢复快照已保留：$TX"; return 1; }
    TX_ACTIVE=0
    tx_discard_incomplete || { ui_err "文件处理已完成。重新运行脚本可重试清理事务目录：$TX"; return 1; }
}

tx_commit() { tx_finish; }

tx_recover_if_needed() {
    local running_digest='' marker
    [[ -e $TX || -L $TX ]] || return 0
    [[ ! -L $TX && -d $TX ]] || fatal "事务路径不是普通目录，无法安全恢复：$TX"
    if [[ ! -f $TX/ready || -L $TX/ready ]]; then
        tx_discard_incomplete || fatal "无法清理事务目录。请保留并检查 $TX。"
        return 0
    fi
    tx_systemd_snapshot || fatal "无法确认快照使用 systemd，请检查 $TX。"
    # Keep a reference to this exact ready marker while another session may recover.
    local marker_fd
    exec {marker_fd}<"$TX/ready" || fatal '无法打开事务标记。'
    marker=/proc/$BASHPID/fd/$marker_fd
    release_lock || exit 1
    ui_warn '发现上次操作留下的快照。'
    if ! ask_yes '现在恢复到上次操作之前的状态'; then
        fatal '需要先完成恢复，才能进行其他操作。'
    fi
    acquire_lock
    check_private_dirs || exit 1
    verify_running_script || exit 1
    if [[ ! -e $TX && ! -L $TX ]]; then exec {marker_fd}<&-; return 0; fi
    [[ -f $TX/ready && ! -L $TX/ready && $TX/ready -ef $marker ]] || fatal '等待期间快照已变化，请重新运行脚本。'
    exec {marker_fd}<&-
    tx_systemd_snapshot || fatal '无法核实当前快照的服务管理方式。'
    if [[ $SOURCE_PATH == "$SELF_SCRIPT_PATH" ]]; then
        running_digest=$(sha256sum < "$SOURCE_PATH") || fatal '无法核对当前管理脚本。'
    fi
    TX_ACTIVE=1
    tx_rollback || fatal '恢复失败。'
    if [[ -n $running_digest ]] && { [[ ! -f $SELF_SCRIPT_PATH ]] || [[ $(sha256sum < "$SELF_SCRIPT_PATH") != "$running_digest" ]]; }; then
        ui_warn '恢复已完成，托管脚本已变化。请重新运行下载的脚本。'
        exit 1
    fi
}

is_stale_stage() {
    local dir=$1 suffix=${1#"$STAGE_BASE".}
    [[ $dir != "$STAGE" && $suffix =~ ^(live[.])?[a-zA-Z0-9]{8}$ && ! -L $dir && -d $dir && -O $dir ]]
}

remove_stage() {
    check_transaction_mounts "$1" && rm -rf -- "$1"
}

clean_stale_stages() {
    local d
    for d in "$STAGE_BASE".*; do
        is_stale_stage "$d" || continue
        # Other editors can be idle without holding the management lock.
        # FD 8 pins their private stage until its final user is finished.
        (
            local rc=0
            exec 8<"$d" || { [[ ! -e $d && ! -L $d ]]; exit; }
            flock -n -E 42 8 || rc=$?
            (( rc != 42 )) || exit 0
            (( rc == 0 )) || exit 1
            [[ ! -L $d && $d -ef /proc/$BASHPID/fd/8 ]] || exit 0
            if [[ -f $d/step.log && ! -L $d/step.log ]]; then remove_stage "$d"
            else rmdir -- "$d" 2>/dev/null || true; fi
        ) || { ui_warn "无法清理临时目录：$d"; return 1; }
    done
    return 0
}


finish_action_lock() {
    local rc=0
    [[ $LOCK_OWNER == "$BASHPID" ]] || return 0
    if [[ -n $STAGE && ( -e $TX || -L $TX ) ]]; then
        ui_err "事务未完成，重新打开后可恢复：$TX"
        rc=1
    fi
    if (( ! TX_ACTIVE )); then release_lock || rc=1; fi
    return "$rc"
}

on_action_error() {
    local code=$1 line=$2 func=${3:-} failed_command=${4:-}
    [[ $BASHPID == "${ACTION_PID:-$BASHPID}" ]] || exit "$code"
    # Ctrl+C can reach both the action and its supervisor. The supervisor's
    # forwarded TERM (or another keypress) must not interrupt this rollback.
    trap '' INT TERM HUP PIPE
    trap - EXIT ERR
    set +e
    UI_BUF_ON=0
    case $code in
        130) step_end '已取消' ;;
        143) ui_step_fail; ui_err '操作被中止。' ;;
        *)
            ui_step_fail
            if (( ! DIE_SHOWN )) && [[ ! -e ${STAGE:-/nonexistent}/.died ]]; then
                if [[ $failed_command == return* || -z $failed_command ]]; then ui_err '操作没有完成。'
                else ui_err "执行出错：$failed_command"; fi
                ui_note "位置：${func:-main} 第 $line 行，退出码 $code"
            fi
            show_step_log ;;
    esac
    kill_jobs
    if (( TX_ACTIVE && ! KEEP_TX )); then tx_rollback || code=1; fi
    if [[ -n $STAGE ]] && ! remove_stage "$STAGE"; then
        ui_warn "临时目录未清理，可能留有日志和配置：$STAGE"
    fi
    finish_action_lock || code=1
    exit "$code"
}

on_action_exit() {
    local rc=$?
    [[ $BASHPID == "${ACTION_PID:-$BASHPID}" ]] || exit "$rc"
    trap '' INT TERM HUP PIPE
    trap - EXIT ERR
    set +e
    UI_BUF_ON=0
    if (( rc != 0 )); then ui_step_fail; fi
    kill_jobs
    if (( TX_ACTIVE && ! KEEP_TX )); then tx_rollback || rc=1; fi
    if [[ -n $STAGE ]] && ! remove_stage "$STAGE"; then
        ui_warn "临时目录未清理，可能留有日志和配置：$STAGE"
        if (( rc == 0 || rc == 20 || rc == RC_QUIET )); then rc=1; fi
    fi
    finish_action_lock || rc=1
    exit "$rc"
}

kill_jobs() {
    local j live i
    local -a pending=()
    mapfile -t pending < <(jobs -p)
    for j in "${pending[@]}"; do kill -TERM "$j" 2>/dev/null || true; done
    # Reap writers before deleting their stage. Probe traps forward cancellation
    # to timeout/OpenSSL; allow the bounded DNS lookup to finish as well.
    for (( i=0; i<120; i++ )); do
        live=0
        for j in "${pending[@]}"; do kill -0 "$j" 2>/dev/null && live=1 || true; done
        (( live )) || break
        sleep 0.1
    done
    for j in "${pending[@]}"; do
        kill -KILL "$j" 2>/dev/null || true
        wait "$j" 2>/dev/null || true
    done
    return 0
}

terminal_text() {
    # Logs are line-oriented: a broken control sequence must not hide later
    # records. Mark and reset an unfinished sequence at each line boundary.
    # Work on bytes so ordinary UTF-8 survives even with a byte-only locale.
    LC_ALL=C awk -v preview_bytes="${1:-0}" '
      function utf8_width(line, pos, lead,    size, j, b) {
        if (lead <= "\337") size=2
        else if (lead <= "\357") size=3
        else size=4
        if (pos+size-1 > length(line)) return 1
        for (j=1; j<size; j++) {
          b=substr(line,pos+j,1)
          if (b < "\200" || b > "\277") return 1
          if (j == 1 && ((lead == "\340" && b < "\240") || (lead == "\355" && b > "\237") ||
                         (lead == "\360" && b < "\220") || (lead == "\364" && b > "\217"))) return 1
        }
        return size
      }
      BEGIN { esc=sprintf("%c",27); bel=sprintf("%c",7); del=sprintf("%c",127) }
      {
        end=length($0)
        if (preview_bytes && end > preview_bytes) end=preview_bytes
        # Plain ASCII has no terminal escapes. Emit the whole preview in one write.
        preview=(end < length($0) ? substr($0,1,end) : $0)
        if (preview !~ /[^\t -~]/) {
          print preview (end < length($0) ? " …（长日志已截断）" : "")
          next
        }
        for (i=1; i<=end; i++) {
          c=substr($0,i,1)
          # Consume complete UTF-8 characters before classifying standalone C1 bytes.
          if (c >= "\302" && c <= "\364") {
            size=utf8_width($0,i,c)
            if (size > 1) {
              c=substr($0,i,size); i+=size-1
              if (size == 2 && substr(c,1,1) == "\302" && substr(c,2,1) <= "\237") c=substr(c,2,1)
            }
          }
          if (length(c) == 1 && c >= "\200" && c <= "\237") {
            if (c == "\234") state=""
            else if (state == "string" || state == "string-esc") state="string"
            else if (c == "\233") state="csi"
            else if (c == "\235") { state="string"; osc=1 }
            else if (c == "\220" || c == "\230" || c == "\236" || c == "\237") { state="string"; osc=0 }
            continue
          }
          if (state == "string" || state == "string-esc") {
            if ((state == "string-esc" && c == "\\") || (osc && c == bel)) state=""
            else if (c == esc) state="string-esc"
            else state="string"
            continue
          }
          if (c == esc) { state="escape"; continue }
          if (state == "csi") {
            if (c >= "@" && c <= "~") state=""
            continue
          }
          if (state == "escape") {
            if (c == "[") state="csi"
            else if (c == "]") { state="string"; osc=1 }
            else if (c == "P" || c == "X" || c == "^" || c == "_") { state="string"; osc=0 }
            else if (!(c >= " " && c <= "/")) state=""
            continue
          }
          if (c == "\t" || (c >= " " && c != del)) printf "%s", c
        }
        if (i<=length($0)) printf " …（长日志已截断）"
        else if (state != "") printf " [已截断控制序列]"
        state=""; osc=0
        printf "\n"
      }'
}

show_step_log() {
    [[ -n $STEP_LOG && -s $STEP_LOG ]] || return 0
    local l
    printf '  %s相关日志：%s\n' "$C_DIM" "$C_RESET" >&5
    while IFS= read -r l; do
        [[ -n ${l//[[:space:]]/} ]] || continue
        printf '  %s|%s %s\n' "$C_DIM" "$C_RESET" "$l" >&5
    done < <(tail -n 15 "$STEP_LOG" | terminal_text)
}

run_action() {
    # run_child provides the only subprocess boundary, so its $! is ACTION_PID.
    # Undo Bash's asynchronous INT default before installing our traps,
    # so foreground commands inherit normal keyboard-interrupt handling.
    trap - INT
    set -Eeuo pipefail
    ACTION_PID=$BASHPID
    # A nested action must never clean its parent's stage or unlock its description.
    STAGE='' STEP_LOG='' LOCK_OWNER='' DRAFT_GENERATION='' TX_ACTIVE=0 KEEP_TX=0
    trap 'on_action_error $? $LINENO "${FUNCNAME[0]:-}" "$BASH_COMMAND"' ERR
    trap 'on_action_error 130 $LINENO' INT
    trap 'on_action_error 143 $LINENO' TERM HUP
    trap 'TUI_RESIZED=1' WINCH
    trap on_action_exit EXIT
    prepare_runtime
    [[ $1 != : ]] || return 0
    make_dir "$(dirname -- "$STAGE_BASE")"
    STAGE=$(mktemp -d "$STAGE_BASE.live.XXXXXXXX")
    exec 8<"$STAGE"
    flock -x 8
    STEP_LOG=$STAGE/step.log
    : > "$STEP_LOG"
    check_private_dirs || return 1
    "$@" 2>> "$STEP_LOG"
}

run_child() {
    local -a INPUT_SUPERVISORS=("${INPUT_SUPERVISORS[@]}" "$BASHPID")
    local __rc_pid='' __rc_cancel=0 __rc_sent=0 __rc_status=0 __rc_retry __rc_saved
    local __rc_int __rc_term __rc_hup __rc_err
    __rc_int=$(trap -p INT); __rc_term=$(trap -p TERM)
    __rc_hup=$(trap -p HUP); __rc_err=$(trap -p ERR)
    trap - ERR
    set +e
    CHILD_RUNNING=1
    # Waiting on an asynchronous child lets the supervising shell forward a
    # signal addressed only to its PID. Explicit stdin keeps interactive reads.
    # Send once: a second request must not interrupt the child's rollback.
    trap 'if (( __rc_cancel == 0 )); then __rc_cancel=130; if [[ -n $__rc_pid ]]; then __rc_sent=1; kill -INT "$__rc_pid" 2>/dev/null || :; fi; fi' INT
    trap 'if (( __rc_cancel == 0 )); then __rc_cancel=143; if [[ -n $__rc_pid ]]; then __rc_sent=1; kill -TERM "$__rc_pid" 2>/dev/null || :; fi; fi' TERM HUP
    run_action "$@" <&0 &
    __rc_pid=$!
    case $__rc_cancel:$__rc_sent in
        130:0) kill -INT "$__rc_pid" 2>/dev/null || true ;;
        143:0) kill -TERM "$__rc_pid" 2>/dev/null || true ;;
    esac
    while :; do
        wait "$__rc_pid"
        __rc_status=$?
        (( __rc_status > 128 )) || break
        if ! kill -0 "$__rc_pid" 2>/dev/null; then
            # A trapped signal and child exit can coincide. Keep the first status if already collected.
            __rc_retry=0
            wait "$__rc_pid" 2>/dev/null || __rc_retry=$?
            (( __rc_retry == 127 )) || __rc_status=$__rc_retry
            break
        fi
    done
    __rc_pid=''
    CHILD_RC=$__rc_status
    if (( __rc_cancel )); then
        # A failed cleanup and a completed uninstall both have meaningful results.
        case $CHILD_RC in 0|130|143|"$RC_QUIET") CHILD_RC=$__rc_cancel ;; esac
    fi
    tty_echo "${INPUT_TTY_STATE:-echo}"
    CHILD_RUNNING=0
    trap - INT TERM HUP ERR
    for __rc_saved in "$__rc_int" "$__rc_term" "$__rc_hup" "$__rc_err"; do
        [[ -z $__rc_saved ]] || eval "$__rc_saved"
    done
    set -e
    select_core_path
    if (( __rc_cancel )) && [[ -n $ACTION_PID ]]; then exit "$CHILD_RC"; fi
    if (( __rc_cancel == 143 )); then
        (( CHILD_RC != 20 )) || exit 0
        exit "$CHILD_RC"
    fi
    return 0
}


fetch() {
    local url=$1 dest=$2 child
    [[ $url == https://* ]] || { die '下载地址必须是 HTTPS。'; return 1; }
    # wait is interruptible: action cancellation can reap the download through
    # kill_jobs instead of waiting for curl's full transfer deadline.
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fLsS --retry 2 --retry-delay 2 \
        --connect-timeout 10 --max-time 600 --speed-limit 1024 --speed-time 30 -o "$dest.part" "$url" >> "$STEP_LOG" 2>&1 3>&- 4>&- 5>&- 8>&- 9>&- &
    child=$!
    if ! wait "$child"; then
        rm -f -- "$dest.part"
        die "下载失败：$url"
        return 1
    fi
    [[ -s $dest.part ]] || { rm -f -- "$dest.part"; die "下载结果为空：$url"; return 1; }
    mv -f -- "$dest.part" "$dest"
}

valid_release_tag() {
    local LC_ALL=C
    case $1 in
        XTLS/Xray-core) [[ $2 == v* ]] && valid_xray_version "${2#v}" ;;
        shadowsocks/shadowsocks-rust) [[ $2 == v* ]] && valid_ss_version "${2#v}" ;;
        XTLS/Xray-rules-dat) [[ $2 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $2 != *..* ]] ;;
        *) return 1 ;;
    esac
}

release_query_to() {
    local output=$1 child
    shift
    # Keep the job in the action's shell: its signal trap can interrupt wait and reap it.
    "$@" </dev/null > "$output" 2>>"${STEP_LOG:-/dev/null}" 3>&- 4>&- 5>&- 8>&- 9>&- &
    child=$!
    wait "$child"
}

latest_tag_try() {
    local repo=$1 output=$2 file=$3 prefix="https://github.com/$1/releases/tag/" url candidate
    local -a curl_args=(--proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 30)
    if release_query_to "$file" curl "${curl_args[@]}" -I -o /dev/null -w '%{url_effective}\n' \
        "https://github.com/$repo/releases/latest" && IFS= read -r url < "$file" && [[ $url == "$prefix"?* ]]; then
        candidate=${url#"$prefix"}
        candidate=${candidate//%2[Bb]/+}
        if valid_release_tag "$repo" "$candidate"; then printf -v "$output" '%s' "$candidate"; return 0; fi
    fi
    release_query_to "$file" curl "${curl_args[@]}" "https://api.github.com/repos/$repo/releases/latest" || return 1
    release_query_to "$file.tag" jq -er '.tag_name | strings | select(test("[[:cntrl:]]") | not)' "$file" || return 1
    candidate=$(<"$file.tag")
    valid_release_tag "$repo" "$candidate" || return 1
    printf -v "$output" '%s' "$candidate"
}

latest_tag() {
    [[ -n $STAGE && -d $STAGE ]] || { die '获取发行版本前需要准备临时目录。'; return 1; }
    latest_tag_try "$1" "$2" "$STAGE/release-response" || {
        die "无法获取 $1 的最新正式版，请检查本机能否访问 GitHub。"; return 1;
    }
}

normalize_tag() {
    local t=$1
    [[ $t =~ ^[0-9] ]] && t=v$t
    printf '%s' "$t"
}

arch_of() {
    local machine
    machine=$(uname -m) || return 1
    case "$machine" in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64|armv8) printf 'arm64' ;;
        armv7l|armv7|armv8l) printf 'arm' ;;
        armv6l) printf 'armv6' ;;
        armv5tel|armv5tejl) printf 'armv5' ;;
        i[3-6]86) printf '386' ;;
        s390x) printf 's390x' ;;
        riscv64|ppc64le|loongarch64) printf '%s' "$machine" ;;
        *) printf 'unknown' ;;
    esac
}


valid_xray_version() {
    local LC_ALL=C
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

xray_version_of() {
    local out v bin
    [[ ! -L $1 ]] && bin=$(trusted_executable_path "$1") || return 1
    out=$(timeout -k 2 5 "$bin" version 2>>"${STEP_LOG:-/dev/null}") || return 1
    v=$(awk 'NR==1 && $1=="Xray" {print $2; exit}' <<< "$out")
    valid_xray_version "$v" || return 1
    printf '%s' "$v"
}

download_xray() {
    local tag=$1 out=$2 asset digest base arch
    arch=$(arch_of) || return 1
    if [[ $arch == arm || $arch == armv6 ]]; then
        # Xray's GOARM=6/7 builds need hardware floating point; use its soft-float ZIP otherwise.
        grep -Eq '^[[:blank:]]*Features[[:blank:]]*:[[:blank:]]*([^[:blank:]]+[[:blank:]]+)*vfp([[:blank:]]|$)' \
            "$ROOT/proc/cpuinfo" 2>/dev/null || arch=armv5
    fi
    case $arch in
        amd64) asset=Xray-linux-64.zip ;;
        arm64) asset=Xray-linux-arm64-v8a.zip ;;
        arm) asset=Xray-linux-arm32-v7a.zip ;;
        armv6) asset=Xray-linux-arm32-v6.zip ;;
        armv5) asset=Xray-linux-arm32-v5.zip ;;
        386) asset=Xray-linux-32.zip ;;
        s390x) asset=Xray-linux-s390x.zip ;;
        riscv64) asset=Xray-linux-riscv64.zip ;;
        ppc64le) asset=Xray-linux-ppc64le.zip ;;
        loongarch64) asset=Xray-linux-loong64.zip ;;
        *) die "此脚本不支持在 $(uname -m) 上安装 Xray。"; return 1 ;;
    esac
    if [[ $tag == latest || $tag == compat ]]; then latest_tag XTLS/Xray-core tag || return 1; fi
    valid_xray_version "${tag#v}" || { die 'Xray 版本号格式不正确。'; return 1; }
    tag=$(normalize_tag "$tag")
    base=https://github.com/XTLS/Xray-core/releases/download/$tag
    mkdir -p "$out" || return 1
    fetch "$base/$asset" "$out/$asset" || return 1
    fetch "$base/$asset.dgst" "$out/$asset.dgst" || return 1
    digest=$(awk -F'= *' '/^SHA(2-)?256=/{print $2; exit}' "$out/$asset.dgst" | tr -d '[:space:]')
    [[ $digest =~ ^[0-9a-fA-F]{64}$ ]] || { die 'Xray 校验文件格式异常。'; return 1; }
    [[ $(sha256_of "$out/$asset") == "${digest,,}" ]] || { die 'Xray 安装包 SHA-256 校验失败。'; return 1; }
    unzip -p "$out/$asset" xray > "$out/xray" \
        && unzip -p "$out/$asset" geoip.dat > "$out/geoip.dat" \
        && unzip -p "$out/$asset" geosite.dat > "$out/geosite.dat" || {
        die '提取 Xray 安装包失败。'; return 1;
    }
    geodata_files_ok "$out" || { die 'Xray 安装包缺少有效的 geoip.dat 或 geosite.dat。'; return 1; }
    chmod 755 "$out/xray" || return 1
    rm -f -- "$out/$asset" "$out/$asset.dgst"
    local v
    v=$(xray_version_of "$out/xray") || { die '无法读取安装包中的 Xray 版本，请检查日志。'; return 1; }
    ver_ge "$v" "$XRAY_MIN_VERSION" || { die "需要 Xray $XRAY_MIN_VERSION 或更新版本，当前为 $v。"; return 1; }
    [[ $v == "${tag#v}" ]] || { die "Xray 安装包版本与目标 $tag 不符，已停止安装。"; return 1; }
    printf 'v%s' "$v" > "$out/xray.version"
}


# Upstream static SS-Rust builds also run on Debian and Ubuntu without a glibc version dependency.
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

valid_ss_version() {
    local LC_ALL=C identifiers='[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*'
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+(-$identifiers)?([+]$identifiers)?$ ]]
}

ss_version_of() {
    local out v bin
    [[ ! -L $1 ]] && bin=$(trusted_executable_path "$1") || return 1
    out=$(timeout -k 2 5 "$bin" --version 2>>"${STEP_LOG:-/dev/null}") || return 1
    v=$(awk 'NR==1 && $1 ~ /^(shadowsocks(-rust)?|ssserver(-rust)?)$/ {print $2; exit}' <<< "$out")
    valid_ss_version "$v" || return 1
    printf '%s' "$v"
}

download_ss() {
    local tag=$1 out=$2 triple asset base digest member v
    triple=$(ss_triple) || { die "此脚本不支持在 $(uname -m) 上安装 SS-Rust。"; return 1; }
    if [[ $tag == latest ]]; then latest_tag shadowsocks/shadowsocks-rust tag || return 1; fi
    valid_ss_version "${tag#v}" || { die 'SS-Rust 版本号格式不正确。'; return 1; }
    tag=$(normalize_tag "$tag")
    asset="shadowsocks-${tag}.${triple}.tar.xz"
    base=https://github.com/shadowsocks/shadowsocks-rust/releases/download/$tag
    mkdir -p "$out" || return 1
    fetch "$base/$asset" "$out/$asset" || return 1
    fetch "$base/$asset.sha256" "$out/$asset.sha256" || return 1
    digest=$(awk '{print $1; exit}' "$out/$asset.sha256")
    [[ $digest =~ ^[0-9a-fA-F]{64}$ ]] || { die 'SS-Rust 校验文件格式异常。'; return 1; }
    [[ $(sha256_of "$out/$asset") == "${digest,,}" ]] || { die 'SS-Rust 安装包 SHA-256 校验失败。'; return 1; }

    # Do not stop reading tar's listing early: tar | awk '... exit' can trigger SIGPIPE (141) with pipefail.
    if ! tar -tJf "$out/$asset" > "$out/.ss-members" 2>>"${STEP_LOG:-/dev/null}"; then
        rm -f -- "$out/.ss-members"
        die '无法读取 SS-Rust 安装包的文件清单。'
        return 1
    fi
    member=$(awk '$0 == "ssserver" || $0 == "./ssserver" {if (found == "") found = $0} END {print found}' "$out/.ss-members")
    rm -f -- "$out/.ss-members"
    [[ -n $member ]] || { die '安装包中缺少 ssserver。'; return 1; }
    if ! tar -xOJf "$out/$asset" "$member" > "$out/ssserver" 2>>"${STEP_LOG:-/dev/null}"; then
        rm -f -- "$out/ssserver"
        die '无法从 SS-Rust 安装包提取 ssserver。'
        return 1
    fi
    [[ -s $out/ssserver ]] || { die '提取的 ssserver 为空。'; return 1; }
    chmod 755 "$out/ssserver"
    v=$(ss_version_of "$out/ssserver") || {
        die '无法读取安装包中的 SS-Rust 版本，请检查日志。'
        return 1
    }
    [[ $v == "${tag#v}" ]] || { die "SS-Rust 安装包版本与目标 $tag 不符，已停止安装。"; return 1; }
    rm -f -- "$out/$asset" "$out/$asset.sha256"
    printf 'v%s' "$v" > "$out/ss.version"
}



script_version_of() {
    local version LC_ALL=C ids='[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*'
    has_manager_script "$1" || return 1
    version=$(awk -F'"' '
        $1 == "readonly SCRIPT_VERSION=" {
            if (++seen != 1 || !((NF == 3 && $3 ~ /^[[:blank:]]*$/) || $3 ~ /^[[:blank:]]+#/)) exit 1
            version=$2
        }
        END {if (seen != 1) exit 1; print version}
    ' "$1") || return 1
    [[ $version =~ ^v?[0-9]+(\.[0-9]+)*(-$ids)?(\+$ids)?$ ]] || return 1
    printf '%s' "$version"
}



probe_public_ip() {
    local family=$1 url addr
    shift
    for url in "$@"; do
        addr=$(curl "-$family" -fsS --connect-timeout 3 --max-time 6 --max-filesize 128 "$url" 2>/dev/null) || continue
        addr=$(normalize_link "$addr")
        if "valid_ipv$family" "$addr" && ! unusable_endpoint_ip "$addr"; then
            printf '%s\n' "${addr,,}"
            return 0
        fi
    done
    return 1
}

detect_public_ips() {
    local ipv6_job=''
    NET_V4='' NET_V6=''
    if has_ipv6_stack; then
        (probe_public_ip 6 https://api64.ipify.org https://ipv6.icanhazip.com https://v6.ident.me || :) \
            > "$STAGE/public-ip-v6" 3>&- 4>&- 5>&- 8>&- 9>&- &
        ipv6_job=$!
    fi
    NET_V4=$(probe_public_ip 4 https://api.ipify.org https://ipv4.icanhazip.com https://v4.ident.me) || NET_V4=''
    if [[ -n $ipv6_job ]] && wait "$ipv6_job"; then IFS= read -r NET_V6 < "$STAGE/public-ip-v6" || NET_V6=''; fi
    return 0
}

has_ipv6_stack() {
    local table=$ROOT/proc/net/if_inet6 flag value
    [[ -r $table ]] || return 1
    if IFS= read -r value 2>/dev/null < "$table" && [[ -n $value ]]; then return 0; fi
    # A live interface may be enabled before it receives its first address.
    for flag in "$ROOT"/proc/sys/net/ipv6/conf/*/disable_ipv6; do
        case $flag in */all/disable_ipv6|*/default/disable_ipv6) continue ;; esac
        [[ -r $flag ]] && IFS= read -r value 2>/dev/null < "$flag" && [[ $value == 0 ]] && return 0
    done
    return 1
}


listeners() {
    local flag
    local -a family=()
    case $1 in tcp) flag=-ltnp ;; udp) flag=-lunp ;; *) return 2 ;; esac
    case ${3:-} in '') ;; 4|6) family=("-$3") ;; *) return 2 ;; esac
    valid_port "$2" || return 2
    timeout -k 2 5 ss -H "$flag" "${family[@]}" "sport = :$((10#$2))" 2>>"${STEP_LOG:-/dev/null}" || return 2
}

# Parse complete ss -H -l{t,u}np users tuples; never search inside a process name.
listener_pids() {
    local row=$1
    local -n result=$2
    local header='^[[:space:]]*([^[:space:]]+[[:space:]]+){5}users:[[:space:]]*\([[:space:]]*'
    local tuple='^\([[:space:]]*"([^"\\]|\\.)*"[[:space:]]*,[[:space:]]*pid[[:space:]]*=[[:space:]]*([1-9][0-9]*)[[:space:]]*,[[:space:]]*fd[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*\)[[:space:]]*'
    local next='^,[[:space:]]*' end='^\)[[:space:]]*$'
    local -a parsed=()
    result=()
    [[ $row =~ $header ]] || return 1
    row=${row:${#BASH_REMATCH[0]}}
    while [[ $row =~ $tuple ]]; do
        parsed+=("${BASH_REMATCH[2]}")
        row=${row:${#BASH_REMATCH[0]}}
        if [[ $row =~ $end ]]; then result=("${parsed[@]}"); return 0; fi
        [[ $row =~ $next ]] || return 1
        row=${row:${#BASH_REMATCH[0]}}
    done
    return 1
}

listeners_only_pid() {
    local row pid expected=$2
    local -a owners
    [[ -n $1 && $expected =~ ^[1-9][0-9]*$ ]] || return 1
    while IFS= read -r row; do
        listener_pids "$row" owners || return 1
        for pid in "${owners[@]}"; do [[ $pid == "$expected" ]] || return 1; done
    done <<< "$1"
}

nginx_unit_cgroup() {
    local group
    group=$(timeout -k 2 5 systemctl show zxray-nginx -p ControlGroup --value 2>/dev/null) || return 1
    [[ $group == /* && $group == */zxray-nginx.service && $group != *$'\n'* ]] || return 1
    printf '%s' "$group"
}

nginx_worker_owned() {
    local pid=$1 fd target hierarchy controllers path group=${stopping_nginx_group:-} in_service=0
    if [[ -r /proc/$pid/cgroup ]]; then
        while IFS=: read -r hierarchy controllers path; do
            [[ ( $hierarchy == 0 && -z $controllers ) || ,$controllers, == *,name=systemd,* ]] || continue
            [[ $path == /* ]] || continue
            [[ $path != *.service && $path != *.service/* ]] || in_service=1
            [[ $path == */zxray-nginx.service || $path == */zxray-nginx.service/* ]] || continue
            if [[ -z $group && ! ${stopping_nginx_group+x} ]]; then group=$(nginx_unit_cgroup) || group=''; fi
            [[ -n $group && ( $path == "$group" || $path == "$group/"* ) ]] && return 0
        done 2>/dev/null < "/proc/$pid/cgroup"
    fi
    # Workers in another service may share the same error log.
    (( ! in_service )) || return 1
    for fd in /proc/$pid/fd/*; do
        [[ -L $fd ]] || continue
        [[ $fd -ef $NGINX_DIR/error.log ]] && return 0
        target=$(readlink -- "$fd" 2>/dev/null) || continue
        [[ $target == "$NGINX_DIR/error.log (deleted)" && /proc/$pid/root$NGINX_DIR -ef $NGINX_DIR ]] && return 0
    done
    return 1
}

# The same installed executable can also be started with an independent configuration.
managed_core_argv() {
    local core=$1
    shift
    case $core in
        xray) [[ $# == 4 && $2 == run && $3 == -config && $4 == "$CONFIG_FILE" ]] ;;
        ss) [[ $# == 5 && $2 == -c && $3 == "$SS_CONFIG" && $4 == --acl && $5 == "$SS_ACL" ]] ;;
        *) return 1 ;;
    esac
}

pid_is_owned() {
    local pid=$1 exe cmd bin resolved
    [[ -r /proc/$pid/cmdline ]] || return 1
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
    local -a bins=("$CORE_BIN" "$SS_BIN") argv=()
    if (( LEGACY_CORE_OWNED )); then bins+=("$PUBLIC_XRAY"); fi
    # /proc resolves symlinked parent directories; retain exact-path matching.
    for bin in "${bins[@]}"; do
        if [[ $exe != "$bin" && $exe != "$bin (deleted)" ]]; then
            resolved=$(readlink -f -- "${bin%/*}" 2>/dev/null) || continue
            resolved=${resolved%/}/${bin##*/}
            [[ $exe == "$resolved" || $exe == "$resolved (deleted)" ]] || continue
        fi
        mapfile -d '' -t argv 2>/dev/null < "/proc/$pid/cmdline" || return 1
        if [[ $bin == "$SS_BIN" ]]; then managed_core_argv ss "${argv[@]}"
        else managed_core_argv xray "${argv[@]}"; fi
        return $?
    done
    # Process titles are mutable: a path mentioned in argv is not evidence
    # that an unrelated executable belongs to this installation.
    case ${exe##*/} in
        nginx|nginx\ \(deleted\)|nginx-light|nginx-light\ \(deleted\)|nginx-extras|nginx-extras\ \(deleted\)|\
        nginx-core|nginx-core\ \(deleted\)|nginx-full|nginx-full\ \(deleted\)|nginx.dpkg-new|nginx.dpkg-new\ \(deleted\)) ;;
        *) return 1 ;;
    esac
    cmd=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") || return 1
    [[ " $cmd " == *" -c $NGINX_DIR/nginx.conf "* ]] && return 0
    if [[ $cmd == 'nginx: worker process'* || $cmd == 'nginx: cache '* ]]; then
        local ppid
        # Workers also need independent ownership evidence (cgroup/log fd/parent).
        if nginx_worker_owned "$pid"; then return 0; fi
        ppid=$(awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)
        if [[ $ppid =~ ^[0-9]+$ ]] && (( ppid > 1 && ppid != pid )) && pid_is_owned "$ppid"; then return 0; fi
    fi
    return 1
}

port_foreign() {
    local rows row pid
    local -a owners
    rows=$(listeners "$1" "$2") || return 2
    [[ -n $rows ]] || return 1
    while IFS= read -r row; do
        listener_pids "$row" owners || return 0
        for pid in "${owners[@]}"; do pid_is_owned "$pid" || return 0; done
    done <<< "$rows"
    return 1
}


port_owner_name() {
    local rows row pid name
    local -a owners
    rows=$(listeners "$1" "$2") || return 2
    while IFS= read -r row; do
        listener_pids "$row" owners || continue
        for pid in "${owners[@]}"; do
            pid_is_owned "$pid" && continue
            if IFS= read -r name 2>/dev/null < "/proc/$pid/comm" && [[ $name =~ ^[a-zA-Z0-9_.+-]+$ ]]; then
                printf '%s' "$name"
            else printf 'PID %s' "$pid"; fi
            return 0
        done
    done <<< "$rows"
    return 1
}
port_owner_label() {
    local n
    n=$(port_owner_name "$1" "$2") || n=''
    printf '%s' "${n:0:16}"
    [[ -n $n ]] || printf '其他程序'
}

port_listening() {
    local rows
    rows=$(listeners "$1" "$2") || return 2
    [[ -n $rows ]]
}

port_query_failed() {
    die '无法查询本机监听端口，已停止操作。' '请检查 ss 命令及权限。'
}

random_free_port() {
    local low high extra min max span left right count drawn slot p proto rc
    if ! IFS=$' \t' read -r low high extra 2>/dev/null < "$ROOT/proc/sys/net/ipv4/ip_local_port_range" ||
        [[ -n $extra ]] || ! valid_port "$low" || ! valid_port "$high" || (( 10#$low > 10#$high )); then
        low=32768 high=60999
    else low=$((10#$low)); high=$((10#$high)); fi
    # If the kernel uses all unprivileged ports, explicit binding is still valid.
    if (( low <= 1024 && high == 65535 )); then low=65536 high=65536; fi
    for span in 20000-60000 1024-65535; do
        min=${span%-*}; max=${span#*-}
        left=0 right=0
        if (( low > max || high < min )); then left=$((max - min + 1))
        else
            if (( low > min )); then left=$((low - min)); fi
            if (( high < max )); then right=$((max - high)); fi
        fi
        count=$((left + right)); (( count > 0 )) || continue
        drawn=$(shuf -i "1-$count" -n 200) || { die '生成随机端口失败，请检查 shuf。'; return 1; }
        while IFS= read -r slot; do
            if (( slot <= left )); then p=$((min + slot - 1))
            else p=$((max - right + slot - left)); fi
            for proto in tcp udp; do
                rc=0; port_listening "$proto" "$p" || rc=$?
                (( rc <= 1 )) || { port_query_failed; return 1; }
                (( rc == 1 )) || continue 2
            done
            rc=0; port_in_draft "$p" || rc=$?
            case $rc in
                1) printf '%s' "$p"; return 0 ;;
                2) die '无法读取草稿中的端口。'; return 1 ;;
            esac
        done <<< "$drawn"
    done
    die '找不到可用的随机端口。'
}


sni_pool() {
    local d f=${1:-$(sni_pool_file)}
    local -a pool=()
    if [[ -f $f ]]; then
        while IFS= read -r d || [[ -n $d ]]; do
            d=${d%%#*}
            d=${d//[[:space:]]/}
            [[ -n $d ]] || continue
            if valid_domain "$d"; then pool+=("${d,,}"); fi
        done < "$f"
    fi
    (( ${#pool[@]} )) || pool=("${DEFAULT_SNI_POOL[@]}")
    printf '%s\n' "${pool[@]}"
}

# Only Xray's built-in gate dials the decoy through the configured freedom outbound.
sni_probe_family() {
    jq -er 'if .reality.guard == "xray" and .outbound == "v4only" then "4"
            elif .reality.guard == "xray" and .outbound == "v6only" then "6"
            else "" end' "$DRAFT"
}

sni_probe() (
    local d=$1 log=$2 probe_pid="" rc=0 family=${4:-}
    trap 'trap "" TERM INT HUP; if [[ -n $probe_pid ]]; then kill "$probe_pid" 2>/dev/null || true; wait "$probe_pid" 2>/dev/null || true; fi; exit 143' TERM INT HUP
    if [[ ${3:-0} != 1 ]]; then
        safe_remote_target "$d" 443 1 "$family" || { printf '%s\n' "$PARSE_ERR" > "$log"; return 1; }
    fi
    timeout -k 1 5 openssl s_client ${family:+"-$family"} -connect "$d:443" -servername "$d" -tls1_3 -alpn h2 \
        -verify_hostname "$d" -verify_return_error </dev/null > "$log" 2>&1 3>&- 4>&- 5>&- 8>&- 9>&- &
    probe_pid=$!
    wait "$probe_pid" || rc=$?
    probe_pid=''
    (( rc == 0 )) && grep -q 'ALPN protocol: h2' "$log"
)

now_ms() {
    # Return an eight-digit millisecond wall-clock tick, safe for 32-bit Bash.
    # Both the TUI and SNI probes handle the modulo-100000000 wrap.
    local seconds fraction raw
    if [[ ${EPOCHREALTIME:-} =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        seconds=${BASH_REMATCH[1]}
        fraction=${BASH_REMATCH[2]}000
        seconds=${seconds: -5}
        printf '%d' $(( 10#$seconds * 1000 + 10#${fraction:0:3} ))
    else
        raw=$(date +%s%3N) || return 1
        [[ $raw =~ ^[0-9]+$ ]] || return 1
        # Bash printf interprets leading zeros as octal; force decimal first.
        printf '%d' "$(( 10#${raw: -8} ))"
    fi
}

sni_probe_job() {
    local d=$1 out=$2 i t1 t2 elapsed probe_pid='' rc family=${3:-}
    trap 'trap "" TERM INT HUP; if [[ -n $probe_pid ]]; then kill "$probe_pid" 2>/dev/null || true; wait "$probe_pid" 2>/dev/null || true; fi; exit 143' TERM INT HUP
    if ! safe_remote_target "$d" 443 1 "$family"; then
        printf '%s\n' "$PARSE_ERR" > "$out.log"
        : > "$out.done"
        return 0
    fi
    for i in 1 2 3; do
        t1=$(now_ms) || continue
        timeout -k 1 5 openssl s_client ${family:+"-$family"} -connect "$d:443" -servername "$d" -tls1_3 -alpn h2 \
            -verify_hostname "$d" -verify_return_error </dev/null > "$out.log" 2>&1 3>&- 4>&- 5>&- 8>&- 9>&- &
        probe_pid=$!
        rc=0
        wait "$probe_pid" || rc=$?
        probe_pid=''
        if (( rc == 0 )) && grep -q 'ALPN protocol: h2' "$out.log"; then
            t2=$(now_ms) || continue
            elapsed=$(( (t2 - t1 + 100000000) % 100000000 ))
            # The handshake has a five-second timeout. Discard measurements
            # distorted by a wall-clock adjustment instead of ranking them.
            if (( elapsed <= 6000 )); then
                printf '%s\n' "$elapsed" >> "$out.ms"
            fi
        fi
    done
    : > "$out.done"
}

sni_auto_select() {
    local __sa_out=$1 __sa_dir __sa_i __sa_total __sa_done=0 __sa_best='' __sa_bscore=999999999 __sa_score __sa_ms __sa_ok
    local __sa_running __sa_pid __sa_deadline __sa_budget __sa_next=0 __sa_progress=0
    local -a __sa_pool=() __sa_pids=() __sa_sorted=()
    local __sa_family
    SNI_BEST_MS=0
    __sa_family=$(sni_probe_family) || return 1
    tui_cursor on
    mapfile -t __sa_pool < <(sni_pool)
    if (( ${#__sa_pool[@]} > 64 )); then
        ui_note '本次仅测试前 64 个站点。'
        __sa_pool=("${__sa_pool[@]:0:64}")
    fi
    __sa_total=${#__sa_pool[@]}
    (( __sa_total )) || return 1
    __sa_budget=$(( ((__sa_total + 11) / 12) * 30 ))
    (( __sa_budget <= 90 )) || __sa_budget=90
    __sa_deadline=$(( SECONDS + __sa_budget ))
    __sa_dir=$STAGE/sni-test
    rm -rf -- "$__sa_dir" || return 1
    mkdir -p -- "$__sa_dir" || return 1
    if [[ -t 4 ]]; then
        ui_note '正在测速伪装站点…'
        if ui_ansi_tty; then __sa_progress=1; fi
    fi
    while (( SECONDS <= __sa_deadline )); do
        __sa_running=0
        for __sa_pid in "${__sa_pids[@]}"; do
            if kill -0 "$__sa_pid" 2>/dev/null; then __sa_running=$(( __sa_running + 1 )); fi
        done
        # Limit concurrent TLS handshakes on small VPS machines.
        while (( __sa_next < __sa_total && __sa_running < 12 )); do
            __sa_i=$__sa_next
            (
                trap - ERR INT TERM HUP EXIT TSTP
                set +e
                sni_probe_job "${__sa_pool[$__sa_i]}" "$__sa_dir/$__sa_i" "$__sa_family"
            ) 3>&- 4>&- 5>&- 8>&- 9>&- &
            __sa_pids+=("$!")
            __sa_next=$(( __sa_next + 1 ))
            __sa_running=$(( __sa_running + 1 ))
        done
        __sa_done=$(find "$__sa_dir" -maxdepth 1 -name '*.done' 2>/dev/null | wc -l)
        if (( __sa_progress )); then
            printf '\r\e[2K%d/%d' "$__sa_done" "$__sa_total" >&4
        fi
        (( __sa_done < __sa_total )) || break
        (( __sa_running )) || break
        sleep 0.3
    done
    # Never wait forever: terminate only still-running workers when probes did not finish.
    if (( __sa_done < __sa_total )); then
        for __sa_pid in "${__sa_pids[@]}"; do
            kill -0 "$__sa_pid" 2>/dev/null && kill "$__sa_pid" 2>/dev/null || true
        done
    fi
    for __sa_pid in "${__sa_pids[@]}"; do wait "$__sa_pid" 2>/dev/null || true; done
    if (( __sa_progress )); then printf '\r\e[2K' >&4; fi
    for __sa_i in "${!__sa_pool[@]}"; do
        [[ -s $__sa_dir/$__sa_i.ms ]] || continue
        mapfile -t __sa_sorted < <(sort -n "$__sa_dir/$__sa_i.ms")
        __sa_ok=${#__sa_sorted[@]}
        (( __sa_ok >= 2 )) || continue
        if (( __sa_ok >= 3 )); then __sa_ms=${__sa_sorted[1]}; else __sa_ms=$(( (__sa_sorted[0] + __sa_sorted[1]) / 2 )); fi
        __sa_score=$(( (3 - __sa_ok) * 1000000 + __sa_ms ))
        if (( __sa_score < __sa_bscore )); then
            __sa_bscore=$__sa_score
            __sa_best=${__sa_pool[$__sa_i]}
            SNI_BEST_MS=$__sa_ms
        fi
    done
    [[ -n $__sa_best ]] || return 1
    printf -v "$__sa_out" '%s' "$__sa_best"
}


uri_decode() {
    local data=$1 out='' ch hex i=0
    while (( i < ${#data} )); do
        ch=${data:i:1}
        if [[ $ch == % ]]; then
            hex=${data:i+1:2}
            [[ $hex =~ ^[0-9A-Fa-f]{2}$ ]] || return 1
            (( 16#$hex >= 32 && 16#$hex != 127 )) || return 1
            printf -v ch '%b' "\\x$hex"
            out+=$ch
            i=$(( i + 3 ))
            continue
        fi
        out+=$ch
        i=$(( i + 1 ))
    done
    valid_text_value "$out" || return 1
    printf '%s' "$out"
}

parse_link_query() {
    local protocol=$1 query=$2 pair key raw_value value
    local -n result=$3
    local -a pairs=()
    [[ $query != *[[:cntrl:]]* ]] || { PARSE_ERR='查询参数含控制字符'; return 1; }
    IFS='&' read -r -a pairs <<< "$query"
    for pair in "${pairs[@]}"; do
        [[ -n $pair ]] || continue
        key=$(uri_decode "${pair%%=*}") || { PARSE_ERR='参数名称编码不正确'; return 1; }
        raw_value=''
        [[ $pair != *=* ]] || raw_value=${pair#*=}
        value=$(uri_decode "$raw_value") || { PARSE_ERR='参数值编码不正确'; return 1; }
        if [[ $protocol == ss ]]; then
            # SIP002 exporters may include optional metadata.
            case $key in plugin|type) ;; *) continue ;; esac
        else
            case $key in
                serverName) key=sni ;; publicKey) key=pbk ;; shortId) key=sid ;;
                fingerprint) key=fp ;; spiderX) key=spx ;;
                security|encryption|flow|type|sni|pbk|sid|fp|spx|headerType) ;;
                *) PARSE_ERR='链接含暂不支持的 VLESS 参数'; return 1 ;;
            esac
        fi
        [[ -z ${result[$key]+x} ]] || { PARSE_ERR="参数重复：$key"; return 1; }
        result[$key]=$value
    done
    return 0
}

b64_decode_relaxed() {
    local s=${1//-/+}
    s=${s//_//}
    case $(( ${#s} % 4 )) in
        2) s+='==' ;;
        3) s+='=' ;;
        1) return 1 ;;
    esac
    [[ $s =~ ^[A-Za-z0-9+/]*={0,2}$ ]] || return 1
    # Reject text controls before command substitution can silently remove
    # NUL bytes or trailing newlines from credentials. Binary keys opt out.
    if [[ ${2:-0} != 1 ]]; then
        local encoded
        encoded=$(printf '%s' "$s" | base64 -d 2>/dev/null | od -An -v -tx1) || return 1
        [[ ! $encoded =~ (^|[[:space:]])(0[0-9a-f]|1[0-9a-f]|7f)([[:space:]]|$) ]] || return 1
    fi
    printf '%s' "$s" | base64 -d 2>/dev/null
}

normalize_link() {
    local link=$1
    link=${link#"${link%%[![:space:]]*}"}
    link=${link%"${link##*[![:space:]]}"}
    printf '%s' "$link"
}

parse_hostport() {
    local hp=$1
    if [[ $hp =~ ^\[(.*)\]:([0-9]+)$ ]]; then
        PARSED_HOST=${BASH_REMATCH[1]}
        PARSED_PORT=${BASH_REMATCH[2]}
        [[ $PARSED_HOST == *:* ]] || { PARSE_ERR='方括号仅用于 IPv6 地址'; return 1; }
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
        query=${main#*\?}
        main=${main%%\?*}
        local -A params=()
        parse_link_query ss "$query" params || return 1
        [[ -z ${params[plugin]:-} ]] || { PARSE_ERR='不支持带插件（plugin）的 SS 链接'; return 1; }
        case ${params[type]:-} in ''|tcp|raw) ;; *) PARSE_ERR='SS 落地只支持 TCP 传输'; return 1 ;; esac
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
        left=$(uri_decode "$main") || { PARSE_ERR='百分号编码不正确'; return 1; }
        decoded=$(b64_decode_relaxed "$left") || { PARSE_ERR='链接无法解码'; return 1; }
        [[ $decoded == *@* ]] || { PARSE_ERR='SS 链接解码后缺少 @ 分隔符'; return 1; }
        creds=${decoded%@*}
        hostport=${decoded##*@}
    fi
    [[ $creds == *:* && -n ${creds%%:*} && -n ${creds#*:} ]] || { PARSE_ERR='缺少加密方式或密码'; return 1; }
    valid_text_value "$creds" || { PARSE_ERR='SS 用户信息含控制字符或无效 UTF-8'; return 1; }
    parse_hostport "$hostport" || return 1
    local method=${creds%%:*} password=${creds#*:} klen=0 key
    case $method in
        2022-blake3-aes-128-gcm) klen=16 ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) klen=32 ;;
        aes-128-gcm|aes-256-gcm|chacha20-poly1305|chacha20-ietf-poly1305|xchacha20-poly1305|xchacha20-ietf-poly1305) ;;
        *) PARSE_ERR='此处不支持该 SS 加密方式'; return 1 ;;
    esac
    if (( klen )); then
        [[ $password != :* && $password != *: && $password != *::* ]] || {
            PARSE_ERR='SS2022 密钥之间用一个冒号分隔，首尾不加冒号'; return 1;
        }
        local -a keys=()
        IFS=: read -r -a keys <<< "$password"
        if [[ $method == 2022-blake3-chacha20-poly1305 ]] && (( ${#keys[@]} != 1 )); then
            PARSE_ERR='Xray 的 SS2022 ChaCha20 落地只接受单密钥。'
            return 1
        fi
        for key in "${keys[@]}"; do
            if [[ $key =~ ^[A-Za-z0-9+/]+={0,2}$ ]] && (( ${#key} % 4 == 0 )) \
                && [[ $(printf '%s' "$key" | base64 -d 2>/dev/null | wc -c) == "$klen" ]]; then continue; fi
            PARSE_ERR="$method 需要 $klen 字节密钥的标准 Base64 编码"
            return 1
        done
    fi
    safe_remote_target "$PARSED_HOST" "$PARSED_PORT" || return 1
    PARSED_KIND=ss
    PARSED_LABEL=$(uri_decode "$frag" 2>/dev/null || true)
    PARSED_LABEL=${PARSED_LABEL//[[:cntrl:]]/}
    [[ -n $PARSED_LABEL ]] || PARSED_LABEL='SS 落地'
    PARSED_OUTBOUND_JSON=$(jq -cn --arg h "$PARSED_HOST" --argjson p "$PARSED_PORT" --arg m "$method" --rawfile pw <(printf '%s' "$password") \
        '{protocol:"shadowsocks",settings:{address:$h,port:$p,method:$m,password:$pw}}')
}

parse_vless_link() {
    local link=$1 body main frag id rest hostport query
    local -A params=()
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
    valid_vless_id "$id" || { PARSE_ERR='用户 ID 应为 UUID 或 1-30 字节的有效文本'; return 1; }
    hostport=$(uri_decode "$hostport") || { PARSE_ERR='百分号编码不正确'; return 1; }
    parse_hostport "$hostport" || return 1
    parse_link_query vless "$query" params || return 1
    security=${params[security]:-} encryption=${params[encryption]:-}
    flow=${params[flow]:-} net=${params[type]:-}
    sni=${params[sni]:-} pbk=${params[pbk]:-} sid=${params[sid]:-}
    fp=${params[fp]:-} spx=${params[spx]:-} header=${params[headerType]:-}
    [[ -n $net && $net != raw ]] || net=tcp
    [[ $net == tcp ]] || { PARSE_ERR='VLESS 落地只支持 TCP 传输'; return 1; }
    case $security in ''|none|reality) ;; *) PARSE_ERR='VLESS 落地的 security 仅支持 none 或 reality'; return 1 ;; esac
    [[ -z $header || $header == none ]] || { PARSE_ERR='只支持 headerType=none'; return 1; }
    [[ -z $spx || ( $spx == /* && ${#spx} -le 256 && $spx != *[[:cntrl:]]* ) ]] || {
        PARSE_ERR='spiderX 必须以 / 开头、长度不超过 256，且不能包含控制字符'; return 1;
    }
    if [[ $security != reality && -n "$sni$pbk$sid$fp$spx" ]]; then
        PARSE_ERR='非 REALITY 链接带了 REALITY 参数'
        return 1
    fi
    [[ -n $encryption ]] || encryption=none
    valid_vless_encryption "$encryption" || { PARSE_ERR='VLESS encryption 格式或密钥不正确'; return 1; }
    case $flow in
        '') ;;
        xtls-rprx-vision|xtls-rprx-vision-udp443)
            [[ $security == reality || $encryption != none ]] || { PARSE_ERR='flow 只能配合 REALITY 或 VLESS-ENC 使用'; return 1; } ;;
        *) PARSE_ERR='VLESS 落地的 flow 不受支持'; return 1 ;;
    esac
    local stream
    if [[ $security == reality ]]; then
        [[ -n $sni && -n $pbk ]] || { PARSE_ERR='REALITY 落地缺少 sni 或 pbk'; return 1; }
        valid_domain "$sni" || { PARSE_ERR='REALITY 的 SNI 必须是合法域名'; return 1; }
        [[ $pbk =~ ^[A-Za-z0-9_-]{43}$ ]] || { PARSE_ERR='REALITY 公钥 pbk 须为 43 个 Base64URL 字符'; return 1; }
        [[ -z $sid ]] || valid_short_id "$sid" || { PARSE_ERR='sid 须为 2–16 位十六进制字符，位数须为偶数'; return 1; }
        [[ -n $fp ]] || fp=chrome
        case $fp in
            chrome|firefox|safari|ios|android|edge|360|qq|random|randomized|randomizednoalpn) ;;
            *) PARSE_ERR='REALITY 的指纹不受支持'; return 1 ;;
        esac
        stream=$(jq -cn --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg fp "$fp" --arg spx "${spx:-/}" \
            '{method:"raw", security:"reality",
              realitySettings:({serverName:$sni, publicKey:$pbk, fingerprint:$fp, spiderX:$spx}
                + (if $sid == "" then {} else {shortId:$sid} end))}')
    else
        stream='{"method":"raw"}'
    fi
    safe_remote_target "$PARSED_HOST" "$PARSED_PORT" || return 1
    if [[ $security != reality && $encryption == none ]]; then
        local key
        if key=$(ip_key "$PARSED_HOST"); then
            # Loopback and link-local endpoints have already been excluded by safe_remote_target.
            case $key in
                v4:10.*|v4:172.1[6-9].*|v4:172.2[0-9].*|v4:172.3[01].*|v4:192.168.*|v6:f[cd]??:*) ;;
                *) PARSE_ERR='公网 IP 的 VLESS 落地需要 REALITY 或 VLESS-ENC'; return 1 ;;
            esac
        fi
    fi
    PARSED_KIND=vless
    PARSED_LABEL=$(uri_decode "$frag" 2>/dev/null || true)
    PARSED_LABEL=${PARSED_LABEL//[[:cntrl:]]/}
    [[ -n $PARSED_LABEL ]] || PARSED_LABEL='VLESS 落地'
    PARSED_OUTBOUND_JSON=$(jq -cn --arg h "$PARSED_HOST" --argjson p "$PARSED_PORT" --rawfile id <(printf '%s' "$id") --arg enc "$encryption" \
        --arg flow "$flow" --argjson stream "$stream" \
        '{protocol:"vless",
          settings:({address:$h, port:$p, id:$id, encryption:$enc}
            + (if $flow == "" then {} else {flow:$flow} end)),
          streamSettings:$stream}')
}

parse_landing_link() {
    PARSED_OUTBOUND_JSON='' PARSED_HOST='' PARSED_PORT='' PARSED_KIND='' PARSED_LABEL='' PARSE_ERR=''
    local link
    # Trim pasted whitespace at the edges without altering credentials inside.
    link=$1
    link=${link#"${link%%[![:space:]]*}"}
    link=${link%"${link##*[![:space:]]}"}
    [[ ${#link} -le 16384 && $link != *[[:cntrl:]]* ]] || { PARSE_ERR='链接过长或含控制字符'; return 1; }
    case $link in
        ss://*) parse_ss_link "$link" ;;
        vless://*) parse_vless_link "$link" ;;
        *) PARSE_ERR='只支持 ss:// 或 vless:// 链接'; return 1 ;;
    esac
}


scheme_label() {
    case $1 in
        reality-raw) printf 'REALITY / RAW + Vision' ;;
        reality-xhttp) printf 'REALITY / XHTTP 单路' ;;
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
    [[ ! -L $DRAFT && -f $DRAFT ]] || { die '配置草稿不可读。'; return 1; }
    tmp=$(mktemp "$DRAFT.XXXXXX") || return 1
    if jq -e "$@" "$DRAFT" > "$tmp" && [[ -s $tmp ]] && mv -fT -- "$tmp" "$DRAFT"; then return 0; fi
    rm -f -- "$tmp"
    die '更新配置草稿失败，已保留原文件。'
    return 1
}
st_set() { st_filter --argjson v "$2" "$1 = \$v"; }
st_sets() { st_filter --arg v "$2" "$1 = \$v"; }

# Old state files may store the switches as text. Compare the same values in
# core selection and draft normalization, including when updating an installed core.
readonly JQ_EGRESS_FLAG='def egress_flag:
    if . == null or . == false or . == 0 or . == "0" then 0
    elif . == 1 or . == "1" then 1
    else error("出口开关须为 0 或 1") end;'

# Return a checked list for both Xray and SS-Rust. A historical snapshot
# without this field describes an installation with no domain rule.
blocked_domains_json() {
    local file=${1:-$DRAFT} default=$DEFAULT_BLOCK_DOMAIN
    [[ ${2:-} != installed ]] || default=''
    jq -ce --arg default "$default" --rawfile batch <(printf '%s' "${3:-}") '
        def domain:
            if type != "string" then error("domain must be a string") else ascii_downcase | rtrimstr(".") end
            | split(".") as $labels
            | if length <= 253 and (test("[^a-z0-9.-]") | not) and ($labels | length) >= 2
                 and all($labels[]; length >= 1 and length <= 63 and ((startswith("-") or endswith("-")) | not))
                 and ($labels[-1] | test("[a-z]"))
              then . else error("invalid domain") end;
        if .egress == null then {} elif (.egress | type) == "object" then .egress else error("invalid egress") end
        | if has("block_domains") then .block_domains else [$default | select(length > 0)] end
        | if type == "array" then . else error("block_domains must be an array") end
        | . + (if $batch == "" then []
               else $batch | gsub("，"; ",") | split(",") | map(gsub("^[ \\t]+|[ \\t]+$"; "")) end)
        | map(domain) | unique
    ' "$file"
}

# REALITY compares eight bytes. E.g. ab and ab00 select the same identity.
readonly JQ_SHORT_ID_KEY='def short_id_key:
    if type == "string" and length <= 16 and (length % 2) == 0 and (test("[^0-9a-fA-F]") | not)
    then (ascii_downcase + "0000000000000000")[:16] else error("invalid REALITY shortId") end;'

reality_short_ids() {
    # Keep the first spelling and the subscription order when reading old state.
    jq -ce "$JQ_SHORT_ID_KEY"'.reality | (.short_ids // [.short_id | select(type == "string" and length > 0)])
        | if type != "array" then error("short_ids must be an array") else
            reduce .[] as $id ({seen:{}, ids:[]}; ($id | short_id_key) as $key |
                if .seen[$key] then . else .seen[$key] = true | .ids += [$id] end) | .ids end' "${1:-$DRAFT}"
}

reality_short_id() { reality_short_ids | jq -r '.[0] // empty'; }

set_reality_short_ids() {
    st_filter --argjson ids "$1" '.reality.short_ids = $ids | .reality.short_id = $ids[0]'
}

reality_short_id_note() {
    local DRAFT=${1:-$DRAFT} ids
    [[ -f $DRAFT ]] || return 0
    scheme_has_reality "$(scheme)" || return 0
    ids=$(reality_short_ids) || return 1
    (( $(jq 'length' <<< "$ids") > 1 )) || return 0
    jq -r '"REALITY shortID：\(.[0])（订阅默认）\n其他可用 shortID：\(.[1:] | join("、"))\n客户端可选用其中任意一个 shortID。"' <<< "$ids"
}

load_state_draft() {
    DRAFT=$STAGE/draft.json
    cp -f -- "$STATE" "$DRAFT" || return 1
    normalize_draft_for_apply
}

normalize_enc_auth() {
    local auth seed
    auth=$(st .enc.auth) || return 1
    [[ -z $auth ]] || return 0
    seed=$(st .enc.server_key) || return 1
    auth=x25519
    if valid_raw_key "$seed" 64; then auth=mlkem768; fi
    st_sets .enc.auth "$auth"
}

normalize_draft_layout() {
    if [[ $(st .core.xray) == compat ]]; then st_sets .core.xray latest || return 1; fi
    local domains s
    s=$(scheme) || return 1
    if scheme_has_enc_inbound "$s" || [[ $s == reality-xhttp ]]; then normalize_enc_auth || return 1; fi
    domains=$(blocked_domains_json "$DRAFT" "${1:-}") || { die '配置中的屏蔽域名列表无效。'; return 1; }
    st_filter --rawfile domains <(printf '%s' "$domains") \
        "$JQ_EGRESS_FLAG"'.egress = {cn: (.egress.cn | egress_flag), bt: (.egress.bt | egress_flag), block_domains: ($domains | fromjson)}' || return 1
    normalize_landing_outbounds
}

normalize_draft_for_apply() {
    normalize_draft_layout "${1:-}" || return 1
    normalize_node_name || return 1
    if scheme_has_reality "$(scheme)" && [[ $(st .reality.fp) != chrome ]]; then st_sets .reality.fp chrome; fi
}

scheme() { st .scheme; }

needs_nginx() {
    scheme_has_reality "$(scheme)" && [[ $(st .reality.guard) == nginx ]]
}
ss_core() {
    if jq -e "$JQ_EGRESS_FLAG"'.scheme == "ss" and (.landings | length) == 0
        and (.egress.cn | egress_flag) == 0 and (.egress.bt | egress_flag) == 0
        and (.outbound == "v4first" or .outbound == "v6first")' "$DRAFT" >/dev/null && ss_arch_supported; then
        printf 'ss-rust'
    else
        printf 'xray'
    fi
}

needs_xray() { ! needs_ss_rust; }
needs_ss_rust() { [[ $(ss_core) == ss-rust ]]; }

port_in_draft() {
    local rc
    [[ -n $DRAFT ]] || return 1
    valid_port "$1" || return 2
    jq -se --argjson p "$((10#$1))" '
        if length == 1 and (.[0].users | type) == "array" then .[0] else error("invalid draft") end
        | [.reality.port, .reality.internal, .reality.gate, .enc.port, .ss.port, .users[].port]
        | map(select(. != null))
        | if all(.[]; type == "number" and . == floor and . >= 0 and . <= 65535)
          then index($p) != null else error("invalid port") end' "$DRAFT" >/dev/null 2>&1 && return 0
    rc=$?
    (( rc == 1 )) && return 1
    return 2
}

public_ports() {
    local s reality=false enc=false ss=false
    s=$(scheme) && in_list "$s" "${SCHEMES[@]}" || return 1
    if scheme_has_reality "$s"; then reality=true; fi
    if scheme_has_enc_inbound "$s"; then enc=true; fi
    if scheme_has_ss "$s"; then ss=true; fi
    jq -er --argjson reality "$reality" --argjson enc "$enc" --argjson ss "$ss" '
        def port:
            if type == "number" and . == floor and . >= 1 and . <= 65535 then . else error("invalid port") end;
        def row($proto; $p; $port_name): "\($proto) \($p | port) \($port_name)";
        .scheme as $scheme
        | [if $reality then row("tcp"; .reality.port; "REALITY") else empty end,
           if $enc then row("tcp"; .enc.port; "VLESS-ENC") else empty end,
           if $ss then row("tcp"; .ss.port; "SS2022"), row("udp"; .ss.port; "SS2022") else empty end,
           (.users[] | select(.port != null and .port != 0)
             | ("落地" + (.name | ltrimstr("landing"))) as $port_name
             | if ($port_name | test("[[:cntrl:]]")) then error("invalid port label") else
                 row("tcp"; .port; $port_name), (if $scheme == "ss" then row("udp"; .port; $port_name) else empty end) end)]
        | .[]' "$DRAFT"
}


draft_new() {
    local s=$1 p rc
    PREVIEW_NOTES=()
    jq -n --arg s "$s" --arg v4 "$NET_V4" --arg v6 "$NET_V6" --argjson schema "$STATE_SCHEMA" \
        --arg default_domain "$DEFAULT_BLOCK_DOMAIN" --arg name "$(default_node_name)" --argjson jitter "$(limit_jitter_new)" '{
        schema: $schema, scheme: $s, name: $name, name_initialized: 1, script: "", installed_at: "",
        net: {host: (if $v4 != "" then $v4 elif $v6 != "" then $v6 else "" end), v4: $v4, v6: $v6, manual: 0, v6_link: 1},
        outbound: (if $v4 == "" and $v6 != "" then "v6first" else "v4first" end),
        bbr: 1, firewall: "auto",
        egress: {cn: 0, bt: 0, block_domains: [$default_domain]},
        core: {xray: "latest", ss: "latest"},
        reality: {port: 0, internal: 0, gate: 0, sni: "", sni_auto: 1, private_key: "", public_key: "", short_id: "",
                  fp: "chrome", guard: "nginx", limit: "orig", limit_custom: {ua: 8192, ur: 1024, da: 32768, dr: 2048},
                  limit_jitter: $jitter, conn_ip: 256, conn_total: 4096},
        xhttp: {path: "", xmux: null, enc: 0, split: "v6_up_v4_down"},
        enc: {port: 0, rtt: "1rtt", shape: "random", auth: "x25519", ticket: "600s", pad: "off",
              pad_client: "", pad_server: "", server_key: "", client_key: ""},
        ss: {port: 0, method: "2022-blake3-aes-128-gcm", password: ""},
        users: [{name: "direct", id: "", out: "direct"}],
        landings: [],
        meta: {nginx_packages: [], nginx_hash: "", created_user: 0, selinux_note: 0, fw_rules: [], extra_packages: []}
    }' > "$DRAFT"
    PORT_NOTE=''
    if scheme_has_reality "$s"; then
        p=443
        rc=0; port_foreign tcp 443 || rc=$?
        (( rc <= 1 )) || { port_query_failed; return 1; }
        if (( rc == 0 )); then
            p=$(random_free_port) || return 1
            if [[ $s == triple ]]; then note_add "TCP 443 被 $(port_owner_label tcp 443) 占用，REALITY 改用随机端口 $p。"
            else PORT_NOTE="443 已被 $(port_owner_label tcp 443) 占用"; fi
        fi
        st_set .reality.port "$p"
        if selinux_enforcing; then
            st_sets .reality.guard xray
            st_set .meta.selinux_note 1
        fi
    fi
    if scheme_has_ss "$s"; then
        p=$(random_free_port) || return 1
        st_set .ss.port "$p"
    fi
    if scheme_has_enc_inbound "$s"; then
        p=$(random_free_port) || return 1
        st_set .enc.port "$p"
    fi
    if [[ $(scheme_transport "$s") == xhttp ]]; then
        p=$(random_path) || return 1
        st_sets .xhttp.path "$p"
    fi
    if [[ $s == enc-split ]]; then
        st_filter '.enc.auth = "mlkem768" | .enc.pad = "aggressive"'
    fi
    return 0
}

finalize_identity() {
    local xray=$1 s out i kind id rows p private public secret field rc ids ss_bytes=0 ss_format=saved
    local -a generated=()
    s=$(scheme)
    if scheme_has_ss "$s"; then
        ss_bytes=$(ss_key_bytes "$(st .ss.method)") || return 1
        if needs_ss_rust; then ss_format=canonical; fi
    fi
    # Validate the JSON strings before Bash can strip NULs or trailing newlines.
    # Existing VLESS IDs need no update. SS entry passwords also need length checks.
    rows=$(jq -r --arg scheme "$s" '.users | to_entries[] | .value as $user |
        ($user.id | if . == null then "" elif type == "string" and (test("[[:cntrl:]]") | not)
            then . else error("invalid entry credential") end) as $id |
        (if $scheme == "ss" and $user.name != "direct" then [.key, "ss", $id]
         elif $id == "" then [.key, "uuid", ""]
         else empty end) | @tsv' "$DRAFT") || {
        die '入口凭据须为不含控制字符的文本，请核对草稿。'; return 1;
    }
    while IFS=$'\t' read -r i kind id; do
        [[ -n $i ]] || continue
        if [[ $kind == ss ]]; then
            if [[ -n $id ]]; then
                valid_ss_password "$id" "$ss_bytes" saved || { die 'SS2022 独立入口密码长度或格式有误，请在「SS2022 → 填写密码」修正。'; return 1; }
                continue
            fi
            id=$(rand_b64 "$ss_bytes") || return 1
        else
            id=$(new_uuid) || return 1
        fi
        [[ -n $id ]] || { die '生成用户凭据失败。'; return 1; }
        generated+=("$i"$'\t'"$id")
    done <<< "$rows"
    if (( ${#generated[@]} )); then
        st_filter --argjson count "${#generated[@]}" --rawfile updates <(printf '%s\n' "${generated[@]}") '
            ($updates | split("\n")) as $rows
            | if ($rows | length) != ($count + 1) or $rows[-1] != "" then error("incomplete credential list")
              else reduce ($rows[:-1][] | split("\t")) as $pair
                (.; .users[($pair[0] | tonumber)].id = $pair[1]) end' || return 1
    fi
    if scheme_has_reality "$s"; then
        private=$(st .reality.private_key) || return 1
        public=$(st .reality.public_key) || return 1
        if [[ -z $private ]]; then
            [[ -z $public ]] || { die 'REALITY 私钥缺失。请从备份恢复原密钥对，或在「高级设置 → 密钥对」导入新密钥对并重新分发链接。'; return 1; }
            out=$(timeout -k 2 15 "$xray" x25519) || { die 'Xray 生成 REALITY 密钥失败或超时。'; return 1; }
            private=$(awk '/PrivateKey:|Private key:/{print $NF; exit}' <<< "$out")
            public=$(awk '/Password \(PublicKey\):|Password:|Public key:/{print $NF; exit}' <<< "$out")
            valid_raw_key "$private" 32 && valid_raw_key "$public" 32 || { die '无法解析 REALITY 密钥。'; return 1; }
            store_keypair reality "$private" "$public" || return 1
        else
            local derived
            valid_raw_key "$private" 32 && derived=$(keypair_public x25519 "$private") && valid_raw_key "$derived" 32 ||
                { die '无法从 REALITY 私钥派生公钥，请检查密钥和 OpenSSL。'; return 1; }
            if [[ -z $public ]]; then
                st_sets .reality.public_key "$derived" || return 1
            elif [[ $derived != "$public" ]]; then
                die 'REALITY 公私钥不匹配，请在「高级设置 → 密钥对」重新导入。'; return 1
            fi
        fi
        ids=$(reality_short_ids) || return 1
        if [[ $ids == '[]' ]]; then
            secret=$(rand_hex 8) || return 1
            [[ $secret =~ ^[0-9a-f]{16}$ ]] || { die '生成 REALITY shortId 失败。'; return 1; }
            ids=$(jq -cn --arg sid "$secret" '[$sid]') || return 1
        fi
        set_reality_short_ids "$ids" || return 1
        if [[ $(st .reality.guard) == nginx ]]; then field=.reality.internal; else field=.reality.gate; fi
        p=$(st "$field")
        rc=0
        if [[ $p != 0 ]]; then
            port_foreign tcp "$p" || rc=$?
            (( rc <= 1 )) || { port_query_failed; return 1; }
        fi
        if [[ $p == 0 ]] || (( rc == 0 )); then
            p=$(random_free_port) || return 1
            st_set "$field" "$p"
        fi
    fi
    if needs_enc_keys; then
        private=$(st .enc.server_key) || return 1
        public=$(st .enc.client_key) || return 1
        if [[ -z $private && -n $public ]]; then
            die 'VLESS-ENC 私钥缺失。请从备份恢复原密钥对，或在「高级设置 → 密钥对」导入新密钥对并重新分发链接。'
            return 1
        fi
        local auth want line_dec line_enc private_bytes=32 public_bytes=32
        normalize_enc_auth || return 1
        auth=$(st .enc.auth) || return 1
        case $auth in
            x25519) want='Authentication: X25519' ;;
            mlkem768) want='Authentication: ML-KEM-768'; private_bytes=64; public_bytes=1184 ;;
            *) die '无法识别 VLESS-ENC 的认证方式，请检查草稿或恢复备份。'; return 1 ;;
        esac
        if [[ -z $public ]]; then
            if [[ -n $private ]]; then
                valid_raw_key "$private" "$private_bytes" && public=$(keypair_public "$auth" "$private") && valid_raw_key "$public" "$public_bytes" ||
                    { die "无法从 $(auth_label "$auth") 私钥恢复公钥。请检查本机 OpenSSL 是否支持该算法，或从备份恢复原密钥对。"; return 1; }
            else
                out=$(timeout -k 2 15 "$xray" vlessenc) || { die 'Xray 生成 VLESS-ENC 密钥失败或超时。'; return 1; }
                line_dec=$(awk -v w="$want" '/Authentication:/{f=index($0,w)>0;next} f && /"decryption":/{sub(/.*"decryption": *"/,""); sub(/".*/,""); print; exit}' <<< "$out")
                line_enc=$(awk -v w="$want" '/Authentication:/{f=index($0,w)>0;next} f && /"encryption":/{sub(/.*"encryption": *"/,""); sub(/".*/,""); print; exit}' <<< "$out")
                private=${line_dec##*.}; public=${line_enc##*.}
                valid_raw_key "$private" "$private_bytes" && valid_raw_key "$public" "$public_bytes" ||
                    { die '无法解析 Xray 生成的 VLESS-ENC 密钥。'; return 1; }
            fi
            store_keypair enc "$private" "$public" || return 1
        else
            valid_raw_key "$private" "$private_bytes" && valid_raw_key "$public" "$public_bytes" ||
                { die 'VLESS-ENC 密钥格式与认证方式不符，请从备份导入原密钥对。'; return 1; }
            # Older OpenSSL versions need an actual handshake to verify a saved ML-KEM pair.
            local derived_enc
            if derived_enc=$(keypair_public "$auth" "$private"); then
                [[ $derived_enc == "$public" ]] || { die 'VLESS-ENC 公私钥不匹配，请从备份导入配对的密钥。'; return 1; }
            elif [[ $auth == mlkem768 ]]; then
                verify_mlkem_pair "$xray" "$private" "$public" || {
                    die 'ML-KEM 本机握手未通过。请检查密钥对和回环监听后重新应用。'; return 1;
                }
            else
                die '无法核验 VLESS-ENC 的 X25519 密钥，请检查 OpenSSL。'; return 1
            fi
        fi
    fi
    if (( ss_bytes )); then
        secret=$(jq -er '.ss.password | if . == null then "" else strings | select(test("[[:cntrl:]]") | not) end' "$DRAFT") || {
            die 'SS2022 主入口密码须为不含控制字符的文本，请在「SS2022 → 填写密码」修正。'; return 1;
        }
        if [[ -z $secret ]]; then
            secret=$(rand_b64 "$ss_bytes") && valid_ss_password "$secret" "$ss_bytes" || { die '生成 SS2022 密钥失败。'; return 1; }
            st_filter --rawfile pw <(printf '%s' "$secret") '.ss.password = $pw' || return 1
        elif ! valid_ss_password "$secret" "$ss_bytes" "$ss_format"; then
            die 'SS2022 主入口密码无效，请在「SS2022 → 填写密码」输入对应长度的标准 Base64。'; return 1
        fi
    fi
    return 0
}

ss_key_bytes() {
    case $1 in
        2022-blake3-aes-128-gcm) printf '16' ;;
        2022-blake3-aes-256-gcm) printf '32' ;;
        *) die 'SS2022 加密方式无效。'; return 1 ;;
    esac
}

valid_ss_password() {
    local LC_ALL=C key=$1 bytes=$2 canonical
    [[ $key =~ ^[A-Za-z0-9+/]+={0,2}$ ]] && (( ${#key} == (bytes + 2) / 3 * 4 )) || return 1
    case $bytes in
        16) [[ $key == *== ]] || return 1 ;;
        32) [[ $key == *= && $key != *== ]] || return 1 ;;
        *) return 1 ;;
    esac
    # Preserve older Xray spellings that map to the same bytes. SS-Rust uses canonical input.
    [[ ${3:-} != saved ]] || return 0
    canonical=$(printf '%s' "$key" | base64 -d 2>/dev/null | base64 -w 0) || return 1
    [[ $key == "$canonical" ]]
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

valid_enc_ticket() {
    [[ $1 =~ ^([0-9]{1,5})(-([0-9]{1,5}))?$ ]] || return 1
    local lo=${BASH_REMATCH[1]} hi=${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}
    (( 10#$lo <= 10#$hi && 10#$hi <= 86400 ))
}

valid_padding() {
    local p=$1 seg idx=0 prob min max total=0
    [[ $p =~ ^[0-9]+-[0-9]+-[0-9]+(\.[0-9]+-[0-9]+-[0-9]+)*$ ]] || return 1
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
    # Xray ParsePadding permits 18 + 65535 bytes across length segments.
    (( total <= 65553 ))
}

outbound_label() {
    case $1 in
        v4first) printf 'IPv4 优先' ;; v6first) printf 'IPv6 优先' ;;
        v4only) printf '只用 IPv4' ;; v6only) printf '只用 IPv6' ;;
    esac
}

outbound_xray_strategy() {
    case $1 in
        v4first) printf 'UseIPv4v6' ;; v6first) printf 'UseIPv6v4' ;;
        v4only) printf 'ForceIPv4' ;; v6only) printf 'ForceIPv6' ;;
    esac
}

limit_jitter_new() {
    shuf -i 80-125 -n 4 | jq -cs .
}

limit_preset() {
    # 6 values: upload threshold / steady rate / burst, download threshold / steady rate / burst.
    # 4 independent jitter percentages are retained for per-machine variability.
    local base
    case $1 in
        orig) base='1048576 262144 524288 4194304 1048576 2097152' ;;
        std) base='4194304 524288 1048576 16777216 2097152 4194304' ;;
        *) return 1 ;;
    esac
    jq -r --arg b "$base" '
      (.reality.limit_jitter // [100,100,100,100]) as $j
      | ($b | split(" ") | map(tonumber)) as $v
      | [($v[0]*$j[0]/100|floor), ($v[1]*$j[1]/100|floor), ($v[2]*$j[1]/100|floor),
         ($v[3]*$j[2]/100|floor), ($v[4]*$j[3]/100|floor), ($v[5]*$j[3]/100|floor)]
      | map(tostring) | join(" ")' "$DRAFT"
}

limit_values() {
    case $(st .reality.limit) in
        off) return 0 ;;
        orig|std) limit_preset "$(st .reality.limit)" ;;
        custom)
            jq -r '.reality.limit_custom |
              "\(.ua) \(.ur) \(.ur * 2) \(.da) \(.dr) \(.dr * 2)"' "$DRAFT" ;;
        *) return 1 ;;
    esac
}

limit_label() {
    case $(st .reality.limit) in
        off) printf '回落不限速' ;;
        orig) printf '严格' ;;
        std) printf '宽松' ;;
        custom) printf '自定义' ;;
    esac
}

limit_text() {
    if (( $# == 0 )) && [[ $(st .reality.limit) == off ]]; then
        printf '回落不限速，匹配站点的未认证连接仍可转发'
        return 0
    fi
    local -a lv=()
    read -r -a lv <<< "${1:-$(limit_values)}"
    (( ${#lv[@]} == 6 )) || return 1
    printf '上行 %s 后 %s/s\n下行 %s 后 %s/s' "$(human_bytes "${lv[0]}")" "$(human_bytes "${lv[1]}")" \
        "$(human_bytes "${lv[3]}")" "$(human_bytes "${lv[4]}")"
}

rtt_label() { if [[ $1 == 1rtt ]]; then printf '1-RTT'; else printf '0-RTT'; fi; }
auth_label() { if [[ $1 == mlkem768 ]]; then printf 'ML-KEM-768'; else printf 'X25519'; fi; }

pad_label() {
    case $1 in
        gentle) printf '温和' ;; aggressive) printf '激进' ;; custom) printf '自定义' ;; *) printf '核心默认' ;;
    esac
}

split_label() {
    if [[ $(st .xhttp.split) == v6_up_v4_down ]]; then printf 'IPv6 上行，IPv4 下行'
    else printf 'IPv4 上行，IPv6 下行'; fi
}

xmux_mode_index() {
    jq -r '.xhttp.xmux | if . == null or . == {} then 1 elif has("maxConcurrency") then 2 else 3 end' "$DRAFT"
}

xmux_label() {
    case $(xmux_mode_index) in
        2) printf '每条连接 %s 路' "$(st .xhttp.xmux.maxConcurrency)" ;;
        3) printf '%s 条底层连接' "$(st .xhttp.xmux.maxConnections)" ;;
        *) printf '客户端默认' ;;
    esac
}

enc_summary() {
    printf '%s，%s' "$(rtt_label "$(st .enc.rtt)")" "$(auth_label "$(st .enc.auth)")"
}

enc_detail() {
    local v
    v="外观 $(st .enc.shape)"
    [[ $(st .enc.pad) == off ]] || v+="，$(pad_label "$(st .enc.pad)")填充"
    printf '%s' "$v"
}

core_label() {
    local v iv=''
    v=$(st ".core.$1")
    if [[ $MODE == modify ]]; then iv=$(installed_version "$1"); fi
    case $v in
        compat) printf '旧版配置（更新时自动升级）' ;;
        latest)
            [[ $(jq -r ".core.$1 // empty" "$STATE" 2>/dev/null) == latest ]] || iv=''
            if [[ -n $iv ]]; then printf '最新正式版 %s' "$iv"; else printf '最新正式版'; fi ;;
        *) printf '%s 固定' "$v" ;;
    esac
}

node_name() {
    local name
    name=$(st .name) || return 1
    if [[ -n $name ]]; then printf '%s' "$name"; else default_node_name; fi
}

default_node_name() {
    local h
    h=$(hostname -s 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || true)
    h=${h%%.*}
    [[ $h =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ && ${h,,} != localhost* ]] || h=xray
    printf '%s' "${h:0:24}"
}

set_node_name() {
    st_filter --arg name "$1" '.name = $name | .name_initialized = 1'
}

normalize_node_name() {
    # Older records do not distinguish the built-in names from a manual choice.
    [[ $(st .name_initialized) != 1 ]] || return 0
    local name
    name=$(st .name) || return 1
    case ${name,,} in
        ''|zdd|zdd-xray|doudou|doudou-xray|zxray) name=$(default_node_name) || return 1 ;;
    esac
    set_node_name "$name"
}

valid_node_name() {
    local w
    valid_text_value "$1" || return 1
    [[ -n $1 && $1 != *[[:space:]#?\&/\\%\"\']* ]] || return 1
    # Ignore invisible joiners when checking that a name has a visible base.
    str_width "${1//$'\u200d'/}" w
    (( w > 0 )) || return 1
    if [[ $1 == *$'\u200d'* ]]; then str_width "$1" w; fi
    (( w >= 1 && w <= 24 ))
}

scheme_tag() {
    case $1 in
        reality-raw|triple) printf 'REALITY' ;;
        reality-xhttp) printf 'XHTTP' ;;
        reality-split) printf 'XHTTP分离' ;;
        ss|dual) printf 'SS' ;;
        enc) printf 'VLESS-ENC' ;;
        enc-split) printf 'ENC分离' ;;
    esac
}

name_example() {
    local e
    e="链接里显示为 $(node_name)-$(scheme_tag "$(scheme)")"
    case $(scheme) in dual|triple) e+=' 等' ;; esac
    printf '%s' "$e"
}

can_attach_v6_link() {
    local v4
    v4=$(st .net.v4) || return 1
    [[ -n $v4 && -n $(st .net.v6) && $(st .net.host) == "$v4" ]]
}

v6_links_on() {
    can_attach_v6_link && [[ $(st '.net.v6_link // 1') == 1 ]]
}

note_add() { PREVIEW_NOTES+=("$1"); }


CS_DEF=1 CS_MARK=0
PV_KEYS=()
declare -A PV_ORIG=() PV_FP=()

cs_build() {
    local i
    local -a name=('RAW + Vision' 'XHTTP 单路' 'XHTTP 上下行分离' 'SS2022' 'VLESS-ENC'
        'SS2022 + VLESS-ENC' 'REALITY + SS + ENC' 'XHTTP + ENC 分离')
    local -a note=('常规安装' '可选 XMUX' '需要双栈'
        '支持 TCP 和 UDP' '独立加密入口' '两个独立端口' '三个独立端口'
        '需要双栈')
    local -a group=([0]='REALITY' [3]='落地或专线' [5]='多协议混合' [7]='实验性方案')
    ui_page '选择方案'
    for i in "${!SCHEMES[@]}"; do
        if [[ -n ${group[$i]:-} ]]; then
            (( i == 0 )) || ui_blank
            ui_group "${group[$i]}"
        fi
        tui_opt $(( i + 1 )) "${name[$i]}" "${note[$i]}" $(( i + 1 == CS_MARK )) 20
    done
    TUI_FOOT='上下键 移动   回车 选择   Esc 返回'
    TUI_FOOT_PLAIN="1-${#SCHEMES[@]} 选择   0 返回"
}

choose_scheme() {
    local __cs_var=$1
    CS_DEF=${2:-1} CS_MARK=${3:-0}
    tui_menu cs_build $(( CS_DEF - 1 )) ''
    if [[ $TUI_KEY == ENTER ]]; then printf -v "$__cs_var" '%s' "${SCHEMES[$TUI_CUR]}"
    else printf -v "$__cs_var" '%s' ''; fi
}

scheme_index() {
    local i
    for i in "${!SCHEMES[@]}"; do
        if [[ ${SCHEMES[$i]} == "$1" ]]; then printf '%d' $(( i + 1 )); return 0; fi
    done
    printf '1'
}


preview_items() {
    local s=${1:-$(scheme)}
    printf '%s\n' port
    if scheme_has_reality "$s"; then printf '%s\n' sni; fi
    printf '%s\n' addr name
    case $s in dual|triple|enc-split) ;; *) printf '%s\n' landings ;; esac
    case $s in
        reality-xhttp) printf '%s\n' xhttp ;;
        reality-split|enc-split) printf '%s\n' split ;;
    esac
    if scheme_has_ss "$s"; then printf '%s\n' ssm; fi
    if scheme_has_enc_inbound "$s"; then printf '%s\n' encp; fi
    if scheme_has_reality "$s"; then
        printf '%s\n' guard
        if [[ $(st .reality.guard) == nginx ]]; then printf '%s\n' conn; fi
        printf '%s\n' limit
    fi
    printf '%s\n' egress system
}

item_label() {
    case $1 in
        port) printf '端口' ;;
        sni) printf '伪装站点' ;;
        addr) printf '节点地址' ;;
        name) printf '节点名称' ;;
        landings) printf '出口' ;;
        xhttp) printf 'XHTTP' ;;
        split) printf '上下行分离' ;;
        ssm) printf 'SS2022' ;;
        encp) printf 'VLESS-ENC' ;;
        guard) printf '过滤方式' ;;
        conn) printf '连接上限' ;;
        limit) printf '回落限速' ;;
        egress) printf '出口限制' ;;
        system) printf '高级设置' ;;
    esac
}

item_help() {
    case $1 in
        port) printf '%s' '修改端口后，请同步更新客户端。' ;;
        sni) printf '%s' '未通过认证且 SNI 匹配的连接会转给此站。应用后请更新客户端 SNI。' ;;
        addr) printf '%s' '分享链接使用的公网 IP 或域名。' ;;
        name) printf '%s' '客户端节点列表中的名称。' ;;
        landings) printf '%s' '默认从本机直出。每个远端落地有独立的节点链接。' ;;
        xhttp) printf '%s' 'XHTTP 的路径、连接复用（XMUX），以及可叠加的 VLESS 加密。' ;;
        split) printf '%s。客户端需同时支持 IPv4 和 IPv6。' "$(split_label)" ;;
        ssm) printf '%s' '选择加密方式，填写固定密码或生成随机密码。' ;;
        encp) printf '%s' 'VLESS 加密的握手方式、认证方式、外观和填充。' ;;
        guard) printf '%s\n%s' '只允许指定伪装站点的 SNI。' '可用 Nginx 前置或 Xray 内置过滤。' ;;
        conn) printf '%s' 'Nginx 在验证之前限制并发连接，超出的直接断开。' ;;
        limit) printf '%s\n%s' '按连接限制转发到伪装站点的速度。' '关闭限速后仍可回落。' ;;
        egress) printf '%s' '设置本机直出的域名名单、大陆域名/IP 和 BT 限制。' ;;
        system) printf '%s' '设置出站 IP、BBR、协议凭据和核心版本。' ;;
    esac
}

item_value() {
    local s=${2:-$(scheme)} v n note
    case $1 in
        port)
            local -a parts=()
            if scheme_has_reality "$s"; then parts+=("REALITY $(st .reality.port)"); fi
            if scheme_has_ss "$s"; then parts+=("SS $(st .ss.port)"); fi
            if scheme_has_enc_inbound "$s"; then parts+=("ENC $(st .enc.port)"); fi
            n=$(jq '[.users[] | select((.port // 0) > 0)] | length' "$DRAFT")
            if (( ${#parts[@]} == 1 )); then
                v=${parts[0]##* }
                if [[ -n $PORT_NOTE ]]; then v+=$'\t'$PORT_NOTE
                elif (( n > 0 )); then v+=$'\t'"落地另开 $n 个端口"; fi
            else
                v=$(join_by '，' "${parts[@]}")
            fi
            printf '%s' "$v" ;;
        sni)
            v=$(st .reality.sni)
            if [[ -z $v ]]; then printf '%s' "未选择"$'\t''安装前需要先选好'; return 0; fi
            if [[ $(st .reality.sni_auto) != 1 ]]; then v+=$'\t手动指定'
            elif (( SNI_BEST_MS > 0 )); then v+=$'\t'"自动测速 $SNI_BEST_MS ms"
            else v+=$'\t自动挑选'; fi
            printf '%s' "$v" ;;
        addr)
            if scheme_is_split "$s"; then
                printf 'IPv4 %s\nIPv6 %s' "$(st .net.v4 | grep . || printf '未填写')" "$(st .net.v6 | grep . || printf '未填写')"
            else
                v=$(st .net.host)
                if [[ -z $v ]]; then printf '%s' "未填写"$'\t''安装前需要先填好'; return 0; fi
                if [[ $v == "$(st .net.v4)" ]] && v6_links_on; then v+=$'\t另附 IPv6 链接'; fi
                printf '%s' "$v"
            fi ;;
        name) printf '%s\t%s' "$(node_name)" "$(name_example)" ;;
        landings)
            n=$(jq '.landings | length' "$DRAFT")
            if (( n == 0 )); then printf '本机直出'
            else
                printf '本机直出 + %d 个落地' "$n"
                while IFS=$'\t' read -r v note; do printf '\n\t%s  %s' "${v/landing/落地}" "$note"; done < <(jq -r '.landings[:3][]
                    | [.tag, "\(.kind) \(if (.host | test(":")) then "[\(.host)]" else .host end):\(.port)"] | @tsv' "$DRAFT")
                (( n <= 3 )) || printf '\n\t还有 %d 个' $(( n - 3 ))
            fi ;;
        xhttp)
            v="XMUX $(xmux_label)，VLESS 加密"
            if [[ $(st .xhttp.enc) == 1 ]]; then v+=' 开'; else v+=' 关'; fi
            printf '%s\n路径 %s' "$v" "$(st .xhttp.path)" ;;
        split) printf '%s\t路径 %s' "$(split_label)" "$(st .xhttp.path)" ;;
        ssm) st .ss.method ;;
        encp) printf '%s\t%s' "$(enc_summary)" "$(enc_detail)" ;;
        guard)
            if [[ $(st .reality.guard) == nginx ]]; then printf 'Nginx 前置\t只放行伪装站点的 SNI'
            else printf 'Xray 内置\t只放行伪装站点的 SNI，无连接上限'; fi ;;
        conn) printf '每个 IP %s，总计 %s' "$(st .reality.conn_ip)" "$(st .reality.conn_total)" ;;
        limit) printf '%s\n' "$(limit_label)"; limit_text | sed $'s/^/\t/' ;;
        egress) egress_label ;;
        system) outbound_label "$(st .outbound)" ;;
    esac
}

same_item() {
    local a=$2 b=$3
    if [[ $1 == sni ]]; then
        # The selected domain and mode are saved. Probe timing lasts for this session.
        a=${a/$'\t自动测速 '*/$'\t自动挑选'}
        b=${b/$'\t自动测速 '*/$'\t自动挑选'}
    fi
    [[ $a == "$b" ]]
}

split_vn() {
    local __sv_l=$1
    printf -v "$2" '%s' "${__sv_l%%$'\t'*}"
    if [[ $__sv_l == *$'\t'* ]]; then printf -v "$3" '%s' "${__sv_l#*$'\t'}"; else printf -v "$3" '%s' ''; fi
}

line_text() {
    local __lt_v __lt_n
    split_vn "$1" __lt_v __lt_n
    __lt_v=${__lt_v:-$__lt_n}
    printf -v "$2" '%s' "${__lt_v#"${__lt_v%%[! ]*}"}"
}

first_value() {
    local __fv_l=${1%%$'\n'*}
    printf -v "$2" '%s' "${__fv_l%%$'\t'*}"
}

pv_snapshot() {
    local src=${1:-$DRAFT} key s
    local -a keys=(port sni addr name landings xhttp split ssm encp guard conn limit egress system)
    local DRAFT=$STAGE/pv-base.json
    cp -f -- "$src" "$DRAFT" || return 1
    # Compare equivalent state layouts. Keep the installed fingerprint and IPs
    # in this baseline so actual changes to client links remain visible.
    if [[ $src == "$STATE" ]]; then normalize_draft_layout installed || return 1
    else normalize_draft_layout || return 1; fi
    PV_ORIG=() PV_FP=()
    # Hidden fields can become visible after a guard/scheme change.
    s=$(scheme) || return 1
    read_item_fingerprints PV_FP "${keys[@]}" || return 1
    for key in "${keys[@]}"; do
        PV_ORIG[$key]=$(item_value "$key" "$s")
    done
}

links_will_change() {
    local old=$STAGE/nodes-before.json preview=$STAGE/pv-nodes.ndjson err=$STAGE/pv-nodes.err rc=0 NODES_TMP
    [[ -f $old && ! -L $old ]] || return 2
    render_nodes "$preview" 2>"$err" || return 2
    [[ ! -s $err ]] || return 2
    # Compare the subscriptions actually published and rendered, including legacy fingerprints.
    jq -ne --slurpfile before "$old" --slurpfile after "$preview" '
        def links:
            select(type == "array" and length > 0 and all(.[];
                (.label | type == "string") and (.link | type == "string" and length > 0)))
            | map([.label, .link]) | sort;
        select(($before | length) == 1) | ($before[0] | links) != ($after | links)
    ' >/dev/null 2>>"$err" || rc=$?
    case $rc in 0|1) return "$rc" ;; *) return 2 ;; esac
}

# Each filter emits one compact JSON value. Tabs and newlines in fields stay escaped.
read_item_fingerprints() {
    local -n result=$1
    shift
    local key f filter='' rows i
    local -a keys=("$@") values=()
    result=()
    (( $# )) || return 0
    for key in "$@"; do
        case $key in
            port) f='[.reality.port, .ss.port, .enc.port, [.users[] | .port // 0 | select(. > 0)]]' ;;
            sni) f='[.reality.sni, (.reality.sni_auto // 0)]' ;;
            addr) f='[.net.host, .net.v4, .net.v6, (.net.v6_link // 1)]' ;;
            name) f='[.name]' ;;
            landings) f='[.landings, [.users[] | select(.out != "direct") | {name, out}]]' ;;
            xhttp) f='[.xhttp, (if .xhttp.enc == 1 then (.enc | del(.port, .server_key)) else null end)]' ;;
            split) f='[.xhttp]' ;;
            ssm) f='[.ss.method, .ss.password, [.users[] | select((.port // 0) > 0) | .id]]' ;;
            encp) f='[.enc | del(.port, .server_key)]' ;;
            guard) f='[.reality.guard]' ;;
            conn) f='[.reality.conn_ip, .reality.conn_total]' ;;
            limit) f='[.reality.limit, .reality.limit_custom, .reality.limit_jitter]' ;;
            egress) f='[.egress.cn // 0, .egress.bt // 0, .egress.block_domains]' ;;
            system) f='[.outbound, .bbr, .firewall, .core, (.reality.fp | if . == null or . == "" then "chrome" else . end),
                        .reality.public_key, (.reality | .short_ids // [.short_id | select(type == "string" and length > 0)]), .enc.client_key,
                        [.users[] | select((.port // 0) == 0) | [.name, .id]]]' ;;
            *) f='null' ;;
        esac
        filter+="${filter:+,}($f)"
    done
    rows=$(jq -c "$filter" "$DRAFT") && [[ -n $rows ]] || { die '无法读取配置预览的比较数据。'; return 1; }
    mapfile -t values <<< "$rows"
    (( ${#values[@]} == ${#keys[@]} )) || { die '配置草稿内容不完整，无法比较变更。'; return 1; }
    for i in "${!keys[@]}"; do result[${keys[i]}]=${values[i]}; done
}

item_changed() {
    [[ -n ${PV_ORIG[$1]+x} ]] || return 1
    ! same_item "$1" "$2" "${PV_ORIG[$1]}" || [[ $3 != "${PV_FP[$1]:-}" ]]
}

pv_build() {
    local key v note n=0 i full orig changed=0 s
    local -a rows=() vals=() olds=() marks=()
    local -A page_fp=()
    s=$(scheme) || return 1
    mapfile -t rows < <(preview_items "$s")
    n=${#rows[@]}
    if [[ $MODE == modify ]]; then
        read_item_fingerprints page_fp "${rows[@]}" || return 1
        ui_page '当前配置' "$(scheme_label "$s")"
    else ui_page '预览' "$(scheme_label "$s")"; fi
    KEY_W=${#n}
    PV_KEYS=()
    for key in "${rows[@]}"; do
        PV_KEYS+=("$key")
        full=$(item_value "$key" "$s") || return 1
        mapfile -t vals <<< "$full"
        olds=() marks=()
        if [[ $MODE == modify ]] && item_changed "$key" "$full" "${page_fp[$key]}"; then
            changed=$(( changed + 1 ))
            mapfile -t olds <<< "${PV_ORIG[$key]}"
            for i in "${!vals[@]}"; do same_item "$key" "${vals[$i]}" "${olds[$i]:-}" || marks[i]=1; done
            (( ${#marks[@]} )) || marks[0]=2
        fi
        for i in "${!vals[@]}"; do
            split_vn "${vals[$i]}" v note
            if [[ -n ${marks[$i]:-} ]]; then
                first_value "${olds[$i]:-}" orig
                note=${note#"${note%%[! ]*}"}
                [[ -z $note ]] || v+=${v:+  }$note
                v="$C_YELLOW* $v$C_RESET"
                note=''
                if [[ $key == system ]]; then note=''
                elif [[ ${marks[$i]} == 2 ]]; then note='参数已修改'
                elif (( i == 0 )) && [[ -n $orig && $orig != "${vals[$i]%%$'\t'*}" ]]; then note="原 $orig"; fi
            fi
            if (( i == 0 )); then tui_item "${#PV_KEYS[@]}" "$(item_label "$key")" "$v" "$note" "$(item_help "$key")"
            else ui_cont "$v" "$note"; fi
        done
    done
    if (( ${#PREVIEW_NOTES[@]} )); then
        ui_blank
        for i in "${!PREVIEW_NOTES[@]}"; do ui_warn "${PREVIEW_NOTES[$i]}"; done
    fi
    ui_rule
    if [[ $MODE == modify ]]; then
        if sni_pool_changed; then changed=$(( changed + 1 )); fi
        if (( changed > 0 )); then v="已改 $changed 项"; else v='还没有修改'; fi
        tui_item a '应用修改' '' "$v" '核对变更后写入配置并重启服务。'
        tui_item c '换方案' '' '重新生成节点' '应用新方案后，旧节点通常需要更新。'
        TUI_FOOT_PLAIN="1-$n 修改   a 应用修改   c 换方案   0 返回"
    else
        tui_item y '开始安装' '' '部署当前方案' '下载核心、校验配置并启动服务。'
        TUI_FOOT_PLAIN="1-$n 修改   y 开始安装   0 返回"
    fi
    TUI_HELP_H=2
    TUI_FOOT='上下键 移动   回车 选择   Esc 返回'
}

preview_ready() {
    local s
    s=$(scheme)
    if scheme_has_reality "$s" && [[ -z $(st .reality.sni) ]]; then
        ui_warn '还没有选择伪装站点。'
        ui_pause
        edit_sni
        return 1
    fi
    if scheme_is_split "$s" && { ! valid_ipv4 "$(st .net.v4)" || ! valid_ipv6 "$(st .net.v6)"; }; then
        ui_warn '上下行分离需要填写有效的 IPv4 和 IPv6 地址。'
        ui_pause
        edit_addr
        return 1
    fi
    if ! scheme_is_split "$s" && [[ -z $(st .net.host) ]]; then
        ui_warn '还没有填写节点地址。'
        ui_pause
        edit_addr
        return 1
    fi
    return 0
}

PC_TITLE='应用修改'

pc_build() {
    local key cur o v n=0 lab m i shown detail s old_s
    local -a ol=() nl=()
    local -A page_fp=()
    s=$(scheme) && old_s=$(jq -r .scheme "$STAGE/pv-base.json") || return 1
    ui_page "$PC_TITLE" "$(scheme_label "$s")"
    if [[ $old_s != "$s" ]]; then
        ui_kv '方案' "$(scheme_label "$old_s") -> $(scheme_label "$s")"
        n=1
    else
        read_item_fingerprints page_fp "${PV_KEYS[@]}" || return 1
        for key in "${PV_KEYS[@]}"; do
            cur=$(item_value "$key" "$s") || return 1
            item_changed "$key" "$cur" "${page_fp[$key]}" || continue
            n=$(( n + 1 ))
            mapfile -t ol <<< "${PV_ORIG[$key]}"
            mapfile -t nl <<< "$cur"
            lab=$(item_label "$key")
            m=${#ol[@]}
            (( ${#nl[@]} <= m )) || m=${#nl[@]}
            shown=0
            for (( i = 0; i < m; i++ )); do
                if same_item "$key" "${ol[$i]:-}" "${nl[$i]:-}"; then continue; fi
                line_text "${ol[$i]:-}" o
                line_text "${nl[$i]:-}" v
                if [[ $o == "$v" ]]; then o=${ol[$i]//$'\t'/ } v=${nl[$i]//$'\t'/ }; fi
                pc_row "$lab" "${o:-无}" "${v:-无}"
                lab=''
                shown=1
            done
            if (( ! shown )); then
                detail='参数已修改'
                if [[ $key == ssm ]]; then
                    detail=$(jq -r --slurpfile base "$STAGE/pv-base.json" '
                        $base[0] as $old | [
                            (select(.ss.password != $old.ss.password) | .ss.port),
                            (.users[] | select((.port // 0) > 0) as $u
                             | $old.users[] | select(.name == $u.name and .out == $u.out and .id != $u.id) | $u.port)
                        ] | if length > 0 then "密码已改，端口 " + (map(tostring) | join("、")) else "独立入口已调整" end
                    ' "$DRAFT") || return 1
                fi
                ui_kv "$lab" "$C_YELLOW$detail$C_RESET"
            fi
        done
    fi
    if sni_pool_changed; then
        ui_kv '候选站点' "${C_YELLOW}已修改${C_RESET}" '应用时才写入正式文件'
        n=$(( n + 1 ))
    fi
    if (( n == 0 )); then ui_line '参数未变。继续应用会重新生成配置并重启服务。'; fi
    ui_blank
    case $links_rc in
        0) ui_warn '节点链接有变。应用后请到「分享链接」核对。' ;;
        1) ui_ok '订阅中的节点链接没有变化。' ;;
        *) ui_warn '无法确认节点链接是否变化，应用后请核对节点列表。' ;;
    esac
    ui_rule
    tui_item 1 "$PC_TITLE" '' '写入配置并重启服务'
    tui_item 2 '再看看' '' '回到上一页'
    TUI_FOOT='上下键 移动   回车 确认   Esc 返回'
    TUI_FOOT_PLAIN="1 $PC_TITLE   2 再看看"
}




pc_row() {
    local w
    str_width "$2 -> $3" w
    if (( w <= UI_W - 2 - LABEL_W )); then
        ui_kv "$1" "$C_DIM$2$C_RESET -> $C_YELLOW$3$C_RESET"
    else
        ui_kv "$1" "${C_DIM}原 $2$C_RESET"
        ui_kv '' "${C_YELLOW}改为 $3$C_RESET"
    fi
}

pv_confirm() {
    # Start long reviews at the first change, even when buttons are on a later page.
    local TUI_REVIEW_FIRST=1 links_rc=0
    links_will_change || links_rc=$?
    PC_TITLE=${1:-应用修改}
    tui_menu pc_build 0 '' || return 1
    [[ $TUI_KEY == ENTER && ${TUI_IKEYS[$TUI_CUR]} == 1 ]]
}

preview_loop() {
    local key cur=0
    draft_watch_start
    if [[ $MODE == modify && -f $STATE ]]; then pv_snapshot "$STATE"
    elif [[ $MODE == modify ]]; then pv_snapshot
    else PV_ORIG=() PV_FP=(); fi
    while :; do
        tui_menu pv_build "$cur" ''
        cur=$TUI_CUR
        case $TUI_KEY in
            ESC)
                confirm_discard '放弃未应用的修改？' || continue
                draft_watch_stop
                PREVIEW_RESULT=1
                return 0 ;;
            ENTER)
                key=${TUI_IKEYS[$TUI_CUR]}
                case $key in
                    y|a)
                        preview_ready || continue
                        if [[ $MODE == modify ]]; then pv_confirm || continue
                        elif state_ok; then
                            ui_warn '继续将替换当前方案。使用新凭据或端口时，旧客户端需要更新。'
                            ask_no '确定重新安装' || continue
                        fi
                        draft_watch_stop
                        PREVIEW_RESULT=0
                        return 0 ;;
                    c)
                        confirm_discard '放弃未应用的修改并更换方案？' || continue
                        draft_watch_stop
                        PREVIEW_RESULT=2
                        return 0 ;;
                    *)
                        PREVIEW_NOTES=()
                        "edit_${PV_KEYS[$((key - 1))]}" ;;
                esac ;;
        esac
    done
}

confirm_identity_change() {
    [[ $MODE == modify ]] || return 0
    ask_no "确认$1？应用后请更新对应的客户端节点。"
}

input_page() {
    local literal=0
    if [[ $1 == --literal ]]; then literal=1; shift; fi
    local title=$1 sub=$2 hint=$3 width
    shift 3
    ui_page "$title" "$sub"
    [[ -z $hint ]] || ui_hint "$hint"
    ui_blank
    while (( $# >= 2 )); do
        str_width "$2" width
        if (( width <= UI_W - 2 - LABEL_W )); then
            ui_kv "$1" "$2"
        else
            ui_line "$1"
            ui_line "$2"
        fi
        shift 2
    done
    if (( literal )); then
        ACTION_PID='' ui_footer '回车 保存   Esc或/cancel 取消'
    else
        ui_footer '回车 确认   q/Esc 取消'
    fi
}


ask_port() {
    local __ap_cur=$1 __ap_proto=$2 __ap_p __ap_x __ap_busy __ap_rc
    while :; do
        if ! read_line "新端口（回车保留 $__ap_cur）：" __ap_p '' numeric; then
            printf -v "$3" '%s' "$__ap_cur"
            return 0
        fi
        [[ -n $__ap_p && $__ap_p != "$__ap_cur" ]] || { printf -v "$3" '%s' "$__ap_cur"; return 0; }
        if [[ $__ap_p == r || $__ap_p == R ]]; then
            __ap_p=$(random_free_port) || return 1
            ui_note "随机选到 $__ap_p"
        fi
        if ! valid_port "$__ap_p"; then ui_warn '端口需在 1-65535 之间。'; continue; fi
        __ap_p=$(( 10#$__ap_p ))
        [[ $__ap_p != "$__ap_cur" ]] || { printf -v "$3" '%s' "$__ap_cur"; return 0; }
        __ap_rc=0; port_in_draft "$__ap_p" || __ap_rc=$?
        case $__ap_rc in
            0) ui_warn "本方案已保留端口 $__ap_p。"; continue ;;
            2) die '无法读取草稿中的端口。'; return 1 ;;
        esac
        __ap_busy=''
        for __ap_x in tcp udp; do
            [[ $__ap_proto == both || $__ap_proto == "$__ap_x" ]] || continue
            __ap_rc=0; port_foreign "$__ap_x" "$__ap_p" || __ap_rc=$?
            (( __ap_rc <= 1 )) || { port_query_failed; return 1; }
            if (( __ap_rc == 0 )); then __ap_busy=$__ap_x; break; fi
        done
        if [[ -n $__ap_busy ]]; then
            ui_warn "${__ap_busy^^} $__ap_p 已被 $(port_owner_label "$__ap_busy" "$__ap_p") 占用。"
            continue
        fi
        printf -v "$3" '%s' "$__ap_p"
        return 0
    done
}

edit_port() {
    local s k p i n idx=0 proto=tcp cur hint
    local -a keys=() labels=() opts=()
    s=$(scheme)
    if scheme_has_reality "$s"; then keys+=(.reality.port); labels+=('REALITY'); fi
    if scheme_has_ss "$s"; then keys+=(.ss.port); labels+=('SS2022'); fi
    if scheme_has_enc_inbound "$s"; then keys+=(.enc.port); labels+=('VLESS-ENC'); fi
    n=$(jq '.users | length' "$DRAFT")
    for (( i = 0; i < n; i++ )); do
        [[ $(jq -r ".users[$i].port // 0" "$DRAFT") != 0 ]] || continue
        keys+=(".users[$i].port")
        labels+=("$(landing_label "$(jq -r ".users[$i].out" "$DRAFT")")")
    done
    if (( ${#keys[@]} > 1 )); then
        for i in "${!keys[@]}"; do opts+=("${labels[$i]}|$(st "${keys[$i]}")"); done
        option_page k 0 '端口' '选择要修改的入口。' "${opts[@]}"
        [[ -n $k ]] || return 0
        idx=$(( k - 1 ))
    fi
    [[ ${keys[$idx]} != .ss.port && ${keys[$idx]} != .users* ]] || proto=both
    cur=$(st "${keys[$idx]}")
    if [[ $proto == both ]]; then hint='同时监听 TCP 和 UDP。'
    else hint='监听 TCP。'; fi
    [[ $MODE != modify ]] || hint+=$'\n应用后请更新客户端端口。'
    input_page '端口' "${labels[$idx]}" "$hint" '当前' "$cur" '可以填' '1–65535，输入 r 随机选择'
    ask_port "$cur" "$proto" p || return 1
    [[ $p != "$cur" ]] || return 0
    st_set "${keys[$idx]}" "$p"
    [[ ${keys[$idx]} != .reality.port ]] || PORT_NOTE=''
}

edit_sni() {
    local c d cur auto family old_ms=$SNI_BEST_MS
    cur=$(st .reality.sni)
    option_page c 0 '伪装站点' $'SNI 匹配但未通过认证的连接会转给此站。\n站点须支持 TLS 1.3 和 HTTP/2，且证书有效。' \
        '自动挑选|选择握手最快的可用站点' '手动输入|指定站点域名' '候选列表|编辑自动测速的站点'
    case $c in
        1)
            auto=1
            ui_blank
            if ! sni_auto_select d; then
                SNI_BEST_MS=$old_ms
                ui_warn '候选列表里没有可用的站点，请手动输入。'
                ui_pause
                return 0
            fi ;;
        2)
            auto=0
            family=$(sni_probe_family) || return 1
            input_page '伪装站点' '手动输入' '只填域名，例如 www.example.com。回车使用当前域名，q/Esc 取消。' '当前' "${cur:-未选择}"
            while :; do
                read_line '域名：' d "$cur" || return 0
                [[ -n $d ]] || return 0
                d=${d,,}
                [[ $d != "$cur" ]] || break
                if ! valid_domain "$d"; then ui_warn '只填域名，例如 www.example.com，不带 https:// 和路径。'; continue; fi
                if ! safe_remote_target "$d" 443 1 "$family"; then ui_warn "$PARSE_ERR"; continue; fi
                ui_note "正在检测 $d ..."
                if sni_probe "$d" "$STAGE/sni-manual.log" 1 "$family"; then break; fi
                ui_warn "$d 未通过检测。请检查连通性、证书和 TLS 1.3 / HTTP/2 支持。"
            done ;;
        3) edit_sni_pool; return ;;
        *) return 0 ;;
    esac
    if [[ $d != "$cur" ]] && ! confirm_identity_change "把伪装站点改为 $d"; then
        SNI_BEST_MS=$old_ms
        return 0
    fi
    if [[ $d != "$cur" || $(st '.reality.sni_auto // 0') != "$auto" ]]; then
        st_filter --arg domain "$d" --argjson auto "$auto" '.reality |= (.sni = $domain | .sni_auto = $auto)' || {
            SNI_BEST_MS=$old_ms
            return 1
        }
    fi
    if (( ! auto )); then SNI_BEST_MS=0; fi
}

edit_addr() {
    local c v cur=0 host i v4 v6 next_v6=''
    local -a opts=() vals=()
    if scheme_is_split "$(scheme)"; then
        v4=$(st .net.v4)
        v6=$(st .net.v6)
        input_page '节点地址' '上下行分离' "当前方向：$(split_label)。" \
            'IPv4' "${v4:-未填写}" 'IPv6' "${v6:-未填写}"
        while :; do
            read_line 'IPv4：' v "$v4" numeric || return 0
            [[ -n $v && $v != "$v4" ]] || break
            if valid_ipv4 "$v" && ! unusable_endpoint_ip "$v"; then v4=$v; break; fi
            ui_warn '请填写可访问的 IPv4，不能使用环回或未指定地址。'
        done
        while :; do
            read_line 'IPv6：' v "$v6" numeric || return 0
            [[ -n $v && $v != "$v6" ]] || break
            if valid_ipv6 "$v" && ! unusable_endpoint_ip "$v"; then
                if [[ -z $v6 ]] || [[ $(ip_key "$v") != "$(ip_key "$v6")" ]]; then v6=${v,,}; fi
                break
            fi
            ui_warn '请填写可访问的 IPv6，不能使用环回或未指定地址。'
        done
        if [[ $v4 != "$(st .net.v4)" || $v6 != "$(st .net.v6)" ]]; then
            st_filter --arg v4 "$v4" --arg v6 "$v6" '.net |= (.v4 = $v4 | .v6 = $v6 | .manual = 1)'
        fi
        return 0
    fi
    host=$(st .net.host)
    v4=$NET_V4; v6=$NET_V6
    if [[ -z $v4 ]]; then v4=$(st .net.v4) || return 1; fi
    if [[ -z $v6 ]]; then v6=$(st .net.v6) || return 1; fi
    if valid_ipv4 "$v4" && ! unusable_endpoint_ip "$v4"; then opts+=("IPv4|$v4"); vals+=("$v4"); fi
    if valid_ipv6 "$v6" && ! unusable_endpoint_ip "$v6"; then opts+=("IPv6|$v6"); vals+=("$v6"); fi
    for i in "${!vals[@]}"; do [[ ${vals[$i]} != "$host" ]] || cur=$(( i + 1 )); done
    if (( cur == 0 )) && [[ -n $host ]]; then opts+=("自定义|$host"); vals+=("$host"); cur=${#vals[@]}; fi
    opts+=('输入新地址|域名或 IP')
    if can_attach_v6_link; then
        if [[ $(st '.net.v6_link // 1') == 1 ]]; then
            opts+=('另附 IPv6 链接|已开启，选择关闭'); next_v6=0
        else
            opts+=('另附 IPv6 链接|已关闭，选择开启'); next_v6=1
        fi
    fi
    option_page c "$cur" '节点地址' '分享链接使用的公网 IP 或域名。' "${opts[@]}"
    [[ -n $c && $c != "$cur" ]] || return 0
    if [[ -n $next_v6 && $c == "${#opts[@]}" ]]; then st_set .net.v6_link "$next_v6"; return; fi
    if (( c <= ${#vals[@]} )); then st_sets .net.host "${vals[$((c - 1))]}"; return 0; fi
    input_page '节点地址' '输入新地址' '填写客户端可访问的域名、IPv4 或 IPv6。' '当前' "${host:-未填写}"
    while :; do
        read_line '域名或 IP：' v "$host" || return 0
        [[ -n $v && $v != "$host" ]] || return 0
        if valid_host "$v" && ! unusable_endpoint_ip "$v"; then st_sets .net.host "${v,,}"; return 0; fi
        ui_warn '格式不正确，请填写域名、IPv4 或 IPv6 地址。'
    done
}

edit_name() {
    local v cur
    cur=$(node_name)
    input_page --literal '节点名称' '' $'用于区分客户端中的节点。回车保留当前名称。\n需有可见字符，最多 24 列，汉字占 2 列。' \
        '当前' "$cur" '链接名称' "$(name_example | sed 's/^链接里显示为 //')"
    while :; do
        read_line '新名称：' v '' literal || return 0
        [[ -n $v && $v != "$cur" ]] || return 0
        if valid_node_name "$v"; then set_node_name "$v"; return; fi
        ui_warn '需有可见字符，最多 24 列。不能含空格、引号或 # ? & / \ %。'
    done
}

next_landing_index() {
    jq '[.landings[].tag | ltrimstr("landing") | tonumber] | (max // 0) + 1' "$DRAFT"
}

ld_build() {
    local n i tag
    n=$(jq '.landings | length' "$DRAFT")
    ui_page '出口'
    ui_hint $'默认节点从本机直出。\n每个落地另有分享链接，使用该链接的流量从落地服务器出站。'
    ui_blank
    KEY_W=$(jq '[1, (.landings[].tag | ltrimstr("landing") | length)] | max' "$DRAFT")
    ui_item '' '直出' '本机' '默认出口'
    for (( i = 0; i < n; i++ )); do
        tag=$(jq -r ".landings[$i].tag" "$DRAFT")
        tui_item "${tag#landing}" "$(landing_label "$tag")" \
            "$(jq -r ".landings[$i] | \"\(.kind) \(if (.host | contains(\":\")) then \"[\(.host)]\" else .host end):\(.port)\"" "$DRAFT")" \
            "$(jq -r ".landings[$i].label // \"\"" "$DRAFT")" '回车后确认删除。'
    done
    ui_blank
    tui_item a '添加落地' '' 'ss:// 或 vless:// 链接' '支持 ss:// 和 vless://（TCP、REALITY、VLESS-ENC）。'
    TUI_HELP_H=1
    TUI_FOOT='上下键 移动   回车 选择   Esc 返回'
    if (( n > 0 )); then TUI_FOOT_PLAIN='a 添加落地   落地编号 删除   回车 返回'
    else TUI_FOOT_PLAIN='a 添加落地   回车 返回'; fi
}

confirm_landing_add() {
    local k answer saved_tty=''
    if input_is_tty; then saved_tty=$(stty -g <&"$INPUT_FD" 2>/dev/null || true); fi
    # Parse has already succeeded. Present details before any draft mutation.
    while :; do
        ui_page '确认添加落地' '尚未保存'
        ui_kv '名称' "$PARSED_LABEL"
        ui_kv '类型' "$PARSED_KIND"
        ui_kv '地址' "$(uri_host "$PARSED_HOST")"
        ui_kv '端口' "$PARSED_PORT"
        if [[ $PARSED_KIND == ss ]]; then
            ui_kv '加密方式' "$(jq -r '.settings.method // "unknown"' <<< "$PARSED_OUTBOUND_JSON")"
        else
            local encryption security
            encryption=$(jq -r '.settings.encryption // "none"' <<< "$PARSED_OUTBOUND_JSON")
            security=$(jq -r '.streamSettings.security // "none"' <<< "$PARSED_OUTBOUND_JSON")
            if [[ $security == reality ]]; then
                if [[ $encryption == none ]]; then ui_kv '安全类型' 'REALITY'
                else ui_kv '安全类型' 'REALITY + VLESS-ENC'; fi
                ui_kv 'SNI' "$(jq -r '.streamSettings.realitySettings.serverName // ""' <<< "$PARSED_OUTBOUND_JSON")"
            elif [[ $encryption != none ]]; then
                ui_kv '安全类型' 'VLESS-ENC'
            else
                ui_kv '安全类型' '明文 VLESS'
                ui_note '仅适用于受信专网。使用域名时，须由 Xray 识别为私有域名。'
            fi
        fi
        ui_hint '确认后加入草稿，返回预览页应用后生效。'
        ui_rule
        if (( TUI && UI_W >= 40 && UI_H >= 12 )); then
            ui_footer '回车 确认添加   Esc 取消'
            ui_flush
            [[ -z $saved_tty ]] || tty_echo -echo
            tui_cursor off
            while :; do
                tui_read_key k
                case $k in ENTER|ESC|q|Q|n|N|RESIZE|b|B) break ;; esac
            done
            [[ -z $saved_tty ]] || tty_echo "$saved_tty"
            tui_cursor on
            case $k in
                ENTER) return 0 ;;
                ESC|q|Q|n|N) return 1 ;;
                RESIZE) ui_measure ;;
                b|B) go_home_if_b b || true ;;
            esac
            continue
        fi
        read_line '按回车确认添加，q/Esc 或 n 取消：' answer '' numeric || return 1
        case $answer in
            ''|y|Y) return 0 ;;
            *) return 1 ;;
        esac
    done
}

edit_landings() {
    local n key link cur=0 tag
    while :; do
        tui_menu ld_build "$cur" ''
        cur=$TUI_CUR
        [[ $TUI_KEY == ENTER ]] || return 0
        key=${TUI_IKEYS[$TUI_CUR]}
        if [[ $key == a ]]; then
            n=$(jq '.landings | length' "$DRAFT")
            if (( n >= 10 )); then TUI_MSG='最多添加 10 个落地。'; continue; fi
            input_page '添加落地' '' $'粘贴 ss:// 或 vless:// 链接，输入时隐藏。\n下一页核对服务器地址和端口。'
            while :; do
                read_secret_line '落地链接（回车取消）：' link || break
                [[ -n $link ]] || break
                if parse_landing_link "$link"; then
                    if confirm_landing_add; then
                        add_landing "$(normalize_link "$link")" || return 1
                        TUI_MSG='落地已加入草稿，应用修改后生效。'
                    else
                        TUI_MSG='已取消添加，草稿没有变化。'
                    fi
                    break
                fi
                ui_warn "这个链接用不了：$PARSE_ERR"
            done
        else
            tag="landing$key"
            ask_no "删除$(landing_label "$tag")（$(jq -r --arg t "$tag" '.landings[] | select(.tag == $t) | "\(if (.host | contains(":")) then "[\(.host)]" else .host end):\(.port)"' "$DRAFT")）" || continue
            st_filter --arg t "$tag" '.landings |= map(select(.tag != $t)) | .users |= map(select(.out != $t))'
            cur=0
        fi
    done
}

normalize_landing_outbounds() {
    # Only flatten the single-endpoint shapes emitted by previous versions.
    # Leave other forms intact for Xray to validate, including extra fields.
    st_filter '
      def fields($required; $optional):
        type == "object" and (keys_unsorted as $k |
          ($required - $k | length) == 0 and ($k - ($required + $optional) | length) == 0);
      def single: type == "array" and length == 1;
      .landings |= map(
        .outbound |= (
          if .protocol == "vless" and (.settings | fields(["vnext"]; []))
              and (.settings.vnext | single)
              and (.settings.vnext[0] | fields(["address","port","users"]; []))
              and (.settings.vnext[0].users | single)
              and (.settings.vnext[0].users[0] | fields(["encryption","id"]; ["flow"])) then
            .settings = (.settings.vnext[0] as $v |
              {address:$v.address, port:$v.port, id:$v.users[0].id,
               encryption:$v.users[0].encryption}
              + (if ($v.users[0].flow // "") != "" then {flow:$v.users[0].flow} else {} end))
          elif .protocol == "shadowsocks" and (.settings | fields(["servers"]; []))
              and (.settings.servers | single)
              and (.settings.servers[0] | fields(["address","method","password","port"]; [])) then
            .settings = (.settings.servers[0] |
              {address, port, method, password})
          else . end
          | if .streamSettings.network? != null and .streamSettings.method? == null then
              .streamSettings.method = .streamSettings.network
              | del(.streamSettings.network)
            else . end
        )
      )'
}

add_landing() {
    local link=$1 idx tag port=0
    idx=$(next_landing_index)
    tag="landing$idx"
    if [[ $(scheme) == ss ]]; then port=$(random_free_port) || return 1; fi
    st_filter --arg tag "$tag" --rawfile link <(printf '%s' "$link") --slurpfile ob <(printf '%s' "$PARSED_OUTBOUND_JSON") --arg kind "$PARSED_KIND" \
        --arg host "$PARSED_HOST" --argjson port "$PARSED_PORT" --arg node_label "$PARSED_LABEL" --argjson up "$port" \
        '.landings += [{tag:$tag, link:$link, outbound:$ob[0], kind:$kind, host:$host, port:$port, label:$node_label}]
         | .users += [{name:$tag, id:"", out:$tag} + (if $up > 0 then {port:$up} else {} end)]'
}

edit_path() {
    local p cur hint='客户端请求的路径，须与服务端一致。'
    cur=$(st .xhttp.path)
    [[ $MODE != modify ]] || hint+=$'\n改了以后，客户端需要重新导入节点。'
    input_page 'XHTTP 路径' '' "$hint" '当前' "$cur" '可以填' '以 / 开头，最多 64 个字符'
    while :; do
        read_line '新路径：' p "$cur" || return 0
        [[ -n $p && $p != "$cur" ]] || return 0
        if [[ $p =~ ^/[A-Za-z0-9._/-]{0,63}$ ]]; then st_sets .xhttp.path "$p"; return 0; fi
        ui_warn '路径须以 / 开头，最多 64 个字符，只能用英文字母、数字和 . _ - /。'
    done
}

xh_build() {
    local v
    ui_page 'XHTTP 传输'
    tui_item 1 '路径' "$(st .xhttp.path)" '' '客户端请求的路径，须与服务端一致。'
    tui_item 2 'XMUX' "$(xmux_label)" '客户端连接复用' '参数随分享链接导出，在客户端生效。'
    if [[ $(st .xhttp.enc) == 1 ]]; then v='开'; else v='关'; fi
    tui_item 3 'VLESS 加密' "$v" '叠加到 REALITY' '开启前请确认客户端支持 VLESS 加密。'
    if [[ $(st .xhttp.enc) == 1 ]]; then
        tui_item 4 '加密参数' "$(enc_summary)" "$(enc_detail)" 'VLESS 加密的握手方式、认证方式、外观和填充。'
    fi
    TUI_HELP_H=1
    TUI_FOOT='上下键 移动   回车 修改   Esc 返回'
}

edit_xhttp() {
    local c v cur=0
    while :; do
        tui_menu xh_build "$cur" ''
        cur=$TUI_CUR
        [[ $TUI_KEY == ENTER ]] || return 0
        case ${TUI_IKEYS[$TUI_CUR]} in
            1) edit_path ;;
            2) edit_xmux ;;
            3)
                v=1; [[ $(st .xhttp.enc) != 1 ]] || v=2
                option_page c "$v" 'VLESS 加密' '在 REALITY 之外再加一层 VLESS 加密，客户端需要支持。' \
                    '关|只用 REALITY' '开|REALITY + VLESS 加密'
                [[ -n $c && $c != "$v" ]] || continue
                confirm_identity_change '切换 VLESS 加密' || continue
                st_set .xhttp.enc "$(( c - 1 ))" ;;
            4) edit_encp ;;
        esac
    done
}

edit_xmux() {
    local c r s cur r0 s0
    cur=$(xmux_mode_index)
    option_page c "$cur" 'XMUX' '控制客户端怎样复用连接。参数写进节点链接，只在客户端生效。' \
        '客户端默认|推荐' '按并发数|每条连接最多承载几路请求' '按连接数|最多开几条底层连接'
    [[ -n $c ]] || return 0
    [[ $c != 1 || $cur != 1 ]] || return 0
    case $c in
        1) st_set .xhttp.xmux null ;;
        2|3)
            r0=$(jq -r '.xhttp.xmux | (.maxConcurrency // .maxConnections // "") ' "$DRAFT")
            s0=$(jq -r '.xhttp.xmux.hMaxReusableSecs // "1800-3000"' "$DRAFT")
            [[ $c == "$cur" ]] || r0=''
            if [[ $c == 2 ]]; then input_page 'XMUX' '按并发数' '填写每条连接的并发请求数，可用整数或区间。q/Esc 取消。'
            else input_page 'XMUX' '按连接数' '填写客户端连接数上限，可用整数或区间。q/Esc 取消。'; fi
            while :; do
                if [[ $c == 2 ]]; then read_line '每条连接承载几路（例如 16-32）：' r "$r0" numeric || return 0
                else read_line '底层连接数（例如 2-4）：' r "$r0" numeric || return 0; fi
                [[ -n $r ]] || return 0
                valid_xmux_range "$r" 4 && break
                ui_warn '请输入非负整数或递增区间，例如 16-32。'
            done
            while :; do
                read_line '每条连接最长复用几秒：' s "$s0" numeric || return 0
                [[ -n $s ]] || s=$s0
                valid_xmux_range "$s" 6 && break
                ui_warn '请输入非负整数或递增区间，例如 1800-3000。'
            done
            if [[ $c == 2 ]]; then
                st_set .xhttp.xmux "$(jq -cn --arg r "$r" --arg s "$s" '{maxConcurrency:$r, hMaxReusableSecs:$s}')"
            else
                st_set .xhttp.xmux "$(jq -cn --arg r "$r" --arg s "$s" '{maxConnections:$r, hMaxReusableSecs:$s}')"
            fi ;;
    esac
}

sp2_build() {
    ui_page '上下行分离'
    ui_hint '客户端需要同时能连接服务器的 IPv4 和 IPv6 地址。'
    ui_blank
    tui_item 1 '方向' "$(split_label)"
    tui_item 2 '路径' "$(st .xhttp.path)"
    TUI_FOOT='上下键 移动   回车 修改   Esc 返回'
}

edit_split() {
    local c cur sel=0
    while :; do
        tui_menu sp2_build "$sel" ''
        sel=$TUI_CUR
        [[ $TUI_KEY == ENTER ]] || return 0
        case ${TUI_IKEYS[$TUI_CUR]} in
            1)
                cur=1; [[ $(st .xhttp.split) == v6_up_v4_down ]] || cur=2
                option_page c "$cur" '方向' '' 'IPv6 上行|IPv4 下行' 'IPv4 上行|IPv6 下行'
                [[ -n $c && $c != "$cur" ]] || continue
                confirm_identity_change '更换方向' || continue
                if [[ $c == 1 ]]; then st_sets .xhttp.split v6_up_v4_down; else st_sets .xhttp.split v4_up_v6_down; fi ;;
            2) edit_path ;;
        esac
    done
}

edit_ss_method() {
    local c cur want
    local -a baseline=(--argjson base '[]')
    index_of cur "$(st .ss.method)" 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm
    option_page c "$cur" 'SS2022 加密方式' '算法决定密钥长度。切换算法会更换各 SS 入口的密码。' 'AES-128-GCM|16 字节' 'AES-256-GCM|32 字节'
    [[ -n $c && $c != "$cur" ]] || return 0
    if [[ $c == 1 ]]; then want=2022-blake3-aes-128-gcm; else want=2022-blake3-aes-256-gcm; fi
    if [[ $MODE == modify ]]; then
        ask_no '更换算法和所有 SS 入站密码？应用后请更新 SS 链接。' || return 0
        if [[ -f $STAGE/pv-base.json ]]; then baseline=(--slurpfile base "$STAGE/pv-base.json"); fi
    fi
    # Switching back to the installed method restores that set of passwords.
    st_filter --arg method "$want" "${baseline[@]}" '
        (if $base[0].ss.method == $method then $base[0] else {} end) as $old
        | .ss.method = $method | .ss.password = ($old.ss.password // "")
        | if .scheme == "ss" then .users |= map(. as $u |
            if (.port // 0) > 0 then .id = ([$old.users[]? | select(.name == $u.name and .out == $u.out) | .id][0] // "")
            else . end) else . end'
}

edit_ss_password() {
    local action=$1 method bytes choice rows index port value current field=.ss.password label='主入口'
    local -a fields=(.ss.password) entries=("主入口|端口 $(st .ss.port)")
    if [[ $(scheme) == ss ]]; then
        rows=$(jq -r '.users | to_entries[] | select((.value.port // 0) > 0) | [.key, .value.port] | @tsv' "$DRAFT") || return 1
        while IFS=$'\t' read -r index port; do
            [[ -n $index ]] || continue
            fields+=(".users[$index].id")
            entries+=("独立入口|端口 $port")
        done <<< "$rows"
    fi
    if (( ${#fields[@]} > 1 )); then
        option_page choice 0 'SS2022 密码' '按端口选择入口，只修改所选入口的密码。' "${entries[@]}"
        [[ -n $choice ]] || return 0
        field=${fields[choice - 1]}
        label=${entries[choice - 1]#*|}
    fi
    method=$(st .ss.method) && bytes=$(ss_key_bytes "$method") || return 1
    if [[ $action == manual ]]; then
        input_page '填写 SS2022 密码' "$label" "输入 $bytes 字节密钥的标准 Base64（含末尾等号）。留空保留原值。"
        while :; do
            read_secret_line '密码：' value || return 0
            [[ -n $value ]] || return 0
            valid_ss_password "$value" "$bytes" && break
            ui_warn "格式有误。请填写 $bytes 字节密钥的完整标准 Base64，含末尾等号。"
        done
        current=$(st "$field") || return 1
        [[ $value != "$current" ]] || return 0
    else
        value=$(rand_b64 "$bytes") && valid_ss_password "$value" "$bytes" || { die '生成 SS2022 密码失败。'; return 1; }
    fi
    if [[ $MODE == modify ]]; then
        ask_no "更换 SS2022 $label 的密码？应用后请更新该入口的 SS 链接。" || return 0
    fi
    st_filter --rawfile pw <(printf '%s' "$value") "$field = \$pw" || return 1
    TUI_MSG='密码已写入草稿。'
}

edit_ssm() {
    local c
    while :; do
        option_page c 0 'SS2022' '' "加密方式|$(st .ss.method)" '填写密码|复用固定密钥' '随机密码|生成新密钥'
        case $c in
            1) edit_ss_method || return 1 ;;
            2) edit_ss_password manual || return 1 ;;
            3) edit_ss_password random || return 1 ;;
            *) return 0 ;;
        esac
    done
}

ec_build() {
    ui_page 'VLESS-ENC 参数'
    tui_item 1 '握手方式' "$(rtt_label "$(st .enc.rtt)")" '' '0-RTT 可复用票据。1-RTT 每次完整握手。'
    tui_item 2 '认证方式' "$(auth_label "$(st .enc.auth)")" '' 'X25519 密钥短。ML-KEM-768 抗量子，公钥较长。'
    tui_item 3 '握手外观' "$(st .enc.shape)" '' '握手数据在网络上看起来的样子。'
    tui_item 4 '填充' "$(pad_label "$(st .enc.pad)")" '' '在握手数据里加入随机长度的填充。'
    tui_item 5 '票据有效期' "$(st .enc.ticket | tr -d s) 秒" '只影响服务端' '0-RTT 会话票据在服务端保留多久。'
    tui_item 6 '导入密钥对' '' '复用已有配置' '可输入原始密钥对，或成对粘贴 decryption 和 encryption。'
    TUI_HELP_H=1
    TUI_FOOT='上下键 移动   回车 修改   Esc 返回'
}

edit_encp() {
    local v cur sel=0 auth
    local -a baseline
    while :; do
        tui_menu ec_build "$sel" ''
        sel=$TUI_CUR
        [[ $TUI_KEY == ENTER ]] || return 0
        case ${TUI_IKEYS[$TUI_CUR]} in
            1)
                cur=1; [[ $(st .enc.rtt) != 1rtt ]] || cur=2
                option_page v "$cur" '握手方式' '0-RTT 使用旧票据时，服务端重启后可能暂时连不上。重启客户端核心可重新握手。' '0-RTT|复用会话票据，重连更快' '1-RTT|每次都完整握手'
                [[ -n $v && $v != "$cur" ]] || continue
                confirm_identity_change '修改握手方式' || continue
                if [[ $v == 1 ]]; then st_sets .enc.rtt 0rtt; else st_sets .enc.rtt 1rtt; fi ;;
            2)
                cur=1; [[ $(st .enc.auth) != mlkem768 ]] || cur=2
                option_page v "$cur" '认证方式' '修改现有方案时，改回原认证方式可恢复原密钥。' 'X25519|密钥较短' 'ML-KEM-768|抗量子，公钥较长'
                [[ -n $v && $v != "$cur" ]] || continue
                confirm_identity_change '切换 VLESS-ENC 认证方式' || continue
                if [[ $v == 1 ]]; then auth=x25519; else auth=mlkem768; fi
                baseline=(--argjson base '[]')
                if [[ $MODE == modify && -f $STAGE/pv-base.json ]]; then baseline=(--slurpfile base "$STAGE/pv-base.json"); fi
                st_filter --arg auth "$auth" "${baseline[@]}" '
                    (if $base[0].enc.auth == $auth then $base[0].enc else {} end) as $old
                    | .enc += {auth:$auth, server_key:($old.server_key // ""), client_key:($old.client_key // "")}' || return 1 ;;
            3)
                index_of cur "$(st .enc.shape)" random xorpub native
                option_page v "$cur" '握手外观' '握手数据在网络上看起来的样子。' \
                    'random|全部看起来是随机字节，推荐' 'xorpub|公钥部分做混淆' 'native|不做处理'
                [[ -n $v && $v != "$cur" ]] || continue
                confirm_identity_change '修改握手外观' || continue
                case $v in 1) st_sets .enc.shape random ;; 2) st_sets .enc.shape xorpub ;; 3) st_sets .enc.shape native ;; esac ;;
            4) edit_padding ;;
            5)
                input_page '票据有效期' '' '0 关闭票据。600 表示 300–600 秒，也可填 100-600 指定范围。' \
                    '当前' "$(st .enc.ticket | tr -d s) 秒"
                while :; do
                    read_line '新有效期（回车保留）：' v '' numeric || break
                    [[ -n $v ]] || break
                    if ! valid_enc_ticket "$v"; then ui_warn '请输入 0–86400 秒，或从小到大的范围。'; continue; fi
                    st_sets .enc.ticket "${v}s" || return 1
                    break
                done ;;
            6) edit_keypair enc ;;
        esac
    done
}

edit_padding() {
    local c p q cur mode old_p old_q side label prev value
    mode=$(st .enc.pad) || return 1
    index_of cur "$mode" off gentle aggressive custom
    option_page c "$cur" '填充' '在握手数据里加入随机长度的填充，让流量特征更不明显。' \
        '核心默认|不额外设置' '温和|填充较少' '激进|填充较多，开销稍大' '自定义|分别填写客户端和服务端规则'
    [[ -n $c ]] || return 0
    if [[ $c == "$cur" && $c != 4 ]]; then return 0; fi
    confirm_identity_change '修改填充' || return 0
    case $c in
        1) st_sets .enc.pad off ;;
        2) st_sets .enc.pad gentle ;;
        3) st_sets .enc.pad aggressive ;;
        4)
            if [[ $mode == custom ]]; then
                old_p=$(st .enc.pad_client) && old_q=$(st .enc.pad_server) || return 1
            else
                old_p=$(enc_padding_preset "$mode" client); old_q=$(enc_padding_preset "$mode" server)
            fi
            input_page '填充' '自定义' $'例如 100-96-768.60-0-80。首段概率须为 100，最小长度至少 35 字节。\n回车保留当前规则，输入 - 恢复核心默认值。' \
                '客户端' "${old_p:-核心默认}" '服务端' "${old_q:-核心默认}"
            for side in client server; do
                if [[ $side == client ]]; then label=客户端; prev=$old_p; else label=服务端; prev=$old_q; fi
                while :; do
                    read_line "${label}规则：" value '' numeric || return 0
                    [[ -n $value ]] || { value=$prev; break; }
                    [[ $value != - ]] || { value=''; break; }
                    valid_padding "$value" && break
                    ui_warn '填充规则格式有误。'
                done
                if [[ $side == client ]]; then p=$value; else q=$value; fi
            done
            [[ $p != "$old_p" || $q != "$old_q" ]] || return 0
            st_filter --arg p "$p" --arg q "$q" '.enc.pad = (if $p == "" and $q == "" then "off" else "custom" end)
                | .enc.pad_client = $p | .enc.pad_server = $q' ;;
    esac
}

edit_guard() {
    local c cur=1
    [[ $(st .reality.guard) == nginx ]] || cur=2
    option_page c "$cur" '过滤方式' '仅放行伪装站点的 SNI，其他域名的连接会被拒绝。' \
        'Nginx 前置|可以限制连接数，推荐' 'Xray 内置|无需 Nginx，不设置并发上限'
    [[ -n $c && $c != "$cur" ]] || return 0
    if [[ $c == 1 ]]; then
        if selinux_enforcing; then ui_warn 'SELinux 处于强制模式，用不了 Nginx 前置。'; ui_pause; return 0; fi
        st_sets .reality.guard nginx
    else
        st_sets .reality.guard xray
    fi
}

edit_conn() {
    local a b total
    input_page '连接上限' '' $'Nginx 在验证之前限制并发连接，超出的直接断开。\n对正常客户端同样生效，多人共用时请适当调大。' \
        '每个 IP' "$(st .reality.conn_ip)，可以填 16-65535" '总计' "$(st .reality.conn_total)，不能小于每个 IP 的上限"
    ask_number '每个 IP 最多几条' 16 65535 "$(st .reality.conn_ip)" a || return 0
    total=$(st .reality.conn_total)
    (( total >= a )) || total=$a
    ask_number '总计最多几条' "$a" 65535 "$total" b || return 0
    st_set .reality.conn_ip "$a"
    st_set .reality.conn_total "$b"
}

edit_limit() {
    local c ua ur da dr cur
    index_of cur "$(st .reality.limit)" orig std custom off
    option_page c "$cur" '回落限速' $'限制未认证连接转发到伪装站点时的速度。\n不影响已认证代理流量，也不会关闭伪装站点连接。' \
        "严格|$(limit_text "$(limit_preset orig)")" "宽松|$(limit_text "$(limit_preset std)")" \
        '自定义|分别填写 4 个数值；突发带宽自动设为速率的两倍' \
        '回落不限速|保留向伪装站点的转发'
    [[ -n $c ]] || return 0
    if [[ $c == "$cur" && $c != 3 ]]; then return 0; fi
    case $c in
        1) st_sets .reality.limit orig ;;
        2) st_sets .reality.limit std ;;
        3)
            input_page '回落限速' '自定义' '单位是字节，1KiB = 1024，1MiB = 1048576。'
            ask_number '上行传多少字节后限速' 0 104857600 "$(st .reality.limit_custom.ua)" ua || return 0
            ask_number '上行每秒多少字节' 1 104857600 "$(st .reality.limit_custom.ur)" ur || return 0
            ask_number '下行传多少字节后限速' 0 104857600 "$(st .reality.limit_custom.da)" da || return 0
            ask_number '下行每秒多少字节' 1 104857600 "$(st .reality.limit_custom.dr)" dr || return 0
            st_set .reality.limit_custom "$(jq -cn --argjson a "$ua" --argjson b "$ur" --argjson c "$da" --argjson d "$dr" \
                '{ua:$a, ur:$b, da:$c, dr:$d}')"
            st_sets .reality.limit custom ;;
        4) st_sets .reality.limit off ;;
    esac
}

egress_label() {
    local count
    local -a marks=()
    count=$(st '.egress.block_domains | length')
    (( ! count )) || marks+=("屏蔽域名 $count 个")
    [[ $(st '.egress.cn // 0') != 1 ]] || marks+=('阻止大陆域名/IP')
    [[ $(st '.egress.bt // 0') != 1 ]] || marks+=('阻止 BT（可识别部分）')
    if (( ${#marks[@]} )); then join_by '，' "${marks[@]}"; else printf '均关闭'; fi
    if [[ $(scheme) == ss ]] && [[ $(ss_core) == xray ]]; then
        printf '（SS2022 使用 Xray）'
    fi
}

eg_build() {
    local cn bt count
    cn=$(st '.egress.cn // 0')
    bt=$(st '.egress.bt // 0')
    count=$(st '.egress.block_domains | length')
    ui_page '出口限制'
    ui_hint '仅限本机直出。BT 仅拦截可识别的流量。'
    ui_blank
    if [[ $cn == 1 ]]; then
        tui_item 1 '大陆域名/IP' '已阻止' '回车关闭'
    else
        tui_item 1 '大陆域名/IP' '未阻止' '回车开启'
    fi
    if [[ $bt == 1 ]]; then
        tui_item 2 'BT 流量' '已阻止' '回车关闭'
    else
        tui_item 2 'BT 流量' '未阻止' '回车开启'
    fi
    tui_item 3 '屏蔽固定域名' "$count 个" '回车管理' '域名与其子域名一起屏蔽。'
    ui_blank
    if needs_ss_rust; then
        ui_kv '基础限制' '阻止私网等特殊地址（SS-Rust）'
        ui_note '开启大陆或 BT 限制后，SS2022 将使用 Xray。'
    else
        ui_kv '基础限制' '阻止私网等特殊地址和常用 SMTP 端口（Xray）'
    fi
    TUI_HELP_H=0
    TUI_FOOT='上下键 移动   回车 选择   Esc 完成'
    TUI_FOOT_PLAIN='1/2 切换   3 管理域名   0 完成'
}

edit_egress() {
    local sel=0 key
    while :; do
        tui_menu eg_build "$sel" ''
        sel=$TUI_CUR
        [[ $TUI_KEY == ENTER ]] || return 0
        key=${TUI_IKEYS[$TUI_CUR]}
        case $key in
            1)
                if [[ $(st '.egress.cn // 0') == 1 ]]; then st_set .egress.cn 0
                else st_set .egress.cn 1; fi ;;
            2)
                if [[ $(st '.egress.bt // 0') == 1 ]]; then st_set .egress.bt 0
                else st_set .egress.bt 1; fi ;;
            3) edit_block_domains ;;
        esac
    done
}

block_domains_build() {
    local i start=$(( page * page_size )) count=${#domains_list[@]} visible sub
    visible=$(( count - start ))
    (( visible <= page_size )) || visible=$page_size
    sub="$count 个"
    (( pages <= 1 )) || sub+=" · 第 $(( page + 1 ))/$pages 页"
    ui_page '屏蔽固定域名' "$sub"
    ui_hint $'只屏蔽本机直出，名单同时匹配子域名。\n'"$domain_hint"
    ui_blank
    KEY_W=${#visible}
    tui_item a '添加域名' '' '可批量添加'
    for (( i = 0; i < visible; i++ )); do
        tui_item "$(( i + 1 ))" "${domains_list[start + i]}"
    done
    if (( page > 0 )); then tui_item p '上一页'; fi
    if (( page + 1 < pages )); then tui_item n '下一页'; fi
    if (( count )); then tui_item x '清空列表' '' '关闭域名屏蔽'; fi
    TUI_HELP_H=0
    TUI_FOOT='上下键 移动   回车 选择   Esc 返回'
    if (( count )); then TUI_FOOT_PLAIN='a 添加   编号 删除   x 清空   0 返回'
    else TUI_FOOT_PLAIN='a 添加   0 返回'; fi
}

edit_block_domains() {
    local sel=0 key batch domains updated domain names page=0 pages page_size=10 reload=1
    local -a domains_list=()
    local domain_hint='Xray 也会尝试从 HTTP、TLS 或 QUIC 识别域名。'
    if needs_ss_rust; then domain_hint='SS-Rust 只匹配客户端请求携带的域名。'; fi
    while :; do
        if (( reload )); then
            domains=$(blocked_domains_json) || { die '配置中的屏蔽域名列表无效。'; return 1; }
            names=$(jq -r '.[]' <<< "$domains") || { die '无法读取屏蔽域名。'; return 1; }
            domains_list=()
            [[ -z $names ]] || mapfile -t domains_list <<< "$names"
            pages=$(( (${#domains_list[@]} + page_size - 1) / page_size ))
            if (( page >= pages )); then page=$(( pages > 0 ? pages - 1 : 0 )); fi
            reload=0
        fi
        tui_menu block_domains_build "$sel" ''
        sel=$TUI_CUR
        [[ $TUI_KEY == ENTER ]] || return 0
        key=${TUI_IKEYS[$TUI_CUR]}
        case $key in
            p) page=$(( page - 1 )); sel=0; continue ;;
            n) page=$(( page + 1 )); sel=0; continue ;;
            a)
                input_page '添加屏蔽域名' '' '用中文或英文逗号分隔，例如 example.com,example.org。'
                read_line '域名（回车取消）：' batch || continue
                [[ -n $batch ]] || continue
                if ! updated=$(blocked_domains_json "$DRAFT" '' "$batch" 2>/dev/null); then
                    TUI_MSG='整批未添加。请检查域名和多余的逗号。'
                    continue
                fi
                if [[ $updated == "$domains" ]]; then TUI_MSG='域名已在列表中。'; continue; fi
                st_filter --rawfile list <(printf '%s' "$updated") '.egress.block_domains = ($list | fromjson)' || return 1 ;;
            x)
                ask_no '清空全部屏蔽域名？' || continue
                st_set .egress.block_domains '[]' || return 1 ;;
            *)
                domain=${domains_list[page * page_size + key - 1]}
                ask_no "从屏蔽名单删除 ${domain}？" || continue
                st_filter --rawfile list <(printf '%s' "$domains") --arg domain "$domain" \
                    '.egress.block_domains = (($list | fromjson) - [$domain])' || return 1 ;;
        esac
        reload=1
        sel=0
    done
}

SYS_KEYS=()

sy_build() {
    local v fw s count reality=0 enc=0
    s=$(scheme)
    if scheme_has_reality "$s"; then reality=1; fi
    if needs_enc_keys; then enc=1; fi
    ui_page '高级设置'
    SYS_KEYS=(outbound bbr)
    tui_item 1 '出站 IP' "$(outbound_label "$(st .outbound)")" '地址族与域名屏蔽' '选择 IPv4/IPv6 策略，或编辑本机直出的屏蔽域名。'
    if [[ $(st .bbr) == 1 ]]; then v='开'; else v='关'; fi
    tui_item 2 'BBR' "$v" '系统 TCP 拥塞控制' '内核支持时启用 BBR 和 fq。'
    if [[ $s != ss ]]; then
        SYS_KEYS+=(uuid)
        count=$(jq '[.users[] | select(.out == "direct")] | length' "$DRAFT")
        tui_item "${#SYS_KEYS[@]}" 'UUID' "$count 个直出身份" '' '管理直出 UUID，或为已有落地入口指定 UUID。'
    fi
    if (( reality )); then
        SYS_KEYS+=(reality_pair)
        v='X25519'
        if (( enc )); then v="REALITY / $v"; fi
        tui_item "${#SYS_KEYS[@]}" '密钥对' "$v" '' '导入 REALITY 的私钥和公钥。'
    fi
    if (( enc )); then
        SYS_KEYS+=(enc_pair)
        v=$(auth_label "$(st .enc.auth)")
        if (( reality )); then v="VLESS-ENC / $v"; fi
        tui_item "${#SYS_KEYS[@]}" '密钥对' "$v" '' '导入已有密钥，或恢复 VLESS-ENC 的成对配置值。'
    fi
    if (( reality )); then
        SYS_KEYS+=(short_id)
        v=$(reality_short_ids | jq -r 'join("、")')
        tui_item "${#SYS_KEYS[@]}" 'shortId' "${v:-自动生成}" '' '支持多个；订阅默认使用第一个。'
    fi
    fw=$(fw_kind)
    if [[ -n $fw ]]; then
        SYS_KEYS+=(firewall)
        if [[ $(st '.firewall // "auto"') == auto ]]; then v='自动放行'; else v='手动放行'; fi
        tui_item "${#SYS_KEYS[@]}" '防火墙' "$v" "本机 $fw 已启用" '自动放行用到的端口，改端口时同步，卸载时撤销。'
    fi
    SYS_KEYS+=(core)
    local -a cl=()
    if needs_xray; then cl+=("Xray $(core_label xray)"); fi
    if needs_ss_rust; then cl+=("SS-Rust $(core_label ss)"); fi
    tui_item "${#SYS_KEYS[@]}" '核心版本' "${cl[0]:-}" '' '默认使用 GitHub 最新正式版。'
    for v in "${cl[@]:1}"; do ui_cont "$v"; done
    TUI_HELP_H=1
    TUI_FOOT='上下键 移动   回车 修改   Esc 返回'
}

edit_system() {
    local sel=0
    while :; do
        tui_menu sy_build "$sel" ''
        sel=$TUI_CUR
        [[ $TUI_KEY == ENTER ]] || return 0
        case ${SYS_KEYS[$TUI_CUR]} in
            reality_pair) edit_keypair reality ;;
            enc_pair) edit_keypair enc ;;
            *) "edit_${SYS_KEYS[$TUI_CUR]}" ;;
        esac
    done
}

edit_outbound() {
    local c cur m host
    local -a modes=(v4first v6first v4only v6only) opts=()
    opts=('IPv4 优先|推荐' 'IPv6 优先|' '只用 IPv4|' '只用 IPv6|')
    host=$(st .net.host)
    [[ -n $NET_V4 || -n $(st .net.v4) ]] || valid_ipv4 "$host" || opts[2]='只用 IPv4|未检测到 IPv4，不可选'
    [[ -n $NET_V6 || -n $(st .net.v6) ]] || valid_ipv6 "$host" || opts[3]='只用 IPv6|未检测到 IPv6，不可选'
    opts+=('屏蔽固定域名|管理本机直出的屏蔽域名')
    index_of cur "$(st .outbound)" "${modes[@]}"
    option_page c "$cur" '出站 IP' '选择出站 IP 策略，或管理屏蔽域名。' "${opts[@]}"
    if [[ $c == 5 ]]; then edit_block_domains; return; fi
    [[ -n $c && $c != "$cur" ]] || return 0
    if [[ ${opts[$((c - 1))]} == *不可选* ]]; then ui_warn '未检测到对应地址，请先在「节点地址」中填写。'; ui_pause; return 0; fi
    m=${modes[$((c - 1))]}
    local old_core=''
    [[ $(scheme) != ss ]] || old_core=$(ss_core)
    st_sets .outbound "$m"
    if [[ $old_core == ss-rust && $(ss_core) == xray ]]; then
        ui_note 'SS-Rust 不支持这种出站方式，SS2022 将改用 Xray 核心。'
        ui_pause
    fi
}

edit_bbr() {
    local c cur=1
    [[ $(st .bbr) == 1 ]] || cur=2
    option_page c "$cur" 'BBR' '控制本机 TCP 拥塞算法和默认队列。' \
        '开|内核支持时启用 BBR + fq' '关|撤销脚本的 BBR 设置'
    [[ -n $c && $c != "$cur" ]] || return 0
    if [[ $c == 1 ]]; then st_set .bbr 1; else st_set .bbr 0; fi
}

edit_short_id() {
    local ids current='' value choice selected index=0 i title hint existing=''
    local -a values=() opts=('新增 shortID|追加到末尾，订阅仍使用第一个') entries=()
    ids=$(reality_short_ids) || return 1
    mapfile -t values < <(jq -r '.[]' <<< "$ids")
    for i in "${!values[@]}"; do
        existing+="${existing:+$'\n'}$(( i + 1 )). ${values[$i]}"
        if (( i == 0 )); then
            existing+='（订阅默认）'
            entries+=("订阅默认|${values[$i]}")
        else
            entries+=("可用|${values[$i]}")
        fi
    done
    if (( ${#values[@]} )); then opts+=('替换已有 shortID|选择一个条目替换，其他条目继续保留'); fi
    if (( ${#values[@]} > 1 )); then opts+=('删除一个 shortID|保留其余条目'); fi
    option_page choice 0 'REALITY shortID' "已有 shortID：${existing:+$'\n'}${existing:-安装时自动生成}" "${opts[@]}"
    case $choice in
        1) title='新增 shortID' ;;
        2|3)
            if [[ $choice == 3 ]]; then
                (( ${#values[@]} > 1 )) || return 0
                title='删除 shortID'; hint='删除第一个时，订阅改用下一个 shortID。'
            else
                title='替换 shortID'; hint='选择要替换的条目。第一个用于默认订阅。'
            fi
            option_page selected 0 "$title" "$hint" "${entries[@]}"
            [[ -n $selected ]] || return 0
            index=$(( selected - 1 ))
            current=${values[$index]}
            if [[ $choice == 3 ]]; then
                ask_no "删除 $current？应用后，使用它的客户端需要更新 shortID" || return 0
                ids=$(jq -c --argjson i "$index" 'del(.[$i])' <<< "$ids") || return 1
                set_reality_short_ids "$ids" || return 1
                TUI_MSG='所选 shortID 已从草稿移除。'
                return 0
            fi ;;
        *) return 0 ;;
    esac
    hint='填 2–16 位十六进制字符，位数须为偶数。留空保留当前设置。'
    if [[ $choice == 2 ]]; then hint+=$'\n应用后，使用被替换值的客户端需要更新 shortID。'; fi
    input_page "$title" 'REALITY' "$hint" '当前条目' "${current:-新增到末尾}"
    while :; do
        read_line '新 shortId：' value '' numeric || return 0
        [[ -n $value ]] || return 0
        if ! valid_short_id "$value"; then
            ui_warn '需为 2–16 位，长度为偶数，只能使用 0–9 和 A–F（不区分大小写）。'
            continue
        fi
        value=${value,,}
        [[ $value != "${current,,}" ]] || return 0
        if jq -e --arg value "$value" "$JQ_SHORT_ID_KEY"'any(.[]; short_id_key == ($value | short_id_key))' <<< "$ids" >/dev/null; then
            ui_warn '已有等效的 shortID。末尾补 00 或更改大小写都代表同一个值。'
            continue
        fi
        if [[ $choice == 1 ]]; then
            ids=$(jq -c --arg value "$value" '. + [$value]' <<< "$ids") || return 1
        else
            ids=$(jq -c --arg value "$value" --argjson i "$index" '.[$i] = $value' <<< "$ids") || return 1
        fi
        set_reality_short_ids "$ids" || return 1
        TUI_MSG='shortID 列表已写入草稿。'
        return 0
    done
}


edit_uuid() {
    local choice value title primary row name mode target=direct tag rows
    local -a actions=(add primary) targets=() landing_options=() extra=() opts=('新增 UUID|为本机直出添加身份，保留原身份' '修改主 UUID|指定主节点使用的 UUID')
    mapfile -t extra < <(jq -r '.users[] | select(.out == "direct" and (.name | test("^uuid[0-9]+$")))
        | "\(.name)|\(.id)"' "$DRAFT")
    if (( ${#extra[@]} )); then actions+=(manage); opts+=('管理附加 UUID|查看或删除已添加的身份'); fi
    rows=$(jq -r '.users[] | select(.out != "direct" and (.port // 0) == 0) | [.name, .out] | @tsv' "$DRAFT") || return 1
    while IFS=$'\t' read -r name tag; do
        [[ -n $name && -n $tag ]] || continue
        targets+=("$name")
        landing_options+=("$(landing_label "$tag")|入口身份 $name")
    done <<< "$rows"
    if (( ${#targets[@]} )); then actions+=(landing); opts+=('修改落地入口 UUID|复用此入口的客户端身份'); fi
    local hint=''
    [[ $(scheme) != triple ]] || hint='REALITY 和 VLESS-ENC 共用直出 UUID。修改主 UUID 后，请更新这两个节点。'
    option_page choice 0 'UUID' "$hint" "${opts[@]}"
    [[ -n $choice ]] || return 0
    mode=${actions[choice-1]}
    case $mode in
        add) title='新增 UUID' ;;
        primary) title='修改主 UUID' ;;
        landing)
            option_page choice 0 '落地入口 UUID' '选择客户端连接本机时使用的入口。远端落地凭据单独保存在落地链接中。' "${landing_options[@]}"
            [[ -n $choice ]] || return 0
            target=${targets[choice-1]}
            title="修改 $target 入口 UUID" ;;
        manage)
            option_page choice 0 '附加 UUID' '选择身份可查看完整 UUID 或删除。' "${extra[@]}"
            [[ -n $choice ]] || return 0
            row=${extra[$(( choice - 1 ))]}
            name=${row%%|*} value=${row#*|}
            ui_page '附加 UUID' "$name"
            ui_line "$value"
            ask_no '删除此身份？应用修改后，对应节点将失效' || return 0
            st_filter --arg name "$name" --rawfile id <(printf '%s' "$value") 'del(.users[] | select(
                .out == "direct" and (.name | test("^uuid[0-9]+$")) and .name == $name and .id == $id))' || return 1
            TUI_MSG="$name 已从草稿移除。"
            return 0 ;;
        *) return 0 ;;
    esac
    if [[ $mode != add ]]; then
        primary=$(jq -r --arg t "$target" '.users[] | select(.name == $t) | .id // ""' "$DRAFT") || return 1
        input_page "$title" '' '填写 8-4-4-4-12 格式的十六进制 UUID。' '当前 UUID' "${primary:-应用时自动生成}"
    else
        input_page "$title" '' '填写 8-4-4-4-12 格式的十六进制 UUID。'
    fi
    while :; do
        read_line 'UUID：' value || return 0
        [[ -n $value ]] || return 0
        case $mode in
            add) if add_custom_uuid "$value"; then TUI_MSG='新 UUID 已加入草稿。'; return 0; fi ;;
            primary) if set_primary_uuid "$value"; then TUI_MSG='主 UUID 已写入草稿。'; return 0; fi ;;
            landing) if write_custom_uuid landing "$value" "$target"; then TUI_MSG="$target 的 UUID 已写入草稿。"; return 0; fi ;;
        esac
        ui_warn "$CREDENTIAL_ERR"
    done
}

edit_keypair() {
    local kind=$1 label hint secret public private_prompt='私钥：' public_prompt='公钥：'
    if [[ $kind == reality ]]; then
        label='REALITY · X25519'
        hint='分别粘贴私钥和公钥。私钥输入时隐藏。'
    else
        label='VLESS-ENC'
        hint=$'原始密钥对先填私钥、再填公钥，自动识别算法。\n也可依次填写 decryption 和 encryption 的值（不含引号），同时恢复握手参数和填充。每端限一个密钥。'
        private_prompt='私钥 / decryption：'; public_prompt='公钥 / encryption：'
    fi
    if [[ $MODE == modify ]]; then hint+=$'\n更换后，请更新使用这组密钥的节点。'; fi
    input_page '导入密钥对' "$label" "$hint"
    while :; do
        read_secret_line "$private_prompt" secret || return 0
        [[ -n $secret ]] || return 0
        read_line "$public_prompt" public || return 0
        [[ -n $public ]] || return 0
        if set_custom_keypair "$kind" "$secret" "$public"; then
            TUI_MSG=${CREDENTIAL_NOTE:-密钥对校验通过，已写入草稿。}
            return 0
        fi
        secret=''
        ui_warn "$CREDENTIAL_ERR"
    done
}

edit_firewall() {
    local c cur=1 fw
    fw=$(fw_kind)
    [[ $(st '.firewall // "auto"') == auto ]] || cur=2
    option_page c "$cur" '防火墙' "本机使用 $fw。自动规则随方案端口更新。改为手动会尝试撤销本工具添加的规则。" \
        '自动放行|跟随方案端口' '手动放行|自行维护规则'
    [[ -n $c && $c != "$cur" ]] || return 0
    if [[ $c == 1 ]]; then st_sets .firewall auto; else st_sets .firewall off; fi
}

co_build() {
    ui_page '核心版本'
    if needs_xray; then tui_item 1 'Xray' "$(core_label xray)" '' '默认获取 GitHub 最新正式版；也可指定版本号。'; fi
    if needs_ss_rust; then tui_item 2 'SS-Rust' "$(core_label ss)" '' '跟随 shadowsocks-rust 的正式版，或固定一个版本。'; fi
    TUI_HELP_H=1
    TUI_FOOT='上下键 移动   回车 修改   Esc 返回'
}

ask_core_version() {
    local __av_cur=$1 __av_v __av_mode=numeric __av_check=valid_xray_version
    if [[ $3 == ss ]]; then __av_mode=text; __av_check=valid_ss_version; fi
    while :; do
        read_line '版本号：' __av_v "$__av_cur" "$__av_mode" || return 1
        [[ -n $__av_v ]] || return 1
        if "$__av_check" "${__av_v#v}"; then printf -v "$2" '%s' "$(normalize_tag "$__av_v")"; return 0; fi
        ui_warn '版本号格式有误，请检查主版本、次版本和修订号。'
    done
}

edit_core() {
    local c cur v sel=0 iv
    while :; do
        tui_menu co_build "$sel" ''
        sel=$TUI_CUR
        [[ $TUI_KEY == ENTER ]] || return 0
        if [[ ${TUI_IKEYS[$TUI_CUR]} == 1 ]]; then
            case $(st .core.xray) in latest|compat) cur=1 ;; *) cur=2 ;; esac
            option_page c "$cur" 'Xray 版本' '安装或更新时获取所选版本。' \
                '最新正式版|跟随 GitHub 正式发布' '指定版本|固定版本号'
            [[ -n $c ]] || continue
            case $c in
                1) st_sets .core.xray latest ;;
                2)
                    iv=$(installed_version xray)
                    [[ $(st .core.xray) == latest || $(st .core.xray) == compat ]] || iv=$(st .core.xray)
                    input_page 'Xray 版本' '指定版本' "最低版本为 v$XRAY_MIN_VERSION。"
                    ask_core_version "${iv:-v$XRAY_MIN_VERSION}" v xray || continue
                    if ! ver_ge "${v#v}" "$XRAY_MIN_VERSION"; then ui_warn "最低需要 v$XRAY_MIN_VERSION。"; ui_pause; continue; fi
                    st_sets .core.xray "$v" ;;
            esac
        else
            cur=1; [[ $(st .core.ss) == latest ]] || cur=2
            option_page c "$cur" 'SS-Rust 版本' '' '最新版|跟随正式版' '指定版本|填写一个版本号'
            [[ -n $c ]] || continue
            if [[ $c == 1 ]]; then st_sets .core.ss latest; continue; fi
            input_page 'SS-Rust 版本' '指定版本' '示例：v1.24.0。'
            iv=$(installed_version ss)
            [[ $(st .core.ss) == latest ]] || iv=$(st .core.ss)
            ask_core_version "${iv:-v1.24.0}" v ss || continue
            st_sets .core.ss "$v"
        fi
    done
}



# On Linux, Xray's Go wildcard listener and SS-Rust's ipv6_only:false
# request a dual-stack socket even when net.ipv6.bindv6only defaults to 1.
listen_any() { if has_ipv6_stack; then printf '::'; else printf '0.0.0.0'; fi; }

base_final_rules_json() {
    # Xray 2026-10 freedom.finalRules executes at the last outbound dial stage.
    # Do NOT put these rules in global routing: remote landings must retain autonomy.
    jq -cn --arg delay_key "$1" '[
      {action:"block", ip:["geoip:private"], ($delay_key):"0"},
      {action:"block", network:"tcp", port:"25,465,587,2525", ($delay_key):"0"}
    ]'
}

egress_final_rules_json() {
    jq -cn --argjson base "$1" --arg delay_key "$2" --argjson cn "$3" --arg mode "$4" '
      $base
      + (if $cn == 1 then [{action:"block", ip:["geoip:cn"], ($delay_key):"0"}] else [] end)
      + (if $mode == "v4only" then [{action:"block", ip:["::/0"], ($delay_key):"0"}]
         elif $mode == "v6only" then [{action:"block", ip:["0.0.0.0/0"], ($delay_key):"0"}] else [] end)'
}

reality_limits_json() {
    if [[ $(st .reality.limit) == off ]]; then
        printf '{}'
        return 0
    fi
    local -a lv=()
    read -r -a lv <<< "$(limit_values)"
    (( ${#lv[@]} == 6 )) || { die '回落限速参数个数不正确。'; return 1; }
    jq -cn --argjson ua "${lv[0]}" --argjson ur "${lv[1]}" --argjson ub "${lv[2]}" \
        --argjson da "${lv[3]}" --argjson dr "${lv[4]}" --argjson db "${lv[5]}" '{
      limitFallbackUpload:{afterBytes:$ua, bytesPerSec:$ur, burstBytesPerSec:$ub},
      limitFallbackDownload:{afterBytes:$da, bytesPerSec:$dr, burstBytesPerSec:$db}
    }'
}

shared_users_json() {
    local flow=$1 scope=${2:-all}
    jq -c --arg flow "$flow" --arg scope "$scope" '[.users[] | select((.port // 0) == 0 and ($scope == "all" or .out == "direct"))
        | {id, email: .name} + (if $flow == "" then {} else {flow: $flow} end)]' "$DRAFT"
}

render_xray_config() {
    local out=$1 s listen mode strategy cn bt sniff fallback_json version base_rules domains delay_key=blockDelay
    version=$(xray_version_of "$USE_XRAY") || { die '生成配置前无法读取所选 Xray 核心版本。'; return 1; }
    if ver_ge "$version" 26.11.9; then delay_key=delay; fi
    base_rules=$(base_final_rules_json "$delay_key") || return 1
    s=$(scheme)
    listen=$(listen_any)
    mode=$(st .outbound)
    strategy=$(outbound_xray_strategy "$mode")
    cn=$(st '.egress.cn // 0')
    bt=$(st '.egress.bt // 0')
    domains=$(blocked_domains_json) || { die '屏蔽域名列表无效。'; return 1; }
    local inb=$STAGE/xr-in.ndjson rules=$STAGE/xr-rules.ndjson
    : > "$inb"
    : > "$rules"
    : > "$STAGE/xr-gate.ndjson"
    local -a direct_tags=() vless_tags=()
    sniff='null'
    if [[ $cn == 1 || $bt == 1 || $domains != '[]' ]]; then
        # routeOnly never changes the client's original requested destination.
        # BT sniffing is basic signature detection only, not a complete BT firewall.
        sniff='{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}'
    fi

    if scheme_has_reality "$s"; then
        local net flow dec stream users
        net=$(scheme_transport "$s")
        flow=xtls-rprx-vision dec=none
        if [[ $net == xhttp ]]; then
            if [[ $s == reality-xhttp && $(st .xhttp.enc) == 1 ]]; then dec=$(enc_string server); else flow=''; fi
        fi
        [[ $s != triple ]] || net=raw
        if [[ $s == triple ]]; then users=$(shared_users_json "$flow" direct); else users=$(shared_users_json "$flow"); fi
        fallback_json=$(reality_limits_json)
        stream=$(jq -c --arg net "$net" --arg sni "$(st .reality.sni)" \
            --argjson sids "$(reality_short_ids)" --arg path "$(st .xhttp.path)" --arg guard "$(st .reality.guard)" \
            --arg gate "127.0.0.1:$(st .reality.gate)" --argjson limits "$fallback_json" '
            {method: $net, security: "reality",
             realitySettings: ({show: false, target: (if $guard == "nginx" then ($sni + ":443") else $gate end),
                serverNames: [$sni], privateKey: .reality.private_key, shortIds: $sids, minClientVer: "0.0.0"} + $limits)}
            + (if $net == "xhttp" then {xhttpSettings: {path: $path, mode: "auto"}} else {} end)
            + (if $guard == "nginx" then {sockopt: {acceptProxyProtocol: true}} else {} end)' "$DRAFT")
        if [[ $(st .reality.guard) == nginx ]]; then
            jq -c --argjson p "$(st .reality.internal)" --slurpfile u <(printf '%s' "$users") --rawfile dec <(printf '%s' "$dec") \
                --argjson sn "$sniff" '
                {tag:"in-reality", listen:"127.0.0.1", port:$p, protocol:"vless",
                 settings:{clients:$u[0], decryption:$dec}, streamSettings:.}
                + (if $sn == null then {} else {sniffing:$sn} end)' <<< "$stream" >> "$inb"
        else
            jq -c --arg l "$listen" --argjson p "$(st .reality.port)" --slurpfile u <(printf '%s' "$users") --rawfile dec <(printf '%s' "$dec") \
                --argjson sn "$sniff" '
                {tag:"in-reality", listen:$l, port:$p, protocol:"vless",
                 settings:{clients:$u[0], decryption:$dec}, streamSettings:.}
                + (if $sn == null then {} else {sniffing:$sn} end)' <<< "$stream" >> "$inb"
            jq -cn --argjson p "$(st .reality.gate)" \
                '{tag:"reality-gate", listen:"127.0.0.1", port:$p, protocol:"tunnel",
                  settings:{address:"127.0.0.1", port:443, network:"tcp"},
                  sniffing:{enabled:true, destOverride:["tls"], routeOnly:false}}' >> "$inb"
            jq -cn --arg sni "$(st .reality.sni)" \
                '{type:"field", inboundTag:["reality-gate"], domain:["full:" + $sni], network:"tcp", outboundTag:"reality-fallback"}' \
                >> "$STAGE/xr-gate.ndjson"
            jq -cn '{type:"field", inboundTag:["reality-gate"], network:"tcp", outboundTag:"blocked"}' >> "$STAGE/xr-gate.ndjson"
        fi
        direct_tags+=(in-reality)
        vless_tags+=(in-reality)
    fi

    if scheme_has_enc_inbound "$s"; then
        local users stream dec
        dec=$(enc_string server)
        case $s in
            enc-split) users=$(shared_users_json '' direct) ;;
            enc) users=$(shared_users_json xtls-rprx-vision) ;;
            *) users=$(shared_users_json xtls-rprx-vision direct) ;;
        esac
        if [[ $s == enc-split ]]; then
            stream=$(jq -cn --arg path "$(st .xhttp.path)" '{method:"xhttp", security:"none", xhttpSettings:{path:$path, mode:"auto"}}')
        else
            stream='{"method":"raw","security":"none"}'
        fi
        jq -cn --arg l "$listen" --argjson p "$(st .enc.port)" --slurpfile u <(printf '%s' "$users") --rawfile dec <(printf '%s' "$dec") --argjson st "$stream" \
            --argjson sn "$sniff" '
            {tag:"in-enc", listen:$l, port:$p, protocol:"vless",
             settings:{clients:$u[0], decryption:$dec}, streamSettings:$st}
            + (if $sn == null then {} else {sniffing:$sn} end)' >> "$inb"
        direct_tags+=(in-enc)
        vless_tags+=(in-enc)
    fi

    if scheme_has_ss "$s"; then
        jq -c --arg l "$listen" --argjson sn "$sniff" '
            {tag:"in-ss", listen:$l, port:.ss.port, protocol:"shadowsocks",
             settings:{method:.ss.method, password:.ss.password, network:"tcp,udp"}}
            + (if $sn == null then {} else {sniffing:$sn} end)' "$DRAFT" >> "$inb"
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

    # Egress restrictions apply to all locally terminating "direct" users.
    # Other VLESS users are routed to their own remote landing and must not be blocked on A.
    # "in-ss" is always direct. "in-ss-landingN" is always a landing.
    local vtags='[]'
    if (( ${#vless_tags[@]} )); then
        vtags=$(printf '%s\n' "${vless_tags[@]}" | jq -R . | jq -cs .)
    fi
    if [[ $cn == 1 || $bt == 1 ]]; then
        local has_ss=false
        if scheme_has_ss "$s"; then has_ss=true; fi
        # Read user names from the draft. Large lists must not become one argv string.
        jq -c --argjson ts "$vtags" --argjson ss "$has_ss" --argjson cn "$cn" --argjson bt "$bt" '
            def block_rules:
                (if $cn == 1 then . + {domain:["geosite:cn"], outboundTag:"blocked"} else empty end),
                (if $bt == 1 then . + {protocol:["bittorrent"], outboundTag:"blocked"} else empty end);
            ((if ($ts | length) > 0 then
                {type:"field", inboundTag:$ts,
                 user:[.users[] | select(.out == "direct" and (.port // 0) == 0) | .name]}
              else empty end),
             (if $ss then {type:"field", inboundTag:["in-ss"]} else empty end))
            | block_rules' "$DRAFT" >> "$rules" || return 1
    fi

    local gate='[]' tags_json='[]' fallback_out='[]'
    [[ ! -s $STAGE/xr-gate.ndjson ]] || gate=$(jq -cs . "$STAGE/xr-gate.ndjson")
    rm -f -- "$STAGE/xr-gate.ndjson"
    if (( ${#direct_tags[@]} )); then tags_json=$(printf '%s\n' "${direct_tags[@]}" | jq -R . | jq -cs .); fi
    if scheme_has_reality "$s" && [[ $(st .reality.guard) == xray ]]; then
        # Keep decoy/guard traffic isolated from optional CN/BT policies.
        fallback_out=$(jq -cn --argjson rules "$base_rules" --arg strategy "$strategy" '[
          {tag:"reality-fallback", protocol:"freedom",
           settings:{finalRules:$rules},
           streamSettings:{sockopt:{domainStrategy:$strategy}}}]')
    fi
    # Remote users and the internal gate have been routed before the local direct policy.
    jq -n --slurpfile inb "$inb" --slurpfile routed "$rules" --slurpfile domains <(printf '%s' "$domains") \
        --argjson gate "$gate" --argjson tags "$tags_json" --arg strategy "$strategy" \
        --argjson final "$(egress_final_rules_json "$base_rules" "$delay_key" "$cn" "$mode")" --argjson fallback "$fallback_out" \
        --slurpfile draft "$DRAFT" '{
        log: {loglevel: "warning", access: "none"},
        inbounds: $inb,
        outbounds: ([{tag: "direct", protocol: "freedom",
                     settings: {finalRules:$final},
                     streamSettings: {sockopt: {domainStrategy: $strategy}}},
                     {tag: "blocked", protocol: "blackhole"}] + $fallback + [$draft[0].landings[] | .outbound + {tag}]),
        routing: {domainStrategy: "AsIs", rules: ($gate + $routed
            + (if ($domains[0] | length) > 0 then [{type:"field", inboundTag:$tags,
                    domain:($domains[0] | map("domain:" + .) | . + map(. + ".")), outboundTag:"blocked"}] else [] end)
            + [{type: "field", inboundTag: $tags, network: "tcp,udp", outboundTag: "direct"},
               {type: "field", network: "tcp,udp", outboundTag: "blocked"}])}
    }' > "$out"
}


render_ss_rust() {
    local cfg=$1 acl=$2 v6first=false domains
    domains=$(blocked_domains_json) || { die '屏蔽域名列表无效。'; return 1; }
    [[ $(st .outbound) == v6first ]] && v6first=true
    jq --arg l "$(listen_any)" --argjson v6 "$v6first" '
        {server:$l, server_port:.ss.port, method:.ss.method, password:.ss.password, mode:"tcp_and_udp", timeout:300,
         ipv6_first:$v6, ipv6_only:false, no_delay:true}' "$DRAFT" > "$cfg"
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
100::/64
fc00::/7
fe80::/10
ff00::/8
2001:db8::/32
(^|\.)localhost$
ACL
    # Match only the blocked IPv4 ranges in both encodings. A blanket
    # ::ffff:0:0/96 also blocks ALL IPv4 traffic in SS-Rust's dual-family ACL.
    local net bits
    while IFS=/ read -r net bits; do
        [[ $net =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && $bits =~ ^[0-9]+$ ]] || continue
        printf '::ffff:%s/%s\n64:ff9b::%s/%s\n' "$net" "$((96 + bits))" "$net" "$((96 + bits))"
    done < "$acl" > "$acl.mapped"
    cat "$acl.mapped" >> "$acl"
    rm -f -- "$acl.mapped"
    # ssserver matches the destination carried by the Shadowsocks request.
    jq -r '.[] | "(?i)(^|[.])" + (split(".") | join("[.]")) + "[.]?$"' <<< "$domains" >> "$acl"
}


nginx_banner_version() {
    local LC_ALL=C line
    local release='^(nginx version:[[:space:]]+)?nginx/([0-9]+\.[0-9]+\.[0-9]+([-+~][[:alnum:]][[:alnum:].+~-]*)?)([[:space:]]|$)'
    while IFS= read -r line; do
        if [[ $line =~ $release ]]; then printf '%s' "${BASH_REMATCH[2]}"; return 0; fi
    done <<< "$1"
    return 1
}

nginx_probe() {
    local build v m module_dir=''
    local -a modules=()
    NGINX_MODULE_LINE='' NGINX_SUPPORTS_E=0 NGINX_SUPPORTS_KEEPALIVE=0 NGINX_PROBE_ERR=''
    if ! build=$(LC_ALL=C LANGUAGE=C timeout -k 2 5 nginx -V 2>&1); then
        printf '%s\n' "$build" >> "${STEP_LOG:-/dev/null}"
        NGINX_PROBE_ERR='读取 Nginx 编译信息失败或超时。'; return 2
    fi
    # Match complete options: --with-stream_ssl_module alone is not Stream.
    if [[ ! $build =~ (^|[[:space:]])--with-stream(=dynamic)?([[:space:]]|$) ]]; then
        NGINX_PROBE_ERR='当前 Nginx 没有编译 Stream 模块。'; return 2
    fi
    if [[ ! $build =~ (^|[[:space:]])--with-stream_ssl_preread_module([[:space:]]|$) ]]; then
        NGINX_PROBE_ERR='Nginx 缺少读取 SNI 所需的 ssl_preread 模块。'; return 2
    fi
    if [[ $build =~ (^|[[:space:]])--without-stream_(map|return|limit_conn)_module([[:space:]]|$) ]]; then
        NGINX_PROBE_ERR='当前 Nginx 缺少前置防护需要的 Stream 功能。'; return 2
    fi
    if [[ $build =~ (^|[[:space:]])--with-stream=dynamic([[:space:]]|$) ]]; then
        if [[ $build =~ --modules-path=([^[:space:]]+) ]]; then
            module_dir=${BASH_REMATCH[1]}
            module_dir=${module_dir#\'}; module_dir=${module_dir%\'}
            module_dir=${module_dir#\"}; module_dir=${module_dir%\"}
            if [[ $module_dir =~ ^/[A-Za-z0-9_./+-]+$ && $module_dir != */../* && $module_dir != */.. ]]; then
                modules+=("$ROOT$module_dir/ngx_stream_module.so")
            fi
        fi
        modules+=("$ROOT/usr/lib/nginx/modules/ngx_stream_module.so"
                  "$ROOT/usr/share/nginx/modules/ngx_stream_module.so")
        for m in "${modules[@]}"; do
            if [[ -f $m ]]; then NGINX_MODULE_LINE="load_module \"$m\";"; break; fi
        done
        # Only a missing dynamic library is eligible for a module package install.
        [[ -n $NGINX_MODULE_LINE ]] || { NGINX_PROBE_ERR='找不到 Nginx Stream 动态模块。'; return 1; }
    fi
    v=$(nginx_banner_version "$build") || v=''
    v=${v%%[-+~]*}
    if [[ -n $v ]] && ver_ge "$v" 1.15.6; then NGINX_SUPPORTS_KEEPALIVE=1; fi
    # -e overrides the compiled-in error log before nginx parses our config (since 1.19.5).
    if [[ -n $v ]] && ver_ge "$v" 1.19.5; then NGINX_SUPPORTS_E=1; else NGINX_SUPPORTS_E=0; fi
}

nginx_detect() {
    nginx_probe && return 0
    die "$NGINX_PROBE_ERR"
    return 1
}

test_nginx_config() {
    local -a opts=()
    local file config=${1:-$NGINX_DIR/nginx.conf}
    check_private_dirs "$NGINX_DIR" "$NGINX_RUN" || return 1
    for file in "$NGINX_DIR/error.log" "$NGINX_RUN/nginx.pid"; do
        if [[ -L $file || ( -e $file && ! -f $file ) ]] ||
            { [[ -f $file ]] && [[ $(stat -c %h -- "$file") != 1 ]]; }; then
            die "Nginx 日志或 PID 文件路径异常：$file"; return 1
        fi
    done
    if (( NGINX_SUPPORTS_E )); then opts=(-e "$NGINX_DIR/error.log"); fi
    timeout -k 2 15 nginx "${opts[@]}" -t -c "$config" -p "$NGINX_DIR/" >> "$STEP_LOG" 2>&1 || {
        die 'Nginx 配置校验失败，详见下方日志。'; return 1
    }
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
    map_hash_bucket_size 512;
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
        if (( NGINX_SUPPORTS_KEEPALIVE )); then printf '        proxy_socket_keepalive on;\n'; fi
        cat <<EOF
        ssl_preread on;
        preread_timeout 5s;
        proxy_connect_timeout 5s;
        proxy_timeout 24h;
        limit_conn zxray_ip $(st .reality.conn_ip);
        limit_conn zxray_total $(st .reality.conn_total);
        limit_conn_log_level notice;
        proxy_protocol on;
        proxy_pass \$zxray_backend;
    }
EOF
        cat <<EOF

    server {
        listen unix:$NGINX_RUN/reject.sock proxy_protocol;
        proxy_protocol_timeout 1s;
        error_log /dev/null crit;
        return "";
    }
EOF
        printf '}\n'
    } > "$out"
}


landing_label() {
    local out=$1
    if [[ $out == direct ]]; then printf '直出'; else printf '落地%s' "${out#landing}"; fi
}

reality_query() {
    printf 'security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&spx=%%2F' \
        "$(url_encode "$(st .reality.sni)")" "$(st .reality.public_key)" "$(reality_short_id)"
}


split_hosts() {
    if [[ $(st .xhttp.split) == v6_up_v4_down ]]; then printf '%s %s' "$(st .net.v6)" "$(st .net.v4)"
    else printf '%s %s' "$(st .net.v4)" "$(st .net.v6)"; fi
}

node_label() {
    local l identity=${3:-direct}
    l="$4-$1"
    [[ ${2:-direct} == direct ]] || l+="-$(landing_label "$2")"
    if [[ $identity =~ ^uuid([0-9]+)$ ]]; then l+="-UUID${BASH_REMATCH[1]}"; fi
    printf '%s' "$l"
}

node_add() { printf '%s' "$2" | jq -Rsc --arg l "$1" '{label:$l, link:.}' >> "$NODES_TMP"; }

node_add_with_v6() {
    local label=$1 link=$2 host=$3 port=$4 v6=$5
    node_add "$label" "$link" || return 1
    if [[ -n $v6 ]]; then
        local l6=${link/"@$(uri_host "$host"):$port"/"@[$v6]:$port"}
        l6="${l6%%#*}#$(url_encode "$label-IPv6")"
        node_add "$label-IPv6" "$l6"
    fi
}

ss_link_userinfo() {
    # SIP002 requires percent-encoded userinfo for AEAD-2022.
    case $1 in
        2022-*) printf '%s:%s' "$(url_encode "$1")" "$(url_encode "$2")" ;;
        *) b64url_nopad "$1:$2" ;;
    esac
}

render_nodes() {
    local out=$1 s host hu
    s=$(scheme)
    NODES_TMP=$out
    : > "$NODES_TMP"
    host=$(st .net.host)
    hu=$(uri_host "$host")
    local id outtag port name label link user_port rows node_prefix v6=''
    node_prefix=$(node_name) || return 1
    if v6_links_on; then v6=$(st .net.v6); fi
    # Local user and route names are fixed identifiers. An unset draft ID is last.
    # Encode VLESS userinfo before TSV so reserved URI characters and backslashes survive export.
    rows=$(jq -r '.scheme as $scheme | .users[] |
        [(.port // 0), .name, .out, (if $scheme == "ss" then .id else ((.id // "") | @uri) end)] | @tsv' "$DRAFT") || return 1

    if scheme_has_reality "$s"; then
        local rq family query endpoint=$hu alternate=$v6
        rq=$(reality_query)
        port=$(st .reality.port)
        case $s in
            reality-xhttp)
                family=XHTTP
                local enc=none flowq='' extra=''
                if [[ $(st .xhttp.enc) == 1 ]]; then enc=$(enc_string client); flowq='&flow=xtls-rprx-vision'; fi
                if [[ $(stj .xhttp.xmux) != null ]]; then extra="&extra=$(url_encode "$(jq -c '{xmux: .xhttp.xmux}' "$DRAFT")")"; fi
                query="encryption=$(url_encode "$enc")$flowq&$rq&type=xhttp&path=$(url_encode "$(st .xhttp.path)")&mode=stream-one$extra" ;;
            reality-split)
                local up down ex
                read -r up down <<< "$(split_hosts)"
                family=XHTTP分离
                endpoint=$(uri_host "$up"); alternate=''
                ex=$(jq -cn --arg a "$down" --argjson p "$port" --arg sni "$(st .reality.sni)" --arg fp chrome \
                    --arg pbk "$(st .reality.public_key)" --arg sid "$(reality_short_id)" --arg path "$(st .xhttp.path)" \
                    '{downloadSettings:{address:$a, port:$p, network:"xhttp", security:"reality",
                      realitySettings:{serverName:$sni, fingerprint:$fp, publicKey:$pbk, shortId:$sid, spiderX:"/"},
                      xhttpSettings:{path:$path}}}')
                query="encryption=none&$rq&type=xhttp&path=$(url_encode "$(st .xhttp.path)")&mode=auto&extra=$(url_encode "$ex")" ;;
            *)
                family=REALITY
                query="encryption=none&flow=xtls-rprx-vision&$rq&type=tcp&headerType=none" ;;
        esac
        while IFS=$'\t' read -r user_port name outtag id; do
            [[ $user_port == 0 && ( $s != triple || $outtag == direct ) ]] || continue
            label=$(node_label "$family" "$outtag" "$name" "$node_prefix")
            link="vless://$id@$endpoint:$port?$query#$(url_encode "$label")"
            node_add_with_v6 "$label" "$link" "$host" "$port" "$alternate" || return 1
        done <<< "$rows"
    fi

    if scheme_has_enc_inbound "$s"; then
        local enc family query endpoint=$hu alternate=$v6
        enc=$(url_encode "$(enc_string client)")
        port=$(st .enc.port)
        if [[ $s == enc-split ]]; then
            local up down ex
            read -r up down <<< "$(split_hosts)"
            family=ENC分离
            endpoint=$(uri_host "$up"); alternate=''
            ex=$(jq -cn --arg a "$down" --argjson p "$port" --arg path "$(st .xhttp.path)" \
                '{downloadSettings:{address:$a, port:$p, network:"xhttp", xhttpSettings:{path:$path}}}')
            query="encryption=$enc&security=none&type=xhttp&path=$(url_encode "$(st .xhttp.path)")&mode=auto&extra=$(url_encode "$ex")"
        else
            family=VLESS-ENC
            query="encryption=$enc&flow=xtls-rprx-vision&security=none&type=tcp&headerType=none"
        fi
        while IFS=$'\t' read -r user_port name outtag id; do
            [[ $user_port == 0 && ( $s == enc || $outtag == direct ) ]] || continue
            label=$(node_label "$family" "$outtag" "$name" "$node_prefix")
            link="vless://$id@$endpoint:$port?$query#$(url_encode "$label")"
            node_add_with_v6 "$label" "$link" "$host" "$port" "$alternate" || return 1
        done <<< "$rows"
    fi

    if scheme_has_ss "$s"; then
        local m pw ui
        m=$(st .ss.method)
        pw=$(st .ss.password)
        ui=$(ss_link_userinfo "$m" "$pw")
        port=$(st .ss.port)
        label=$(node_label SS direct direct "$node_prefix")
        link="ss://$ui@$hu:$port#$(url_encode "$label")"
        node_add_with_v6 "$label" "$link" "$host" "$port" "$v6" || return 1
        if [[ $s == ss ]]; then
            while IFS=$'\t' read -r port name outtag id; do
                [[ -n $port && $port != 0 ]] || continue
                ui=$(ss_link_userinfo "$m" "$id")
                label=$(node_label SS "$outtag" direct "$node_prefix")
                node_add_with_v6 "$label" "ss://$ui@$hu:$port#$(url_encode "$label")" "$host" "$port" "$v6" || return 1
            done <<< "$rows"
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
        reality_short_id_note
        if (( $(jq '.landings | length' "$DRAFT") > 0 )); then
            printf '落地原始链接\n'
            jq -r '.landings[] | "\(.tag | sub("landing"; "落地 ")): \(.link)"' "$DRAFT"
            printf '\n'
        fi
        printf '对外端口\n'
        public_ports | awk '{printf "%s/%s %s\n", $2, toupper($1), $3}'
        printf '\n出站    %s\n' "$(outbound_label "$(st .outbound)")"
        printf '直出限制  %s\n' "$(egress_label)"
        if scheme_has_reality "$s"; then
            if [[ $(st .reality.guard) == nginx ]]; then printf '防护    Nginx SNI 过滤\n'
            else printf '防护    Xray 内置 SNI 过滤\n'; fi
            limit_text | sed '1s/^/限速    /; 2,$s/^/        /'
            printf '\n'
        fi
        if [[ $(scheme_transport "$s") == xhttp ]]; then
            printf 'XHTTP   请使用 Xray 内核客户端，关闭通用 Mux.cool\n'
        fi
        if [[ $s == ss && $(ss_core) == ss-rust ]]; then
            printf 'SS-Rust 拦截私网等特殊地址，SMTP 端口不单独拦截\n'
        fi
    } > "$out"
}


installed_version() { jq -r ".installed.$1 // empty" "$STATE" 2>/dev/null || true; }

manager_launcher_text() {
    printf '#!/bin/sh\n%s\nexec bash "%s" "$@"\n' "$MANAGED_TAG" "$SELF_SCRIPT_PATH"
}

is_manager_launcher() {
    local LC_ALL=C expected actual='' rc=0
    [[ ! -L $1 && -f $1 && -r $1 ]] || return 1
    expected=$(manager_launcher_text)$'\n'
    # Preflight runs before cmp is installed. A NUL or an extra byte disqualifies the file.
    IFS= read -r -d '' -n "$(( ${#expected} + 1 ))" actual < "$1" || rc=$?
    [[ $rc == 1 && $actual == "$expected" ]]
}

is_core_link() {
    local target
    [[ -L $PUBLIC_XRAY ]] || return 1
    target=$(readlink -- "$PUBLIC_XRAY" && printf x) || return 1
    [[ $target == "$CORE_BIN"$'\nx' ]]
}

other_xray_on_path() {
    local p
    while IFS= read -r p; do
        [[ -f $p && -x $p && ! $p -ef $PUBLIC_XRAY && ! $p -ef $QUICK_BIN &&
            ! $p -ef $SELF_SCRIPT_PATH ]] || continue
        is_manager_launcher "$p" || return 0
    done < <(type -aP xray 2>/dev/null)
    return 1
}

check_launcher_slot() {
    [[ ! -e $QUICK_BIN && ! -L $QUICK_BIN ]] || is_manager_launcher "$QUICK_BIN" || {
        die "$QUICK_BIN 已被其他程序占用，无法创建 zxray 管理命令。"; return 1;
    }
}

# Only an existing state and our exact service command authorize the old core path.
legacy_core_owned() {
    local file schema
    [[ ! -L $STATE && -f $STATE && ! -L $PUBLIC_XRAY ]] || return 1
    [[ ! -e $PUBLIC_XRAY || -f $PUBLIC_XRAY ]] || return 1
    schema=$(jq -r '.schema // 0' "$STATE" 2>/dev/null) || return 1
    [[ $schema == 4 || $schema == "$STATE_SCHEMA" ]] || return 1
    file=$SYSTEMD_DIR/xray.service
    is_managed_file "$file" && grep -Fxq "ExecStart=$PUBLIC_XRAY run -config $CONFIG_FILE" "$file" || return 1
    ! is_managed_file "$PUBLIC_XRAY"
}

select_core_path() {
    XRAY_BIN=$CORE_BIN
    LEGACY_CORE_OWNED=0
    if legacy_core_owned; then
        LEGACY_CORE_OWNED=1
        XRAY_BIN=$PUBLIC_XRAY
    fi
    return 0
}

# Keep older services on their native executable; expose private cores with a link.
sync_native_command() {
    local tmp
    if ! needs_xray; then
        if is_core_link || is_manager_launcher "$PUBLIC_XRAY"; then rm -f -- "$PUBLIC_XRAY" || return 1; fi
        return 0
    fi
    is_regular_executable "$XRAY_BIN" || {
        die "找不到可执行的 Xray 核心：$XRAY_BIN"; return 1;
    }
    [[ $XRAY_BIN != "$PUBLIC_XRAY" ]] || return 0
    if [[ -e $PUBLIC_XRAY || -L $PUBLIC_XRAY ]] && ! is_core_link && ! is_manager_launcher "$PUBLIC_XRAY"; then
        ui_note "保留已有的 $PUBLIC_XRAY，本工具使用的核心位于 $CORE_BIN。"
        return 0
    fi
    if other_xray_on_path; then
        # The public slot is empty or belongs to us. Expose the existing command again.
        rm -f -- "$PUBLIC_XRAY" || return 1
        return 0
    fi
    is_core_link && return 0
    tmp=$(mktemp "$PUBLIC_XRAY.new.XXXXXX") || return 1
    if ! ln -sf -- "$CORE_BIN" "$tmp" || ! mv -fT -- "$tmp" "$PUBLIC_XRAY"; then
        rm -f -- "$tmp"
        die "无法创建 Xray 核心命令：$PUBLIC_XRAY"; return 1
    fi
    return 0
}

core_satisfied() {
    local which=$1 want cur old
    state_ok || return 1
    want=$(st ".core.$which")
    case $which in
        xray)
            is_regular_executable "$XRAY_BIN" || return 1
            service_readable_files --exec "$XRAY_BIN" >/dev/null || return 1
            needs_full_geo || installed_geodata_usable || return 1
            cur=$(xray_version_of "$XRAY_BIN") && ver_ge "$cur" "$XRAY_MIN_VERSION" || return 1 ;;
        ss)
            is_regular_executable "$SS_BIN" || return 1
            service_readable_files --exec "$SS_BIN" >/dev/null || return 1
            cur=$(ss_version_of "$SS_BIN") || return 1 ;;
        *) return 1 ;;
    esac
    old=$(jq -r ".core.$which // empty" "$STATE" 2>/dev/null || true)
    [[ -n $cur ]] || return 1
    case $want in
        compat) return 1 ;;
        latest) [[ $old == latest || ( $which == xray && $old == compat ) ]] ;;
        *) [[ ${cur#v} == "${want#v}" ]] ;;
    esac
}

needs_full_geo() {
    needs_xray && [[ $(st '.egress.cn // 0') == 1 ]]
}

check_xray_asset_dir() {
    if [[ -L $XRAY_ASSET_DIR || ( -e $XRAY_ASSET_DIR && ! -d $XRAY_ASSET_DIR ) ]]; then
        die "地理规则需要普通目录，请先移走异常路径：$XRAY_ASSET_DIR"; return 1
    fi
}

geodata_files_ok() {
    local file
    [[ ! -L $1 && -d $1 ]] || return 1
    for file in "$1/geoip.dat" "$1/geosite.dat"; do
        [[ ! -L $file && -f $file && -s $file ]] || return 1
    done
}

installed_geodata_usable() {
    geodata_files_ok "$XRAY_ASSET_DIR" && service_readable_files "$XRAY_ASSET_DIR/geoip.dat" "$XRAY_ASSET_DIR/geosite.dat" >/dev/null
}

readonly FULL_GEO_LABEL='XTLS/Xray-rules-dat: GeoIP Full, GeoSite Expanded'

full_geo_receipt() (
    cd -- "$1" && printf '%s\n' "$FULL_GEO_LABEL" && sha256sum -- geoip.dat geosite.dat
)

full_geo_fresh() {
    local m=$XRAY_ASSET_DIR/.zxray-full-geo t now receipt
    [[ ! -L $m && -f $m && -s $m ]] || return 1
    t=$(stat -c %Y -- "$m") && now=$(date +%s) || return 1
    [[ $t =~ ^[0-9]+$ ]] && (( t > 0 && now >= t && now - t <= 604800 )) || return 1
    installed_geodata_usable || return 1
    if cmp -s -- "$m" <(printf '%s\n' "$FULL_GEO_LABEL"); then
        # Old receipts have no hashes. A newer data file no longer belongs to this refresh.
        [[ ! $XRAY_ASSET_DIR/geoip.dat -nt $m && ! $XRAY_ASSET_DIR/geosite.dat -nt $m ]]
        return
    fi
    # Hash fixed names only. Never let a receipt supply filenames or checksum options.
    receipt=$(full_geo_receipt "$XRAY_ASSET_DIR") || return 1
    cmp -s -- "$m" <(printf '%s\n' "$receipt")
}

download_full_geodata() {
    # Same official XTLS/Xray-rules-dat Full / Expanded assets used by Xray-install.
    # Download before touching installed files; verify both compressed archives.
    local name gz digest got base tag
    FULL_GEO_DIR=$STAGE/core/full-geodata
    mkdir -p -- "$FULL_GEO_DIR" || return 1
    latest_tag XTLS/Xray-rules-dat tag || return 1
    base="https://github.com/XTLS/Xray-rules-dat/releases/download/$tag"
    for name in geoip-full geosite-expand; do
        gz=$name.dat.gz
        fetch "$base/$gz" "$FULL_GEO_DIR/$gz" || return 1
        fetch "$base/$gz.sha256sum" "$FULL_GEO_DIR/$gz.sha256sum" || return 1
        digest=$(awk 'NR==1 {print $1}' "$FULL_GEO_DIR/$gz.sha256sum")
        [[ $digest =~ ^[0-9a-fA-F]{64}$ ]] || {
            die "$gz 的 SHA-256 文件格式不正确。"; return 1;
        }
        got=$(sha256_of "$FULL_GEO_DIR/$gz")
        [[ ${got,,} == "${digest,,}" ]] || {
            die "$gz 的 SHA-256 校验失败。"; return 1;
        }
        if [[ $name == geoip-full ]]; then
            gzip -dc -- "$FULL_GEO_DIR/$gz" > "$FULL_GEO_DIR/geoip.dat" || {
                die '解压 GeoIP Full 失败。'; return 1;
            }
        else
            gzip -dc -- "$FULL_GEO_DIR/$gz" > "$FULL_GEO_DIR/geosite.dat" || {
                die '解压 GeoSite Expanded 失败。'; return 1;
            }
        fi
        rm -f -- "$FULL_GEO_DIR/$gz" "$FULL_GEO_DIR/$gz.sha256sum"
    done
    geodata_files_ok "$FULL_GEO_DIR" || {
        die '解压后的 geoip.dat 或 geosite.dat 无效。'; return 1;
    }
    full_geo_receipt "$FULL_GEO_DIR" > "$FULL_GEO_DIR/.zxray-full-geo" || {
        die '无法记录完整地理规则的校验值。'; return 1;
    }
    USE_XRAY_ASSET=$FULL_GEO_DIR
    GEO_REFRESH=1
}

install_xray_geodata() {
    local src=$USE_XRAY_ASSET file
    check_xray_asset_dir || return 1
    [[ $src != "$XRAY_ASSET_DIR" ]] || return 0
    geodata_files_ok "$src" || { die '待安装的 geoip.dat 或 geosite.dat 无效。'; return 1; }
    make_dir "$XRAY_ASSET_DIR" && chmod 755 -- "$XRAY_ASSET_DIR" || return 1
    for file in geoip.dat geosite.dat; do
        atomic_install "$src/$file" "$XRAY_ASSET_DIR/$file" 644 replace-link || return 1
    done
    if (( GEO_REFRESH )); then
        atomic_install "$src/.zxray-full-geo" "$XRAY_ASSET_DIR/.zxray-full-geo" 644 replace-link
    else
        rm -f -- "$XRAY_ASSET_DIR/.zxray-full-geo"
    fi
}

plan_cores() {
    USE_XRAY='' USE_SS='' NEW_XRAY=0 NEW_SS=0 GEO_REFRESH=0 FULL_GEO_DIR=''
    if needs_xray; then
        check_xray_asset_dir || return 1
        if needs_full_geo && ! full_geo_fresh; then GEO_REFRESH=1; fi
        if core_satisfied xray; then
            USE_XRAY=$XRAY_BIN USE_XRAY_ASSET=$XRAY_ASSET_DIR
        else NEW_XRAY=1; fi
    fi
    if needs_ss_rust; then
        if core_satisfied ss; then USE_SS=$SS_BIN
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
    if (( GEO_REFRESH )); then download_full_geodata
    elif needs_full_geo; then
        if full_geo_fresh; then USE_XRAY_ASSET=$XRAY_ASSET_DIR
        else download_full_geodata; fi
    fi
}

validate_xray_config() {
    local cfg=$1
    if XRAY_LOCATION_ASSET=$USE_XRAY_ASSET timeout -k 2 20 "$USE_XRAY" run -test -config "$cfg" >> "$STEP_LOG" 2>&1; then
        return 0
    fi
    if grep -Fq 'vless without TLS or other encryption is prohibited' "$STEP_LOG"; then
        die '此 VLESS 落地需要加密。请核对链接的 REALITY 或 VLESS-ENC 参数。'
    else
        die 'Xray 配置校验失败，详见下方日志。'
    fi
    return 1
}

validate_ss_rust() {
    local cfg=$1 acl=$2 p child ok=0 k rc=0 mode proto rows addr addr_key probe=127.0.0.1
    local -a protocols
    # A secondary server must never retain its production bind address in a test run.
    addr=$(jq -er 'select(.servers == null or .servers == []) | .server | strings | select(length > 0)' "$cfg") || {
        die 'SS-Rust 试运行需要单入口配置，请检查 server 和 servers。'; return 1;
    }
    if [[ $addr == *:* ]]; then
        addr_key=$(ip_key "$addr") || { die 'SS-Rust 的 IPv6 监听地址无效。'; return 1; }
        rows=$(timeout -k 2 5 ip -o -6 addr show dev lo up to ::1/128) || {
            die '无法查询 lo 的 IPv6 地址。'; return 1;
        }
        if [[ -n $rows && ! $rows =~ [[:space:]](tentative|dadfailed)[[:space:]] ]]; then
            probe=::1
        elif [[ $addr_key == v6:0:0:0:0:0:0:0:0 ]] && jq -e '.ipv6_only == null or .ipv6_only == false' "$cfg" >/dev/null; then
            # A dual-stack wildcard can work with IPv6 on an external interface only.
            # Preflight stays on loopback; health_check verifies the real IPv6 listener.
            rows=$(timeout -k 2 5 ip -o -4 addr show dev lo up to 127.0.0.0/8) || {
                die '无法查询 lo 的 IPv4 地址。'; return 1;
            }
            probe=$(awk '$3 == "inet" {split($4, a, "/"); if (a[1] ~ /^127[.]/) {print a[1]; exit}}' <<< "$rows")
            [[ $probe == 127.* ]] && valid_ipv4 "$probe" || { die 'lo 上缺少可用于 SS-Rust 试运行的回环地址。'; return 1; }
        else
            die '此 IPv6 配置需使用 ::1 试运行，请先在 lo 上启用 IPv6 回环地址。'; return 1
        fi
    fi
    p=$(random_free_port) || return 1
    jq -e --arg probe "$probe" --argjson p "$p" '.server = $probe | .server_port = $p' "$cfg" > "$STAGE/ss-check.json" || return 1
    mode=$(jq -r '.mode // "tcp_only"' "$STAGE/ss-check.json") || return 1
    case $mode in
        tcp_and_udp) protocols=(tcp udp) ;;
        tcp_only) protocols=(tcp) ;;
        udp_only) protocols=(udp) ;;
        *) die 'SS-Rust 配置中的监听模式无效。'; return 1 ;;
    esac
    "$USE_SS" -c "$STAGE/ss-check.json" --acl "$acl" >> "$STEP_LOG" 2>&1 3>&- 4>&- 5>&- 8>&- 9>&- &
    child=$!
    for k in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.3
        if ! kill -0 "$child" 2>/dev/null; then break; fi
        for proto in "${protocols[@]}"; do
            rows=$(listeners "$proto" "$p") || { rc=2; break 2; }
            listeners_only_pid "$rows" "$child" || continue 2
        done
        ok=1
        break
    done
    kill "$child" 2>/dev/null || true
    for k in {1..20}; do
        kill -0 "$child" 2>/dev/null || break
        sleep 0.1
    done
    kill -KILL "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    (( rc <= 1 )) || { port_query_failed; return 1; }
    (( ok )) || { die 'SS-Rust 试运行失败，详见下方日志。'; return 1; }
}

nginx_system_hash() {
    local format=${1:-v2} sum path
    [[ -d $ROOT/etc/nginx && ! -L $ROOT/etc/nginx ]] || return 1
    sum=$(cd "$ROOT/etc/nginx" && {
        # New v2 hashes always use byte order. old-v2 and legacy reproduce
        # the original regular-file order in the caller's locale.
        if [[ $format == v2 ]]; then export LC_ALL=C; fi
        find . -type f -print0 | sort -z | xargs -0 -r sha256sum || exit 1
        if [[ $format != legacy ]]; then
            find . -type l -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' path; do
                printf '\0%s\0' "$path" && readlink -- "$path" || exit 1
            done
        fi
    } | sha256sum) || return 1
    [[ $format == legacy ]] || printf 'v2:'
    printf '%s' "${sum%% *}"
}

# Read static module links from the package postinst, never execute it.
nginx_deb_module_link() {
    local file=$1 owner base=${1##*/} name
    [[ $base =~ ^[a-zA-Z0-9_.+-]+[.]conf$ ]] || return 1
    owner=$(timeout -k 2 15 dpkg-query -S "$file") || return 1
    [[ $owner == *": $file" ]] || return 1
    owner=${owner%": $file"}
    [[ $owner =~ ^[a-z0-9][a-z0-9.+-]*(:[a-z0-9-]+)?$ ]] || return 1
    name=$(timeout -k 2 15 dpkg-query --control-show "$owner" postinst |
        awk -v base="$base" '
        function remember(value) {
            if (found && name != value) bad=1
            name=value; found=1
        }
        function pairs(s, n, a, i, p) {
            gsub(/^[ \t]+|[ \t]+$/, "", s)
            n=split(s, a, /[ \t]+/)
            for (i=1; i<=n; i++) {
                if (a[i] !~ /^[a-zA-Z0-9_.+-]+[.]conf:[0-9][0-9]-[a-zA-Z0-9_.+-]+[.]conf$/) bad=1
                else if (split(a[i], p, ":") == 2 && p[1] == base) remember(p[2])
            }
        }
        function literal(s, q) {
            q=substr(s, 1, 1)
            if (q == "\"" || q == sprintf("%c", 39)) {
                if (substr(s, length(s), 1) != q) return ""
                s=substr(s, 2, length(s)-2)
            }
            return s
        }
        {
            line=continued $0; continued=""
            if (sub(/\\$/, "", line)) {continued=line; next}
            sub(/[ \t]+#.*/, "", line)
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line == "" || line ~ /^#/) next
            if (!pending && sub(/^for[ \t]+confpair[ \t]+in([ \t]+|$)/, "", line)) pending=1
            if (pending) {
                if (line == "do" || sub(/;[ \t]*do$/, "", line)) {
                    if (line == "do") {line=""; sub(/;[ \t]*$/, "", header)}
                    pairs(header " " line); header=""; pending=0
                } else header=header " " line
                next
            }
            if (line !~ /^ln[ \t]+/) next
            sub(/[ \t]*;$/, "", line)
            n=split(line, a, /[ \t]+/); i=2; flags=""
            while (a[i] ~ /^-[sfnT]+$/) {flags=flags a[i]; i++}
            if (a[i] == "--") i++
            if (!index(flags, "s") || n != i+1) next
            from=literal(a[i]); to=literal(a[i+1])
            if (from != "/usr/share/nginx/modules-available/" base) next
            if (!sub(/^\/etc\/nginx\/modules-enabled\//, "", to)) bad=1
            else remember(to)
        }
        END {if (bad || pending || continued != "" || !found) exit 1; print name}') || return 1
    [[ $name == [0-9][0-9]-"$base" ]] || return 1
    printf '%s' "$name"
}

# Only adopt a changed baseline when the installed packages account for the
# configuration. In particular dpkg does not record the targets of symlinks.
nginx_stock_config() {
    local paths changes dir=$ROOT/etc/nginx file target name conffiles
    local -A module_links=()
    (( $# )) && [[ -d $dir && ! -L $dir ]] || return 1
    # dpkg lists package directories. Unknown empty subdirectories are still user data.
    paths=$(timeout -k 2 15 dpkg-query -L -- "$@") && changes=$(timeout -k 2 30 dpkg --verify -- "$@" 2>&1) || return 1
    # A package directory replaced by an ordinary file has no dpkg content digest.
    conffiles=$(timeout -k 2 15 dpkg-query -W -f='${Conffiles}\n' -- "$@" | awk '
        length($NF) == 32 && $NF ~ /^[[:xdigit:]]+$/ {
            sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+[[:xdigit:]]+$/, ""); print
        }') || return 1
    while IFS= read -r file; do
        case $file in
            /etc/nginx/modules) [[ -L $dir/modules ]] || return 1 ;;
            /etc/nginx/sites-available/default) [[ -L $dir/sites-enabled/default ]] || return 1 ;;
            /usr/share/nginx/modules-available/*.conf)
                name=$(nginx_deb_module_link "$file") || return 1
                module_links["$name"]=$file
                [[ -L $dir/modules-enabled/$name ]] || return 1 ;;
        esac
    done <<< "$paths"
    [[ -z $changes ]] || return 1
    find "$dir" -mindepth 1 -print0 | while IFS= read -r -d '' file; do
        [[ $file != *[[:cntrl:]]* ]] || exit 1
        if [[ ! -L $file ]]; then
            if grep -Fx -- "${file#"$ROOT"}" <<< "$conffiles" >/dev/null; then
                [[ -f $file ]] || exit 1
            else
                [[ -d $file ]] || exit 1
            fi
        else
            target=$(readlink -- "$file") || exit 1
            case $file in
                "$dir/modules")
                    [[ $target == /usr/lib/nginx/modules || $target == ../../usr/lib/nginx/modules ]] || exit 1
                    [[ -d $ROOT/usr/lib/nginx/modules && ! -L $ROOT/usr/lib/nginx/modules ]] || exit 1
                    grep -Fx -- /etc/nginx/modules <<< "$paths" >/dev/null || exit 1
                    grep -Fx -- /usr/lib/nginx/modules <<< "$paths" >/dev/null || exit 1
                    continue ;;
                "$dir/sites-enabled/default")
                    [[ $target == ../sites-available/default || $target == /etc/nginx/sites-available/default ]] || exit 1
                    file=$dir/sites-available/default ;;
                "$dir/modules-enabled/"[0-9][0-9]-*.conf)
                    name=${file##*/}
                    [[ $name =~ ^[0-9][0-9]-[a-zA-Z0-9_.+-]+[.]conf$ && -n $target ]] || exit 1
                    [[ ${module_links["$name"]:-} == "$target" ]] || exit 1
                    file=$ROOT$target ;;
                *) exit 1 ;;
            esac
            [[ -f $file && ! -L $file ]] || exit 1
        fi
        grep -Fx -- "${file#"$ROOT"}" <<< "$paths" >/dev/null || exit 1
    done
}

# Debian nginx-common's purge script recursively removes these three directories.
nginx_deb_purge_safe() {
    local conf=$ROOT/etc/nginx data=$ROOT/var/lib/nginx logs=$ROOT/var/log/nginx dir path p entry
    local -a dirs=() config_packages=()
    for dir in "$conf" "$data" "$logs"; do
        [[ ! -L $dir ]] || return 1
        [[ -e $dir ]] || continue
        [[ -d $dir ]] || return 1
        dirs+=("$dir")
    done
    check_transaction_mounts "${dirs[@]}" || return 1
    if [[ -d $conf ]]; then
        for p in "$@"; do
            case ${p%%:*} in nginx|nginx-*|libnginx-mod-*) config_packages+=("$p") ;; esac
        done
        entry=$(find "$conf" -mindepth 1 -printf x -quit) || return 1
        if [[ -n $entry ]]; then nginx_stock_config "${config_packages[@]}" || return 1; fi
    fi
    for dir in "$data" "$logs"; do
        [[ -d $dir ]] || continue
        find "$dir" -mindepth 1 -print0 | while IFS= read -r -d '' path; do
            [[ ! -L $path ]] || exit 1
            case $path in
                "$data/body"|"$data/fastcgi"|"$data/proxy"|"$data/scgi"|"$data/uwsgi")
                    [[ -d $path ]] || exit 1 ;;
                "$logs/access.log"|"$logs/error.log")
                    [[ -f $path && ! -s $path ]] || exit 1 ;;
                *) exit 1 ;;
            esac
        done || return 1
    done
    return 0
}

nginx_hash_matches() {
    local baseline=$1 current format loc key first_utf8=''
    local effective=${LC_ALL:-${LC_COLLATE:-${LANG:-C}}}
    local -a candidates=()
    local -A installed=([c]=C) tried=()
    shift
    if [[ $baseline =~ ^v2:[0-9a-f]{64}$ ]]; then
        current=$(nginx_system_hash) || return 1
        [[ $current != "$baseline" ]] || return 0
        (( $# )) || return 1
        format=old-v2
    elif [[ $baseline =~ ^[0-9a-f]{64}$ ]]; then
        # This old hash did not cover symlinks. Verify package defaults too.
        nginx_stock_config "$@" || return 1
        format=legacy
    else
        return 1
    fi
    current=$(nginx_system_hash "$format") || return 1
    [[ $current != "$baseline" ]] || return 0
    # Older installs used the UI/SSH locale. Only retry stock files, and
    # always require the original digest; package defaults alone are not proof.
    if [[ $format == old-v2 ]]; then nginx_stock_config "$@" || return 1; fi
    key=${effective,,}; key=${key//-/}; [[ $key != posix ]] || key=c
    tried[$key]=1
    # v2 already checked this exact hash with LC_ALL=C.
    if [[ $format == old-v2 ]]; then tried[c]=1; fi
    while IFS= read -r loc; do
        [[ -n $loc ]] || continue
        key=${loc,,}; key=${key//-/}; [[ $key != posix ]] || key=c
        [[ -n ${installed[$key]:-} ]] || installed[$key]=$loc
        case $key in *utf8*) [[ -n $first_utf8 ]] || first_utf8=$loc ;; esac
    done < <(locale -a 2>/dev/null || true)
    # Bound the candidates regardless of locales-all size. Match aliases
    # to installed names so unsupported locales never cause retry warnings.
    candidates=("$NGINX_LEGACY_COLLATE" C C.UTF-8 en_US.UTF-8 "$first_utf8" "${LANG:-}" "${LC_CTYPE:-}")
    for loc in "${candidates[@]}"; do
        [[ -n $loc ]] || continue
        key=${loc,,}; key=${key//-/}; [[ $key != posix ]] || key=c
        [[ -n ${installed[$key]:-} && -z ${tried[$key]:-} ]] || continue
        tried[$key]=1
        loc=${installed[$key]}
        current=$(LC_ALL="$loc" nginx_system_hash "$format") || return 1
        [[ $current != "$baseline" ]] || return 0
    done
    return 1
}

record_nginx_install() {
    local path arch observed current delta previous
    local -a touched=()
    for path in "$TX/pkgs-plan" "$TX/pkgs-before" "$TX/pkgs-events" "$TX/new-packages"; do
        [[ -f $path && ! -L $path ]] || return 1
    done
    [[ -s $TX/pkgs-plan && -s $TX/pkgs-before ]] || return 1
    arch=$(dpkg --print-architecture) && [[ -n $arch ]] || return 1
    # Only dpkg children of this apt invocation write this receipt. Match native
    # packages in the simulated plan and an actual unpack/configure transition.
    observed=$(LC_ALL=C awk -v arch="$arch" '
        function native_name(token,    n, parts) {
            n = split(token, parts, ":")
            if (n != 1 && (n != 2 || (parts[2] != arch && parts[2] != "all"))) return ""
            return (parts[1] in plan || token in plan) ? parts[1] : ""
        }
        NR == FNR {plan[$0] = 1; next}
        NF == 3 && $1 == "processing:" && $2 == "install:" {
            name = native_name($3); if (name != "") started[name] = 1; next
        }
        NF == 3 && $1 == "status:" && $2 ~ /:$/ &&
            $3 ~ /^(half-installed|unpacked|half-configured|triggers-awaited|triggers-pending|installed)$/ {
            sub(/:$/, "", $2); name = native_name($2)
            if (name in started) print name
        }
    ' "$TX/pkgs-plan" "$TX/pkgs-events" | LC_ALL=C sort -u) || return 1
    if [[ -n $observed ]]; then mapfile -t touched <<< "$observed"; fi
    current=$(pkg_snapshot native-present) || return 1
    delta=$(pkg_added_since "$TX/pkgs-before" "$current" "${touched[@]}") || return 1
    if [[ -n $delta ]]; then
        previous=$(cat -- "$TX/new-packages") || return 1
        printf '%s\n' "$previous" "$delta" | awk 'NF && !seen[$0]++' | atomic_write "$TX/new-packages" 600 || return 1
    fi
    if (( $# )); then printf -v "$1" '%s' "${delta//$'\n'/ }"; fi
}

nginx_install_batch() {
    local __nb_var=$1 __nb_shared=$2 __nb_plan __nb_op __nb_pkg __nb_rest __nb_before __nb_added='' __nb_rc=0 __nb_mask='' __nb_mrc=0
    shift 2
    printf -v "$__nb_var" '%s' ''
    local -a __nb_args=(--no-remove --no-upgrade --no-install-recommends "$@") __nb_expected=("$@")
    [[ -f $TX/ready ]] || { die '缺少 Nginx 安装恢复记录，已停止。'; return 1; }
    # Include unfinished installs and residual conffiles. If apt would configure
    # one of these, rolling back just our newly installed packages cannot undo it.
    __nb_before=$(pkg_snapshot present) || { die '无法记录安装前的软件包状态。'; return 1; }
    if ! __nb_plan=$(LC_ALL=C LANGUAGE=C timeout -k 5 30 apt-get -s install "${__nb_args[@]}" 2>&1); then
        printf '%s\n' "$__nb_plan" >> "$STEP_LOG"
        die 'Nginx 依赖无法满足。' '请检查 Nginx 与模块的软件源、版本及软件包锁定（hold）状态。'; return 1
    fi
    printf '%s\n' "$__nb_plan" >> "$STEP_LOG"
    while read -r __nb_op __nb_pkg __nb_rest; do
        case $__nb_op in
            Remv|Purg) die '安装 Nginx 会移除已有软件包，已停止。'; return 1 ;;
            Inst|Conf)
                __nb_expected+=("$__nb_pkg")
                if [[ $'\n'$__nb_before$'\n' == *$'\n'"${__nb_pkg%%:*}"$'\n'* || ( $__nb_op == Inst && $__nb_rest == \[* ) ]]; then
                    die "安装 Nginx 需要改动已有软件包 $__nb_pkg，已停止。" '请检查软件源和软件包版本后重试。'; return 1
                fi ;;
        esac
    done <<< "$__nb_plan"
    printf '%s\n' "${__nb_expected[@]}" | LC_ALL=C sort -u | atomic_write "$TX/pkgs-plan" 600 || return 1
    # Bind an interrupted-install recovery to the exact release in apt's proposal.
    awk '$1 == "Inst" && $3 ~ /^\(/ {sub(/^\(/, "", $3); print $2, $3}' <<< "$__nb_plan" |
        atomic_write "$TX/pkgs-versions" 600 || return 1
    : > "$TX/pkgs-events" || return 1
    printf '%s\n' "$__nb_before" | atomic_write "$TX/pkgs-before" 600 || return 1
    if (( ! __nb_shared )); then
        __nb_mask=$(timeout -k 2 5 systemctl is-enabled nginx 2>/dev/null) || __nb_mrc=$?
        if [[ $__nb_mask != masked && $__nb_mask != masked-runtime ]]; then
            case $__nb_mrc in 0|1|4) ;; *) die '无法确认 Nginx 系统服务状态。'; return 1 ;; esac
            : > "$TX/nginx-masked" || return 1
            timeout -k 2 15 systemctl mask nginx >> "$STEP_LOG" 2>&1 || { die '无法暂时阻止系统 Nginx 自动启动。'; return 1; }
        fi
    fi
    # dpkg executes this fixed logger via /bin/sh. The root-private receipt
    # complements apt's status fd and survives interruption before apt returns.
    ZXRAY_DPKG_EVENTS="$TX/pkgs-events" pkg_install -o 'Dpkg::Options::=--status-logger=cat >> "$ZXRAY_DPKG_EVENTS"' \
        "${__nb_args[@]}" >> "$STEP_LOG" 2>&1 || __nb_rc=$?
    record_nginx_install __nb_added || { die '无法核实本次安装的软件包，已保留恢复记录。'; return 1; }
    printf -v "$__nb_var" '%s' "$__nb_added"
    if (( __nb_rc == 0 )); then
        rm -f -- "$TX/pkgs-before" || return 1
        rm -f -- "$TX/pkgs-plan" "$TX/pkgs-events" "$TX/pkgs-versions" || return 1
    fi
    if [[ -f $TX/nginx-masked ]]; then
        timeout -k 2 15 systemctl unmask nginx >> "$STEP_LOG" 2>&1 || { die '恢复 Nginx 系统服务状态失败。'; return 1; }
        rm -f -- "$TX/nginx-masked" || return 1
    fi
    if (( __nb_rc != 0 )); then
        die 'Nginx 软件包安装失败。' '详细原因见下方日志。'; return 1
    fi
}

prepare_nginx() {
    local had_nginx=0 rc=0 added='' all_added='' own_config=0 hash
    [[ -e $ROOT/etc/nginx || -L $ROOT/etc/nginx ]] || own_config=1
    if have nginx; then
        had_nginx=1
        nginx_probe || rc=$?
        (( rc != 0 )) || return 0
        if (( rc != 1 )); then die "$NGINX_PROBE_ERR" '请使用包含所需功能的 Nginx，或改用「Xray 内置」防护。'; return 1; fi
    else
        svc_exists nginx || rc=$?
        (( rc <= 1 )) || { die '无法确认已有 Nginx 服务，已停止安装。'; return 1; }
        if (( rc == 0 )) || pkg_installed nginx; then
            die '检测到已有 Nginx，但 nginx 命令不可用。' '请先修复已有安装后重试。'; return 1
        fi
    fi
    (( ! had_nginx )) || : > "$TX/shared-nginx" || return 1
    pkg_refresh >> "$STEP_LOG" 2>&1 || { die '软件源索引更新失败，已停止安装 Nginx。'; return 1; }
    if (( ! had_nginx )); then
        # nginx.org includes Stream in nginx itself; do not mix in Debian modules.
        nginx_install_batch added "$had_nginx" nginx || return 1
        all_added=$added
        rc=0; nginx_probe || rc=$?
    fi
    if (( rc == 1 )); then
        nginx_install_batch added "$had_nginx" libnginx-mod-stream || return 1
        all_added+=" $added"
        nginx_detect || return 1
    elif (( rc != 0 )); then die "$NGINX_PROBE_ERR"; return 1; fi
    if (( ! had_nginx )); then
        svc_stop_disable nginx || return 1
        st_filter --argjson add "$(json_words "$all_added")" '.meta.nginx_packages = ((.meta.nginx_packages + $add) | unique)'
        if (( own_config )); then
            hash=$(nginx_system_hash) || return 1
            st_sets .meta.nginx_hash "$hash"
        else
            st_sets .meta.nginx_hash ''
        fi
    elif [[ -n $all_added ]]; then
        st_filter --argjson add "$(json_words "$all_added")" '.meta.extra_packages = (((.meta.extra_packages // []) + $add) | unique)'
    fi
}


tx_snapshot_sysctl() {
    local key=$1 current=$2 file saved
    (( TX_ACTIVE )) || return 0
    [[ -f $TX/ready && $current =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    case $key in
        net.ipv4.tcp_congestion_control) file=$TX/cc ;;
        net.core.default_qdisc) file=$TX/qdisc ;;
        *) return 1 ;;
    esac
    if [[ -s $file ]]; then
        saved=$(cat -- "$file") || return 1
        [[ $saved =~ ^[a-zA-Z0-9_-]+$ ]]
    else
        printf '%s\n' "$current" | atomic_write "$file" 600
    fi
}

# Both values form one baseline; partial or concatenated JSON cannot restore it.
load_bbr_original() {
    local record=$DATA_DIR/bbr-original.json pair
    if [[ -L $record || ! -f $record ]] || ! pair=$(jq -ers '
        select(length == 1) | .[0] | select(type == "object") | [.cc, .qdisc]
        | select(all(.[]; type == "string" and length > 0 and (test("[^A-Za-z0-9_-]") | not)))
        | join(" ")' "$record"); then
        die "BBR 原始参数记录缺失或损坏：$record" '请核实原来的拥塞控制和队列算法，从备份恢复记录后重试。'
        return 1
    fi
    if (( $# )); then
        local -n bbr_values=$1
        IFS=' ' read -r -a bbr_values <<< "$pair"
    fi
    return 0
}

configure_bbr() {
    if [[ $(st .bbr) != 1 ]]; then
        restore_bbr_original || return 1
        if is_managed_file "$SYSCTL_FILE"; then
            rm -f -- "$SYSCTL_FILE" || return 1
        fi
        return 0
    fi
    local cc q
    timeout -k 2 10 modprobe tcp_bbr >/dev/null 2>&1 || true
    if ! timeout -k 2 5 sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then return 0; fi
    if [[ -e $SYSCTL_FILE || -L $SYSCTL_FILE ]] && ! is_managed_file "$SYSCTL_FILE"; then return 0; fi
    if ! cc=$(timeout -k 2 5 sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) \
        || ! q=$(timeout -k 2 5 sysctl -n net.core.default_qdisc 2>/dev/null) || [[ -z $cc || -z $q ]]; then
        ui_warn '无法读取原始网络参数，已跳过 BBR 设置。'
        return 0
    fi
    if [[ -e $DATA_DIR/bbr-original.json || -L $DATA_DIR/bbr-original.json ]] || is_managed_file "$SYSCTL_FILE"; then
        load_bbr_original || return 1
    fi
    if ! tx_snapshot_sysctl net.ipv4.tcp_congestion_control "$cc" \
        || ! tx_snapshot_sysctl net.core.default_qdisc "$q"; then
        ui_warn '无法保存网络参数恢复记录，已跳过 BBR 设置。'
        return 0
    fi
    if [[ ! -f $DATA_DIR/bbr-original.json ]]; then
        jq -n --arg cc "$cc" --arg q "$q" '{cc: $cc, qdisc: $q}' > "$STAGE/bbr-original.json" || return 1
        atomic_install "$STAGE/bbr-original.json" "$DATA_DIR/bbr-original.json" 600 || return 1
    fi
    atomic_write "$SYSCTL_FILE" 644 <<EOF || return 1
$MANAGED_TAG
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    if ! timeout -k 2 5 sysctl -p "$SYSCTL_FILE" >/dev/null 2>>"${STEP_LOG:-/dev/null}"; then
        ui_warn 'BBR 设置未能完全应用，已保留原始值供关闭或卸载时恢复。'
    fi
}

restore_sysctl_value() {
    local key=$1 value=$2 current
    [[ -n $value ]] || return 1
    current=$(timeout -k 2 5 sysctl -n "$key" 2>/dev/null) || return 1
    [[ $current != "$value" ]] || return 0
    [[ -z ${3:-} || $current == "$3" ]] || return 0
    timeout -k 2 5 sysctl -q -w "$key=$value" >/dev/null 2>>"${STEP_LOG:-/dev/null}" || return 1
    current=$(timeout -k 2 5 sysctl -n "$key" 2>/dev/null) || return 1
    [[ $current == "$value" ]]
}

restore_bbr_original() {
    if [[ ! -e $DATA_DIR/bbr-original.json && ! -L $DATA_DIR/bbr-original.json ]] && ! is_managed_file "$SYSCTL_FILE"; then return 0; fi
    if [[ -e $SYSCTL_FILE || -L $SYSCTL_FILE ]] && ! is_managed_file "$SYSCTL_FILE"; then
        ui_note 'BBR 配置已被替换，保留当前内核参数。'
        return 0
    fi
    local i current failed=0
    local -a keys=(net.ipv4.tcp_congestion_control net.core.default_qdisc) managed=(bbr fq) original=()
    load_bbr_original original || return 1
    # Capture both baselines before the first write. Leave later administrator changes alone.
    for i in "${!keys[@]}"; do
        current=$(timeout -k 2 5 sysctl -n "${keys[$i]}" 2>/dev/null) || { failed=1; continue; }
        if [[ $current != "${managed[$i]}" || $current == "${original[$i]}" ]]; then
            original[$i]=''
        else
            tx_snapshot_sysctl "${keys[$i]}" "$current" || failed=1
        fi
    done
    (( ! failed )) || { die '无法核实网络参数或保存恢复记录，已停止恢复 BBR。'; return 1; }
    for i in "${!keys[@]}"; do
        [[ -z ${original[$i]} ]] || restore_sysctl_value "${keys[$i]}" "${original[$i]}" "${managed[$i]}" || failed=1
    done
    (( ! failed )) || { die 'BBR 设置未能完全恢复，已保留原始记录。'; return 1; }
    rm -f -- "$DATA_DIR/bbr-original.json"
}

install_logrotate() {
    local file=$ROOT/etc/logrotate.d/zxray
    [[ -d $ROOT/etc/logrotate.d ]] || return 0
    if [[ -e $file || -L $file ]] && ! is_managed_file "$file"; then
        ui_note "保留已有的日志轮转配置：$file"
        return 0
    fi
    if ! needs_nginx; then
        if is_managed_file "$file"; then rm -f -- "$file" || return 1; fi
        return 0
    fi
    atomic_write "$file" 644 <<EOF
$MANAGED_TAG
$NGINX_DIR/error.log {
    su root root
    size 1M
    rotate 2
    missingok
    notifempty
    copytruncate
    compress
}
EOF
}


svc_label() {
    case $1 in
        xray) printf 'Xray' ;;
        zxray-ss) printf 'SS-Rust' ;;
        zxray-nginx) printf 'Nginx 前置' ;;
        *) printf '%s' "$1" ;;
    esac
}

port_service() {
    if [[ $1 == REALITY ]] && needs_nginx; then printf 'zxray-nginx'
    elif needs_ss_rust; then printf 'zxray-ss'
    else printf 'xray'; fi
}

wanted_services() {
    if needs_xray; then printf 'xray\n'; fi
    if needs_ss_rust; then printf 'zxray-ss\n'; fi
    if needs_nginx; then printf 'zxray-nginx\n'; fi
}

check_service_ownership() {
    local s file fragment rc owned
    local -a services=("${MANAGED_SERVICES[@]}")
    if (( $# )); then services=("$@"); fi
    for s in "${services[@]}"; do
        file=$SYSTEMD_DIR/$s.service
        owned=0
        if [[ -e $file || -L $file ]]; then
            is_managed_file "$file" || { die "同名服务 $s 不由本工具管理。"; return 1; }
            owned=1
        fi
        rc=0; svc_exists "$s" || rc=$?
        case $rc in
            0) ;;
            1) continue ;;
            *) die "无法查询服务 $s 的归属。"; return 1 ;;
        esac
        # A tagged file on disk may be shadowed by a transient or generated unit.
        fragment=$(timeout -k 2 5 systemctl show "$s" -p FragmentPath --value 2>>"${STEP_LOG:-/dev/null}") || {
            die "无法查询服务 $s 的生效单元文件。"; return 1;
        }
        # During recovery systemd may still hold our just-removed unit in memory.
        if [[ $fragment != "$file" || ( $owned == 0 && ( $IN_ROLLBACK != 1 || ! -f $TX/ready || -L $TX/ready ) ) ]]; then
            die "服务 $s 的生效单元不属于本工具。"; return 1
        fi
    done
}

pid_has_exited() {
    local state
    state=$(awk '/^State:/ {print $2; exit}' "/proc/$1/status" 2>/dev/null) || state=''
    # An unreadable status alone does not mean the process exited.
    [[ $state == Z || ! -d /proc/$1 ]]
}

stop_owned_services() {
    local s pid n pids rc=0 stopping_nginx_group=''
    check_service_ownership || return 1
    if [[ -f $SYSTEMD_DIR/zxray-nginx.service ]]; then stopping_nginx_group=$(nginx_unit_cgroup) || stopping_nginx_group=''; fi
    for s in "${MANAGED_SERVICES[@]}"; do svc_stop_disable "$s" "${1:-disable}" || return 1; done
    pids=$(timeout -k 2 5 pgrep -x '^(xray|ssserver|nginx(-light|-extras|-core|-full|[.]dpkg-new)?)$' 2>/dev/null) || rc=$?
    (( rc <= 1 )) || { die '无法检查遗留进程，已停止操作。'; return 1; }
    while read -r pid; do
        [[ -n $pid ]] || continue
        pid_is_owned "$pid" || continue
        kill -TERM "$pid" 2>/dev/null || true
        for n in 1 2 3 4 5 6 7 8 9 10; do
            pid_has_exited "$pid" && break
            pid_is_owned "$pid" || break
            sleep 0.2
        done
        if pid_is_owned "$pid" && ! pid_has_exited "$pid"; then
            kill -KILL "$pid" 2>/dev/null || true
            for n in 1 2 3 4 5; do
                pid_has_exited "$pid" && break
                sleep 0.2
            done
            if pid_is_owned "$pid" && ! pid_has_exited "$pid"; then
                die "托管进程 $pid 未能停止。"; return 1
            fi
        fi
    done <<< "$pids"
}

# Remove named leaves only. Administrators may have placed other files alongside them.
remove_xray_files() {
    local dir=$1 file
    shift
    if [[ -L $dir ]]; then rm -f -- "$dir"; return; fi
    [[ -d $dir ]] || return 0
    for file in "$@"; do
        if [[ -L $dir/$file || -f $dir/$file ]]; then rm -f -- "$dir/$file" || return 1; fi
    done
    if ! rmdir -- "$dir" 2>/dev/null; then
        for file in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
            if [[ -e $file || -L $file ]]; then ui_note "保留目录及其中的其他文件：$dir"; return 0; fi
        done
        die "无法移除空目录：$dir"; return 1
    fi
}

remove_private_files() {
    local dir=$1 file log s
    shift
    local -a files=() logs=()
    case $dir in
        "$SELF_DIR")
            for file in "$CORE_BIN" "$SS_BIN"; do
                if ! in_list "$file" "$@"; then files+=("${file##*/}"); fi
            done
            if has_manager_script; then files+=(zxray.sh); fi ;;
        "$DATA_DIR")
            files=(state.json state.prev.json bbr-original.json ssserver.json ssserver.acl sni-pool.txt
                   nodes.json node-info.txt subscription.txt subscription.b64 update-check.json)
            # A SIGKILL can leave the home screen update check's mktemp and its tag.
            for file in "$dir"/.update-check.*; do
                [[ -f $file && ! -L $file && -O $file && ${file##*/} =~ ^\.update-check\.[a-zA-Z0-9]{8}(\.tag)?$ ]] &&
                    files+=("${file##*/}")
            done ;;
        "$DATA_DIR/log")
            # Older Debian/Ubuntu releases precreated these files even under systemd.
            for s in "${MANAGED_SERVICES[@]}"; do logs+=("$s.log"); done ;;
        "$NGINX_DIR")
            files=(nginx.conf)
            logs=(error.log) ;;
        *) return 1 ;;
    esac
    if [[ -d $dir && ! -L $dir ]]; then
        for log in "${logs[@]}"; do
            files+=("$log" "$log.1" "$log.1.gz" "$log.2" "$log.2.gz")
            # Some distributions enable logrotate's default dateext globally.
            for file in "$dir/$log"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]{,.gz}; do
                [[ -f $file || -L $file ]] && files+=("${file##*/}")
            done
        done
    fi
    remove_xray_files "$dir" "${files[@]}"
}

remove_nginx_runtime() {
    local reuse=$1 socket=$NGINX_RUN/reject.sock rows
    if [[ ! -L $NGINX_RUN && ! -L $socket && -S $socket ]]; then
        if ! rows=$(timeout -k 2 5 ss -H -xa 2>>"${STEP_LOG:-/dev/null}") ||
            ! awk -v path="$socket" '{for (i=1; i<=NF; i++) if ($i == path) found=1} END {exit found ? 1 : 0}' <<< "$rows"; then
            if (( reuse )); then die "无法确认 Nginx 套接字已释放：$socket"; return 1; fi
            ui_note "保留可能仍在使用的 Nginx 运行目录：$NGINX_RUN"
            return 0
        fi
        rm -f -- "$socket" || return 1
    fi
    remove_xray_files "$NGINX_RUN" nginx.pid reject.sock
}

remove_old_files() {
    remove_xray_files "$CONFIG_DIR" config.json || return 1
    rm -f -- "$SS_CONFIG" "$SS_ACL" || return 1
    if needs_nginx; then
        # Configuration is installed atomically. Keep the active error log and its history.
        if [[ -L $NGINX_DIR ]]; then rm -f -- "$NGINX_DIR" || return 1; fi
        remove_nginx_runtime 1 || return 1
    else
        remove_private_files "$NGINX_DIR" && remove_nginx_runtime 0 || return 1
    fi
    remove_managed_units || return 1
    if ! needs_xray; then
        rm -f -- "$XRAY_BIN" || return 1
        remove_xray_files "$XRAY_ASSET_DIR" geoip.dat geosite.dat .zxray-full-geo || return 1
    fi
    needs_ss_rust || rm -f -- "$SS_BIN" || return 1
    return 0
}

# Return the capability flag separately from the status of reading the draft.
core_bind_cap() {
    local core=$1 result=$2 first rows proto port label guard inner field needed=0
    if ! IFS= read -r first 2>/dev/null < "$ROOT/proc/sys/net/ipv4/ip_unprivileged_port_start" ||
        [[ ! $first =~ ^[0-9]{1,5}$ ]] || (( 10#$first > 65535 )); then
        first=1024
    fi
    case $core in
        Xray)
            rows=$(public_ports) && [[ -n $rows ]] || { die '无法读取 Xray 监听端口，已停止设置端口权限。'; return 1; } ;;
        SS-Rust)
            port=$(st .ss.port) && valid_port "$port" || { die '无法读取 SS-Rust 监听端口，已停止设置端口权限。'; return 1; }
            rows="tcp $port SS-Rust" ;;
        *) return 1 ;;
    esac
    while read -r proto port label; do
        [[ ( $proto == tcp || $proto == udp ) && -n $label ]] && valid_port "$port" || {
            die "$core 的监听端口无效，已停止设置端口权限。"; return 1;
        }
        if [[ $label == REALITY ]]; then
            guard=$(st .reality.guard) || { die '无法读取 REALITY 防护方式。'; return 1; }
            case $guard in
                nginx) field=.reality.internal ;;
                xray) field=.reality.gate ;;
                *) die 'REALITY 防护方式无效。'; return 1 ;;
            esac
            inner=$(st "$field") && valid_port "$inner" || { die 'REALITY 内部端口无效。'; return 1; }
            if (( 10#$inner < 10#$first )); then needed=1; fi
            # Nginx owns the public port; Xray binds the loopback port.
            [[ $guard != nginx ]] || continue
        fi
        if (( 10#$port < 10#$first )); then needed=1; fi
    done <<< "$rows"
    printf -v "$result" '%d' "$needed"
}

install_files_and_services() {
    local low
    if needs_ss_rust; then core_bind_cap SS-Rust low || return 1
    else core_bind_cap Xray low || return 1; fi
    repair_std_dirs
    ensure_service_user || return 1
    if (( SERVICE_USER_CREATED )); then
        local uid gid
        uid=$(id -u "$SERVICE_USER") && gid=$(id -g "$SERVICE_USER") || return 1
        st_filter --arg ids "$uid:$gid" '.meta.created_user = 1 | .meta.created_user_ids = $ids' || return 1
    fi
    make_dir "$DATA_DIR" "$SELF_DIR" "$(dirname -- "$QUICK_BIN")"
    chmod 755 "$DATA_DIR" "$SELF_DIR"
    if needs_xray; then
        if [[ $USE_XRAY != "$XRAY_BIN" ]]; then install_bin "$USE_XRAY" "$XRAY_BIN"; fi
        install_xray_geodata || return 1
        make_dir "$CONFIG_DIR"
        atomic_install "$STAGE/config.json" "$CONFIG_FILE" 640
        chown "root:$SERVICE_USER" "$CONFIG_FILE"
        chmod 750 "$CONFIG_DIR"
        chown "root:$SERVICE_USER" "$CONFIG_DIR"
        write_service xray "$XRAY_BIN" "run -config $CONFIG_FILE" 'Xray' "$SERVICE_USER" "$low" "XRAY_LOCATION_ASSET=$XRAY_ASSET_DIR"
        check_service_access "$XRAY_BIN" "$CONFIG_FILE" "$XRAY_ASSET_DIR/geoip.dat" "$XRAY_ASSET_DIR/geosite.dat"
    fi
    if needs_ss_rust; then
        [[ $USE_SS == "$SS_BIN" ]] || install_bin "$USE_SS" "$SS_BIN"
        atomic_install "$STAGE/ssserver.json" "$SS_CONFIG" 640
        atomic_install "$STAGE/ssserver.acl" "$SS_ACL" 640
        chown "root:$SERVICE_USER" "$SS_CONFIG" "$SS_ACL"
        write_service zxray-ss "$SS_BIN" "-c $SS_CONFIG --acl $SS_ACL" 'Shadowsocks Rust' "$SERVICE_USER" "$low"
        check_service_access "$SS_BIN" "$SS_CONFIG" "$SS_ACL"
    fi
    if needs_nginx; then
        check_private_dirs "$NGINX_DIR" "$NGINX_RUN" || return 1
        make_dir "$NGINX_DIR" "$NGINX_RUN"
        chmod 755 "$NGINX_RUN"
        atomic_install "$STAGE/nginx.conf" "$NGINX_DIR/nginx.conf" 644
        local nginx_service_opts=''
        if (( NGINX_SUPPORTS_E )); then
            nginx_service_opts="-e $NGINX_DIR/error.log "
        fi
        test_nginx_config || return 1
        local nginx_cmd nginx_args
        nginx_cmd=$(command -v nginx)
        nginx_args="${nginx_service_opts}-c $NGINX_DIR/nginx.conf -p $NGINX_DIR/ -g 'daemon off;'"
        write_service zxray-nginx "$nginx_cmd" "$nginx_args" \
            'Xray Manager Nginx' root 0 '' "$NGINX_DIR" zxray-nginx
    fi
}

start_services() {
    local s
    svc_reload_units || { die '服务配置重载失败，已停止启动。'; return 1; }
    check_service_ownership || return 1
    while read -r s; do
        [[ -n $s ]] || continue
        if [[ ${1:-enable} != runtime-only ]]; then
            svc_do enable "$s" || { svc_fail "$s" "$(svc_label "$s") 开机自启设置失败。"; return 1; }
        fi
        svc_do start "$s" || {
            service_log_to_step "$s"; svc_fail "$s" "$(svc_label "$s") 启动失败或超时。"; return 1
        }
    done <<< "$(wanted_services)"
}

service_log_to_step() {
    local s=$1 n=15
    # Keep both sources visible in show_step_log's 15-line window.
    if [[ $s == zxray-nginx && -s $NGINX_DIR/error.log ]]; then n=8; fi
    timeout -k 2 5 journalctl -u "$s" -n "$n" --no-pager -o cat >> "$STEP_LOG" 2>&1 || true
    if [[ $s == zxray-nginx && -s $NGINX_DIR/error.log ]]; then
        tail -n 7 "$NGINX_DIR/error.log" >> "$STEP_LOG" 2>&1 || true
    fi
    if [[ $s == zxray-nginx ]] && grep -Fq 'could not open error log file: open() "/var/log/nginx/error.log" failed (13: Permission denied)' "$STEP_LOG"; then
        printf '%s\n' '旧版 Nginx 读取配置前可能先报告默认日志无法打开。请同时查看后续启动和监听错误。' >> "$STEP_LOG"
    fi
}


wait_active() {
    local s=$1 deadline=$(( SECONDS + $2 )) rc
    while (( SECONDS < deadline )); do
        rc=0; svc_active "$s" || rc=$?
        case $rc in 0) return 0 ;; 1) ;; *) return 2 ;; esac
        sleep 0.5
    done
    return 1
}

# Public sockets must belong to the expected systemd main process, or to one
# of that Nginx master's workers. Inspect every owner in a single ss snapshot.
service_owns_listeners() {
    local rows=$1 unit=$2 main=$3 row pid ppid
    local -n detail=$4
    local -a owners
    detail=''
    [[ -n $rows && $main =~ ^[1-9][0-9]*$ ]] || { detail='服务没有有效的主进程'; return 1; }
    while IFS= read -r row; do
        listener_pids "$row" owners || { detail='监听记录缺少有效的 PID'; return 1; }
        for pid in "${owners[@]}"; do
            [[ $pid != "$main" ]] || continue
            if [[ $unit == zxray-nginx && /proc/$pid/exe -ef /proc/$main/exe ]]; then
                ppid=$(awk '/^PPid:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null) || ppid=''
                [[ $ppid != "$main" ]] || continue
            fi
            detail="监听进程 PID $pid 与服务主进程 PID $main 不符"
            return 1
        done
    done <<< "$rows"
}

# Family-filtered ss output can print a wildcard as *, 0.0.0.0 or [::].
listener_has_bind() {
    local rows=$1 port=$2 family=$3 expected=$4 socket address key
    while read -r _ _ _ socket _; do
        [[ $socket == *:"$port" ]] || continue
        address=${socket%:*}
        address=${address#\[}; address=${address%\]}
        if [[ $address == '*' ]]; then
            if [[ $family == 6 ]]; then address=::; else address=0.0.0.0; fi
        fi
        key=$(ip_key "$address") && [[ $key == "$expected" ]] && return 0
    done <<< "$rows"
    return 1
}

health_check() {
    local s proto port label i owner sockets main reason rows addr ss_addr_key ss_family='' family_rows rc
    if needs_ss_rust; then
        addr=$(jq -er '.server | strings | select(length > 0)' "$SS_CONFIG") || { die '无法读取 SS-Rust 的监听地址。'; return 1; }
        if [[ $addr == *:* ]]; then ss_family=6
        elif valid_ipv4 "$addr"; then ss_family=4; fi
        if [[ -n $ss_family ]]; then
            ss_addr_key=$(ip_key "$addr") || { die 'SS-Rust 的监听地址无效。'; return 1; }
        fi
    fi
    rows=$(public_ports) && [[ -n $rows ]] || { die '无法读取配置中的对外端口。'; return 1; }
    while read -r s; do
        [[ -n $s ]] || continue
        rc=0; wait_active "$s" 10 || rc=$?
        if (( rc )); then
            service_log_to_step "$s"
            if (( rc == 2 )); then svc_fail "$s" "无法查询 $(svc_label "$s") 的运行状态。"
            else svc_fail "$s" "$(svc_label "$s") 没有启动成功。"; fi
            return 1
        fi
    done <<< "$(wanted_services)"
    while read -r proto port label; do
        [[ -n $port ]] || continue
        owner=$(port_service "$label") || return 1
        for (( i = 0; i < 20; i++ )); do
            sockets=$(listeners "$proto" "$port") || { port_query_failed; return 1; }
            if [[ -n $sockets ]]; then
                main=$(timeout -k 2 5 systemctl show "$owner" -p MainPID --value 2>>"$STEP_LOG") || {
                    svc_fail "$owner" "无法查询 $(svc_label "$owner") 的主进程。"; return 1
                }
                if service_owns_listeners "$sockets" "$owner" "$main" reason; then
                    if [[ $owner != zxray-ss || -z $ss_family ]]; then break; fi
                    family_rows=$(listeners "$proto" "$port" "$ss_family") || { port_query_failed; return 1; }
                    if listeners_only_pid "$family_rows" "$main" && listener_has_bind "$family_rows" "$port" "$ss_family" "$ss_addr_key"; then break; fi
                    reason="未检测到 SS-Rust 主进程在 IPv$ss_family 地址 $addr 上监听"
                fi
            fi
            if (( i < 19 )); then sleep 0.5; fi
        done
        if (( i == 20 )); then
            service_log_to_step "$owner"
            if [[ -z $sockets ]]; then
                svc_fail "$owner" "${proto^^} $port（$label）未检测到监听。" "请查看下方 $(svc_label "$owner") 日志。"
            else
                svc_fail "$owner" "${proto^^} $port（$label）监听异常：$reason。"
            fi
            return 1
        fi
    done <<< "$rows"
    if scheme_has_reality "$(scheme)"; then reality_check || return 1; fi
    return 0
}

# Inspect every owner in the same ss snapshot used to check the bind address.
# Return 2 if an owner exited during inspection so startup can be polled again.
check_xray_listener_owners() {
    local port=$1 rows=$2 row pid exe name reason=''
    local -a argv=() owners
    while IFS= read -r row; do
        if ! listener_pids "$row" owners; then
            reason="REALITY 内部端口 TCP $port 的监听记录缺少有效的 PID。"
            break
        fi
        for pid in "${owners[@]}"; do
            if ! exe=$(readlink "/proc/$pid/exe" 2>/dev/null); then
                pid_has_exited "$pid" && return 2
                reason="无法核实 TCP $port（REALITY 内部端口）的监听进程 PID $pid。"
                break 2
            fi
            if [[ /proc/$pid/exe -ef $XRAY_BIN ]]; then
                if ! mapfile -d '' -t argv 2>/dev/null < "/proc/$pid/cmdline"; then
                    pid_has_exited "$pid" && return 2
                    reason="无法读取 TCP $port（REALITY 内部端口）监听进程 PID $pid 的启动参数。"
                    break 2
                fi
                if managed_core_argv xray "${argv[@]}"; then continue; fi
            fi
            pid_has_exited "$pid" && return 2
            name=${exe##*/}
            [[ $name =~ ^[a-zA-Z0-9_.+-]+$ ]] || name='其他程序'
            reason="TCP $port（REALITY 内部端口）被 $name（PID $pid）占用。"
            break 2
        done
    done <<< "$rows"
    [[ -z $reason ]] && return 0
    service_log_to_step xray
    die "$reason"
    return 1
}

reality_check() {
    local rp sni internal deadline rows rc probe=$STAGE/reality-probe.log ok=0 t
    rp=$(st .reality.port)
    sni=$(st .reality.sni)
    if [[ $(st .reality.guard) == nginx ]]; then internal=$(st .reality.internal)
    else internal=$(st .reality.gate); fi
    deadline=$(( SECONDS + 10 ))
    while :; do
        rows=$(listeners tcp "$internal") || { port_query_failed; return 1; }
        if [[ -n $rows ]]; then
            rc=0; check_xray_listener_owners "$internal" "$rows" || rc=$?
            (( rc == 0 )) && break
            (( rc == 2 )) || return 1
        fi
        if (( SECONDS >= deadline )); then
            service_log_to_step xray
            svc_fail xray "等待超时：未检测到 Xray 在 127.0.0.1:$internal 稳定监听。"
            return 1
        fi
        sleep 0.5
    done
    if ! awk -v expected="127.0.0.1:$internal" '$4 != expected {exit 1}' <<< "$rows"; then
        service_log_to_step xray
        svc_fail xray "Xray 的内部端口监听了非预期地址，仅允许 127.0.0.1:$internal。"
        return 1
    fi
    if timeout -k 1 6 openssl s_client -connect "127.0.0.1:$rp" -servername invalid.example -tls1_3 -brief </dev/null > "$probe" 2>&1; then
        die 'SNI 过滤失败：测试域名 invalid.example 也完成了 TLS 握手。'
        return 1
    fi
    for t in 1 2; do
        if timeout -k 1 10 openssl s_client -connect "127.0.0.1:$rp" -servername "$sni" -tls1_3 -brief \
            -verify_hostname "$sni" -verify_return_error </dev/null > "$probe" 2>&1; then ok=1; break; fi
        sleep 1
    done
    if (( ! ok )); then
        tail -n 5 "$probe" >> "$STEP_LOG" 2>/dev/null || true
        die "通过本机 REALITY 入口连接 $sni 时，TLS 握手或证书校验失败。" '请查看下方日志。如站点不可用，可在「伪装站点」更换。'
        return 1
    fi
}


record_installed_versions() {
    local v
    if needs_xray; then
        v=$(xray_version_of "$XRAY_BIN") || { die '读取已安装的 Xray 版本失败或超时。'; return 1; }
        st_sets .installed.xray "v$v"
    else st_sets .installed.xray ''; fi
    if needs_ss_rust; then
        v=$(ss_version_of "$SS_BIN") || { die '读取已安装的 SS-Rust 版本失败或超时。'; return 1; }
        st_sets .installed.ss "v$v"
    else st_sets .installed.ss ''; fi
}

validate_network_targets() {
    local host port s landings hosts field split=0 tag shown_host shown_port first actual_key shown_key family
    # Xray's config test accepts routing rules that reference a missing outbound.
    if ! jq -e '
        [.landings[].tag] as $tags
        | (["direct", "blocked", "reality-fallback"] + $tags) as $all
        | [.users[].name] as $names
        | all($names[]; type == "string" and length > 0 and (test("[[:cntrl:]]") | not))
          and (($names | length) == ($names | unique | length))
          and all($tags[]; type == "string" and length > 0)
          and (($all | length) == ($all | unique | length))
          and all(.users[].out; . as $out | type == "string" and ($out == "direct" or ($tags | index($out)) != null))
    ' "$DRAFT" >/dev/null; then
        die '请检查用户名和落地标识是否有效且各自唯一。每个用户的出口须为直出或已有落地。'
        return 1
    fi
    s=$(scheme) || return 1
    if [[ $s != ss ]]; then
        local rc=0
        check_local_uuids '' '' || rc=$?
        case $rc in
            0) ;;
            1) die '两个 VLESS 入口使用了同一 UUID，请在「高级设置 → UUID」修改。'; return 1 ;;
            *) die 'VLESS 入口身份无效，请核对 UUID 或短字符串。'; return 1 ;;
        esac
    fi
    if scheme_has_reality "$s"; then
        host=$(st .reality.sni) || return 1
        valid_domain "$host" || { die '伪装站点的域名格式不正确。'; return 1; }
        family=$(sni_probe_family) || return 1
        safe_remote_target "$host" 443 1 "$family" || { die "伪装站点不可用：$PARSE_ERR"; return 1; }
    fi
    # Inspect the outbound Xray will dial, including old vnext/servers arrays.
    # The first endpoint is also the one shown in the editor.
    landings=$(jq -r '
        def host_ok: type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
        def port_ok: type == "number" and floor == . and . >= 1 and . <= 65535;
        def endpoint: type == "object" and (.address | host_ok) and (.port | port_ok);
        .landings[] as $l | $l.outbound as $o | $o.settings as $cfg
        | (if $o.protocol == "vless" then $cfg.vnext
           elif $o.protocol == "shadowsocks" then $cfg.servers
           else error("unknown landing protocol") end) as $legacy
        | (if $legacy == null then [$cfg]
           elif ($cfg.address != null or $cfg.port != null) then error("ambiguous landing endpoints")
           else $legacy end) as $ends
        | if (($l.tag | host_ok) and ($l.host | host_ok) and ($l.port | port_ok)
              and ($ends | type == "array" and length > 0 and all(.[]; endpoint)))
          then $ends | to_entries[] | [$l.tag, $l.host, $l.port, .key, .value.address, .value.port] | @tsv
          else error("invalid landing endpoint") end' "$DRAFT") || {
        die '落地配置缺少有效的服务器地址或端口，请核对落地链接。'; return 1;
    }
    if [[ -n $landings ]]; then
        while IFS=$'\t' read -r tag shown_host shown_port first host port; do
            if [[ $first == 0 ]]; then
                actual_key=${host,,}; shown_key=${shown_host,,}
                if [[ $actual_key != "$shown_key" ]]; then
                    actual_key=$(ip_key "$host") || actual_key=${host,,}
                    shown_key=$(ip_key "$shown_host") || shown_key=${shown_host,,}
                fi
                if [[ $shown_key != "$actual_key" || $shown_port != "$port" ]]; then
                    die "$tag 显示的地址或端口与实际出站不一致，请核对落地链接。"; return 1
                fi
            fi
            safe_remote_target "$host" "$port" || { die "$tag 的目标不可用：$PARSE_ERR"; return 1; }
        done <<< "$landings"
    fi
    # Only clients resolve the advertised name. Check literal IPs here without consulting server DNS.
    if scheme_is_split "$s"; then split=1; fi
    hosts=$(jq -er '.net | {host, v4, v6} | to_entries[]
        | if (.value == null or (.value | type == "string" and (test("[[:cntrl:]]") | not)))
          then [.key, .value // ""] | @tsv else error("invalid endpoint address") end' "$DRAFT") || {
        die '节点地址格式有误。'; return 1;
    }
    while IFS=$'\t' read -r field host; do
        if [[ -z $host ]]; then
            if [[ $field == host && $split == 0 ]] || [[ $field != host && $split == 1 ]]; then
                die '请补全节点地址。'; return 1
            fi
            continue
        fi
        case $field in
            host) valid_domain "$host" || ip_key "$host" >/dev/null ;;
            v4) valid_ipv4 "$host" ;;
            v6) valid_ipv6 "$host" ;;
        esac || { die "节点地址格式有误：$host"; return 1; }
        if unusable_endpoint_ip "$host"; then die "节点地址不可用：$host"; return 1; fi
    done <<< "$hosts"
}

apply_draft() {
    resume_draft_lock || return 1
    check_foreign_install || return 1
    check_launcher_slot || return 1
    check_service_ownership || return 1
    if [[ -n $CLI_CORE_TAG ]] && needs_ss_rust; then
        ui_note "当前使用 SS-Rust。--core-version 只指定 Xray 版本。"
    fi
    plan_cores
    STEP_NO=0
    STEP_TOTAL=4
    local dl=0
    if (( NEW_XRAY || NEW_SS || GEO_REFRESH )); then dl=1; STEP_TOTAL=$(( STEP_TOTAL + 1 )); fi
    local ng=0
    if needs_nginx; then ng=1; STEP_TOTAL=$(( STEP_TOTAL + 1 )); fi

    ui_blank
    if (( dl )); then
        ui_step '下载所需组件'
        : > "$STEP_LOG"
        download_cores
        ui_step_done
    fi

    ui_step '生成并校验配置'
    : > "$STEP_LOG"
    finalize_identity "$USE_XRAY"
    validate_network_targets
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
    ports_preflight || return 1
    ui_step_done

    : > "$STEP_LOG"
    tx_begin repair
    if (( ng )); then
        ui_step '准备 Nginx'
        : > "$STEP_LOG"
        prepare_nginx
        render_nginx "$STAGE/nginx.conf"
        ui_step_done
    fi

    ui_step '写入配置并启动服务'
    : > "$STEP_LOG"
    stop_owned_services
    remove_old_files
    install_files_and_services
    configure_bbr
    install_logrotate
    install_self
    [[ -n $(st .installed_at) ]] || st_sets .installed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    st_sets .updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    write_node_files
    fw_sync
    start_services
    ui_step_done

    ui_step '检查运行状态'
    : > "$STEP_LOG"
    health_check
    record_installed_versions
    record_created_dirs
    save_prev_state
    atomic_install "$DRAFT" "$STATE" 600
    ui_step_done

    ui_step '提交更改'
    tx_commit
    post_commit_cleanup
    ui_step_done
}

ports_preflight() {
    local proto port label internal rc rows key
    local -A seen=()
    rows=$(public_ports) && [[ -n $rows ]] || { die '无法读取配置中的对外端口。'; return 1; }
    while read -r proto port label; do
        [[ -n $port ]] || continue
        key=$proto/$port
        if [[ -n ${seen[$key]+x} ]]; then
            die "${proto^^} $port 同时分配给了 ${seen[$key]} 和 $label，请修改其中一个端口。"; return 1
        fi
        seen[$key]=$label
        rc=0; port_foreign "$proto" "$port" || rc=$?
        (( rc <= 1 )) || { port_query_failed; return 1; }
        if (( rc == 0 )); then
            die "${proto^^} $port（$label）已被 $(port_owner_label "$proto" "$port") 占用。" '请在「修改配置」里换一个端口，或先停掉占用它的程序。'
            return 1
        fi
    done <<< "$rows"
    if scheme_has_reality "$(scheme)"; then
        if [[ $(st .reality.guard) == nginx ]]; then internal=$(st .reality.internal)
        else internal=$(st .reality.gate); fi
        valid_port "$internal" || { die "REALITY 本地转发端口 $internal 无效。"; return 1; }
        internal=$((10#$internal))
        if [[ -n ${seen[tcp/$internal]+x} ]]; then
            die "REALITY 本地端口 $internal 与 ${seen[tcp/$internal]} 的 TCP 端口重复。"; return 1
        fi
        rc=0; port_foreign tcp "$internal" || rc=$?
        (( rc <= 1 )) || { port_query_failed; return 1; }
        if (( rc == 0 )); then
            die "REALITY 本地转发端口 $internal 无法使用，请重新运行以自动分配空闲端口。"
            return 1
        fi
    fi
    return 0
}

record_created_dirs() {
    (( ${#CREATED_DIRS[@]} )) || return 0
    st_filter --argjson d "$(printf '%s\n' "${CREATED_DIRS[@]}" | jq -R . | jq -cs .)" \
        '.meta.created_dirs = ((.meta.created_dirs // []) + $d | unique)'
}

write_node_files() {
    make_dir "$DATA_DIR"
    atomic_install "$STAGE/nodes.json" "$NODES_JSON" 600
    render_info "$STAGE/nodes.json" "$STAGE/info.txt"
    atomic_install "$STAGE/info.txt" "$INFO_FILE" 600
    jq -r '.[].link' "$STAGE/nodes.json" > "$STAGE/sub.txt"
    atomic_install "$STAGE/sub.txt" "$SUB_FILE" 600
    b64_oneline < "$SUB_FILE" | atomic_write "$SUB_B64" 600
    if (( SNI_POOL_STAGED )); then
        if [[ -f $STAGE/sni-pool.txt ]]; then atomic_install "$STAGE/sni-pool.txt" "$SNI_POOL_FILE" 600
        else rm -f -- "$SNI_POOL_FILE"; fi
    fi
}

post_commit_cleanup() {
    if ! needs_nginx; then release_nginx_packages || true; fi
    return 0
}

nginx_may_be_running() {
    local rc=0
    timeout -k 2 5 pgrep -x '^nginx(-light|-extras|-core|-full|[.]dpkg-new)?$' >/dev/null 2>&1 || rc=$?
    # Only the documented "no matches" result proves the packages are unused.
    (( rc != 1 ))
}

nginx_packages_in_use() (
    local state
    # An inconclusive package-use query must not mark the uninstall step failed.
    die() { return 1; }
    svc_state_line state nginx package || return 0
    case $state in
        ''|'nginx 0 disabled'|'nginx 0 static'|'nginx 0 indirect'|'nginx 0 generated'|'nginx 0 transient') nginx_may_be_running ;;
        *) return 0 ;;
    esac
)

release_nginx_packages() {
    local pk hash
    local -a pkgs=()
    pk=$(jq -c '.meta.nginx_packages // []' "$STATE" 2>/dev/null || echo '[]')
    [[ $pk != '[]' ]] || return 0
    hash=$(jq -r '.meta.nginx_hash // empty' "$STATE")
    mapfile -t pkgs < <(jq -r '.[]' <<< "$pk")
    if [[ -z $hash ]] || nginx_packages_in_use \
        || ! nginx_hash_matches "$hash" "${pkgs[@]}"; then
        ui_note '保留 Nginx 软件包：仍在使用、状态不明或配置已改动。'
        return 0
    fi
    pkg_remove_safe "${pkgs[@]}" >/dev/null 2>&1 || { ui_warn 'Nginx 软件包未能卸载，已保留安装记录。'; return 1; }
    jq -e '.meta.nginx_packages = [] | .meta.nginx_hash = ""' "$STATE" > "$STAGE/state-clean.json" || return 1
    atomic_install "$STAGE/state-clean.json" "$STATE" 600
}


release_extra_packages() {
    local p shared_nginx=1 rc=0
    local -a pkgs=() safe=()
    mapfile -t pkgs < <(jq -r '.meta.extra_packages // [] | .[]' "$1" 2>/dev/null)
    (( ${#pkgs[@]} )) || return 0
    # A stopped system Nginx may still load these modules on its next start.
    if ! have nginx; then
        svc_exists nginx || rc=$?
        if (( rc == 1 )); then shared_nginx=0; fi
    fi
    for p in "${pkgs[@]}"; do
        if (( shared_nginx )) && [[ $p == *nginx* ]]; then
            ui_note "系统 Nginx 仍需 $p，已保留。"
        else
            safe+=("$p")
        fi
    done
    (( ${#safe[@]} )) || return 0
    pkg_remove_safe "${safe[@]}" >/dev/null 2>&1 || ui_warn "保留仍被依赖或未能移除的软件包：${safe[*]}"
    return 0
}

state_ok() {
    local file=${1:-$STATE} schema=${2:-$STATE_SCHEMA}
    [[ ! -L $file && -f $file ]] || return 1
    jq -es --argjson schema "$schema" --arg schemes "${SCHEMES[*]}" '
        length == 1 and (.[0] |
            type == "object" and (.schema | tostring) == ($schema | tostring)
            and (.scheme | type) == "string"
            and (.scheme as $s | ($schemes | split(" ") | index($s)) != null)
            and (.net | type) == "object" and (.core | type) == "object"
            and (.users | type) == "array" and any(.users[]; .name == "direct" and .out == "direct")
            and (.landings | type) == "array" and (.meta | type) == "object")
    ' "$file" >/dev/null 2>&1
}

migrate_state() {
    local f tmp jitter
    for f in "$STATE" "$DATA_DIR/state.prev.json"; do
        state_ok "$f" 4 || continue
        jitter=$(limit_jitter_new) || return 1
        tmp=$(mktemp "$f.XXXXXX") || return 1
        if jq -e --argjson s "$STATE_SCHEMA" --argjson j "$jitter" '.schema = $s
            | .reality.limit_jitter = (.reality.limit_jitter // $j)' "$f" > "$tmp" \
            && [[ -s $tmp ]] && chmod 600 "$tmp" && mv -fT -- "$tmp" "$f"; then continue; fi
        rm -f -- "$tmp"
        die "迁移配置失败，已保留原文件：$f"
        return 1
    done
    return 0
}

untracked_private_dir() {
    local dir entry
    for dir in "$DATA_DIR" "$SELF_DIR"; do
        if [[ -L $dir || ( -e $dir && ! -d $dir ) ]]; then printf '%s' "$dir"; return 0; fi
        [[ -d $dir ]] || continue
        [[ -r $dir && -x $dir ]] || { printf '%s' "$dir"; return 0; }
        for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
            [[ -e $entry || -L $entry ]] || continue
            if [[ $entry == "$SELF_SCRIPT_PATH" ]] && has_manager_script; then continue; fi
            printf '%s' "$dir"
            return 0
        done
    done
    return 1
}

collect_untracked_files() {
    local -n result=$1
    local p service
    local -a candidates=("$STATE" "$CONFIG_FILE" "$CORE_BIN" "$SS_BIN" "$SS_CONFIG" "$SS_ACL"
        "$DATA_DIR/state.prev.json" "$OLD_DATA_DIR/state.json" "$NGINX_DIR")
    for service in "${MANAGED_SERVICES[@]}"; do candidates+=("$SYSTEMD_DIR/$service.service"); done
    result=()
    for p in "${candidates[@]}"; do
        if [[ -e $p || -L $p ]]; then result+=("$p"); fi
    done
}

check_foreign_install() {
    local p private script
    local -a present=() unknown=() paths=()
    state_ok && return 0
    if [[ -f $OLD_DATA_DIR/state.json ]]; then
        DIE_SHOWN=1
        ui_err '检测到旧版 Xray Manager。'
        ui_code "  $OLD_DATA_DIR/state.json"
        ui_line '请先用旧版脚本卸载，再运行本脚本：'
        if [[ -f $OLD_SELF_SCRIPT ]]; then ui_code "  bash $OLD_SELF_SCRIPT --uninstall"
        else ui_note '请运行原版本的管理脚本，并选择完整卸载。'; fi
        return 1
    fi
    collect_untracked_files paths
    if private=$(untracked_private_dir); then paths+=("$private"); fi
    for p in "$CONFIG_DIR" "$XRAY_ASSET_DIR"; do
        if [[ -e $p || -L $p ]]; then paths+=("$p"); fi
    done
    for p in "${MANAGED_SERVICES[@]}"; do
        # A Debian SysV script can predate systemd's generated unit.
        script=$ROOT/etc/init.d/$p
        if [[ -e $script || -L $script ]]; then paths+=("$script"); fi
        if svc_exists "$p"; then present+=("$p")
        elif (( $? != 1 )); then unknown+=("$p"); fi
    done
    if (( ${#paths[@]} || ${#present[@]} )); then
        ui_err '发现已有的 Xray 文件、目录或同名服务，已停止安装。'
    elif (( ${#unknown[@]} )); then
        ui_err '无法确认同名服务状态，已停止安装。'
    else
        return 0
    fi
    DIE_SHOWN=1
    for p in "${paths[@]}"; do ui_code "  $p"; done
    for p in "${present[@]}"; do
        in_list "$SYSTEMD_DIR/$p.service" "${paths[@]}" || ui_line "同名服务：$p"
    done
    for p in "${unknown[@]}"; do ui_line "无法查询服务状态：$p"; done
    if (( ${#unknown[@]} )); then ui_note '请检查服务管理器，核实服务状态后重试。'
    else ui_note '请核对上方路径和服务的归属，再处理冲突。'; fi
    return 1
}


source_script_record() {
    local p=$1 d info owner mode identity digest
    [[ $p == /* ]] || p=$PWD/$p
    [[ ! $p =~ [[:cntrl:]] && -f $p && ! -L $p ]] || return 1
    # Reject writable or linked ancestors before resolving the supplied path.
    # A root-owned file in an untrusted directory is not safe to delete later.
    d=$p
    while :; do
        [[ ! -L $d ]] || return 1
        info=$(stat -c '%u:%a' -- "$d" 2>/dev/null) || return 1
        [[ $info =~ ^([0-9]+):([0-7]{3,4})$ ]] || return 1
        owner=${BASH_REMATCH[1]} mode=${BASH_REMATCH[2]}
        (( (owner == 0 || owner == EUID) && (8#$mode & 0022) == 0 )) || return 1
        [[ $d != / ]] || break
        d=$(dirname -- "$d")
    done
    p=$(readlink -f -- "$p") || return 1
    is_managed_path "$p" && return 1
    [[ $p != "$TX" && $p != "$TX"/* && $p != "$STAGE_BASE".* ]] || return 1
    grep -Fxq 'readonly SCRIPT_MARKER="ZXRAY_MANAGER"' "$p" || return 1
    identity=$(stat -c '%d:%i' -- "$p") || return 1
    digest=$(timeout -k 2 5 sha256sum < "$p") || return 1
    digest=${digest%% *}
    [[ $identity =~ ^[0-9]+:[0-9]+$ && $digest =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ -z ${2:-} || $digest == "$2" ]] || return 1
    jq -cn --arg path "$p" --arg sha256 "$digest" --arg identity "$identity" \
        '{path:$path,sha256:$sha256,identity:$identity}'
}

record_source_script() {
    [[ -n $SOURCE_RECORD ]] || return 0
    local p current
    p=$(jq -r '.path' <<< "$SOURCE_RECORD") || return 1
    current=$(source_script_record "$p") || return 0
    [[ $current == "$SOURCE_RECORD" ]] || return 0
    st_filter --argjson source "$current" \
        '.meta.source_files = ([.meta.source_files[]? | select(.path != $source.path)] + [$source])'
}

source_records_json() {
    jq -ec '
        if type == "array" and all(.[]; type == "object"
            and (.path | type == "string" and startswith("/") and (test("[\\x00-\\x1f\\x7f]") | not))
            and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
            and (.identity | type == "string" and test("^[0-9]+:[0-9]+$")))
        then map({path,sha256,identity}) else error("invalid source records") end'
}

prepare_source_cleanup() {
    local state=${1:-} records='[]'
    SOURCE_CLEANUP_LEFT=0
    if [[ -n $state ]]; then
        records=$(jq -ce '.meta.source_files // []' "$state") || return 1
    fi
    if ! jq -n --argjson records "$records" --argjson current "${SOURCE_RECORD:-null}" \
        '$records + (if $current == null then [] else [$current] end)' \
        | source_records_json \
        | jq -c 'reduce .[] as $r ([]; [.[] | select(.path != $r.path)] + [$r])' > "$STAGE/source-cleanup.json"; then
        die '原始脚本记录异常，已停止卸载。'
        return 1
    fi
}

cleanup_source_scripts() {
    local record p current records
    SOURCE_CLEANUP_LEFT=0
    if ! records=$(source_records_json < "$STAGE/source-cleanup.json" | jq -c '.[]'); then
        SOURCE_CLEANUP_LEFT=1
        ui_warn '无法读取原始脚本清单，已跳过清理。'
        return 0
    fi
    while IFS= read -r record; do
        [[ -n $record ]] || continue
        p=$(jq -r '.path' <<< "$record") || return 1
        [[ -e $p || -L $p ]] || continue
        current=$(source_script_record "$p") || current=''
        if [[ $current != "$record" ]]; then
            SOURCE_CLEANUP_LEFT=$((SOURCE_CLEANUP_LEFT + 1))
            ui_warn "原始脚本已变化或路径不安全，已保留：$p"
        elif ! rm -f -- "$p"; then
            SOURCE_CLEANUP_LEFT=$((SOURCE_CLEANUP_LEFT + 1))
            ui_warn "原始脚本无法删除，请手动清理：$p"
        fi
    done <<< "$records"
    return 0
}

install_self() {
    local src=$SOURCE_PATH installed_v cur_v='' src_v
    check_launcher_slot || return 1
    make_dir "$SELF_DIR" "$(dirname -- "$QUICK_BIN")" || return 1
    if [[ -e $SELF_SCRIPT_PATH || -L $SELF_SCRIPT_PATH ]]; then
        cur_v=$(script_version_of "$SELF_SCRIPT_PATH") || {
            die "现有管理脚本的归属或版本无法确认，已保留：$SELF_SCRIPT_PATH"; return 1;
        }
    fi
    if [[ -n $src && $src == "$SELF_SCRIPT_PATH" ]]; then
        verify_running_script "$src" || return 1
    elif [[ -n $src ]]; then
        # Validate and publish the same private copy even if the download path changes.
        [[ -n $STAGE && -n $SOURCE_DIGEST && ! -L $src && -f $src ]] &&
            cp -- "$src" "$STAGE/manager-source.sh" || { die '无法取得当前脚本副本，请重新打开。'; return 1; }
        src=$STAGE/manager-source.sh
        verify_running_script "$src" || return 1
        src_v=$(script_version_of "$src") || { die "无法确认来源脚本的归属或版本：$src"; return 1; }
        if [[ -z $cur_v ]] || ver_ge "$src_v" "$cur_v"; then
            atomic_install "$src" "$SELF_SCRIPT_PATH" 700 || return 1
            record_source_script || return 1
        fi
    fi
    installed_v=$(script_version_of "$SELF_SCRIPT_PATH") || { die "无法核实已安装管理脚本的版本：$SELF_SCRIPT_PATH"; return 1; }
    manager_launcher_text | atomic_write "$QUICK_BIN" 755 || return 1
    sync_native_command || return 1
    st_sets .script "$installed_v"
}


prepare_new_draft() {
    local s
    s=$(scheme)
    if scheme_has_reality "$s"; then
        local d
        ui_line '正在测速并选择 REALITY 伪装站点…'
        if sni_auto_select d; then
            st_sets .reality.sni "$d"
            st_set .reality.sni_auto 1
        else
            note_add '未找到可用伪装站点，请在「伪装站点」中填写。'
        fi
    fi
    if [[ $(st .meta.selinux_note) == 1 ]]; then
        note_add 'SELinux 处于强制模式，前置防护改用 Xray 内置方式。'
    fi
}

refresh_net_in_draft() {
    local old4 old6 old6_key new6_key host host_key
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
    [[ -n $NET_V6 && $NET_V6 != "$old6" ]] || return 0
    old6_key=$(ip_key "$old6") || old6_key=''
    new6_key=$(ip_key "$NET_V6") || return 1
    if [[ $new6_key != "$old6_key" ]]; then
        st_sets .net.v6 "$NET_V6"
        host_key=$(ip_key "$host") || host_key=''
        if [[ -n $old6_key && $host_key == "$old6_key" ]]; then
            st_sets .net.host "$NET_V6"
            note_add '公网 IPv6 已变化，节点地址已更新。'
        fi
    fi
    return 0
}

carry_meta_from_state() {
    local domains
    state_ok || return 0
    domains=$(blocked_domains_json "$STATE") || { die '已安装配置中的屏蔽域名列表无效。'; return 1; }
    st_filter --slurpfile o "$STATE" --rawfile domains <(printf '%s' "$domains") '
        .egress.block_domains = ($domains | fromjson)
        | .meta = (.meta + ($o[0].meta // {}
            | {nginx_packages, nginx_hash, created_user, created_user_ids, created_dirs, fw_rules, extra_packages, source_files}
            | with_entries(select(.value != null))))
        | .name = ($o[0].name // .name)
        | .name_initialized = ($o[0].name_initialized // 0)
        | .firewall = ($o[0].firewall // .firewall)' || return 1
    normalize_node_name
}

action_install() {
    local had_old=0 installed=''
    check_launcher_slot || return 1
    check_foreign_install || return 1
    DRAFT=$STAGE/draft.json
    if state_ok; then
        had_old=1
        cp -- "$STATE" "$STAGE/editor-state.json" || return 1
        installed=$(jq -r .scheme "$STAGE/editor-state.json") || return 1
        snapshot_node_links || return 1
    fi
    snapshot_sni_pool "$SNI_POOL_FILE" "$STAGE/editor-pool.txt" || return 1
    pause_draft_lock || return 1
    ui_line '正在检测本机公网地址…'
    detect_public_ips
    edit_install_draft "$had_old" "$installed"
    apply_draft
    if [[ $MODE == modify ]]; then show_modify_result; else show_install_result; fi
}

edit_install_draft() {
    local had_old=$1 installed=$2 def=1 curidx=0 cli_first=1 s
    local STATE=$STAGE/editor-state.json SNI_POOL_FILE=$STAGE/editor-pool.txt
    if (( had_old )); then curidx=$(scheme_index "$installed"); fi
    sni_stage_begin
    if (( had_old )) && [[ -z $CLI_SCHEME || $CLI_SCHEME == "$installed" ]]; then
        cli_first=0
        MODE=modify
        load_state_draft
        PREVIEW_NOTES=()
        refresh_net_in_draft
        def=$(scheme_index "$(scheme)")
        [[ -z $CLI_CORE_TAG ]] || st_sets .core.xray "$CLI_CORE_TAG"
        preview_loop
        case $PREVIEW_RESULT in
            0) return 0 ;;
            1) exit "$RC_QUIET" ;;
        esac
    fi
    [[ -z $CLI_SCHEME ]] || def=$(scheme_index "$CLI_SCHEME")
    while :; do
        MODE=new
        if (( cli_first )) && [[ -n $CLI_SCHEME ]]; then s=$CLI_SCHEME
        else choose_scheme s "$def" "$curidx"; fi
        cli_first=0
        if [[ -z $s ]]; then
            if (( had_old )); then
                # Escape from scheme selection returns to the installed scheme's preview.
                MODE=modify
                PORT_NOTE='' SNI_BEST_MS=0
                sni_stage_begin
                load_state_draft
                PREVIEW_NOTES=()
                refresh_net_in_draft
                [[ -z $CLI_CORE_TAG ]] || st_sets .core.xray "$CLI_CORE_TAG"
                preview_loop
                case $PREVIEW_RESULT in
                    0) return 0 ;;
                    1) exit "$RC_QUIET" ;;
                    2) continue ;;
                esac
            fi
            exit "$RC_QUIET"
        fi
        sni_stage_begin
        draft_new "$s"
        if (( had_old )); then note_add '确认安装后，将替换现有方案并生成新节点。'; fi
        if scheme_is_split "$s" && [[ -z $NET_V4 || -z $NET_V6 ]]; then
            note_add "公网地址未检测完整：IPv4 ${NET_V4:-未知}，IPv6 ${NET_V6:-未知}。请在「节点地址」中补全。"
        fi
        carry_meta_from_state
        [[ -z $CLI_CORE_TAG ]] || st_sets .core.xray "$CLI_CORE_TAG"
        prepare_new_draft
        preview_loop
        if [[ $PREVIEW_RESULT == 0 ]]; then
            # The confirmation is performed inside preview_loop. No edits are lost.
            return 0
        fi
        def=$(scheme_index "$s")
    done
}

firewall_hints() {
    local kind l rc rows
    local -a ports=() missing=()
    rows=$(fw_wanted) && [[ -n $rows ]] || { ui_warn '无法读取对外端口。'; return 0; }
    mapfile -t ports <<< "$rows"
    ui_kv_words '对外端口' "${ports[@]}"
    kind=$(fw_kind)
    if [[ -n $kind ]]; then
        for l in "${ports[@]}"; do
            rc=0; fw_has "$kind" "$l" || rc=$?
            case $rc in
                0) ;;
                1) missing+=("$l") ;;
                3) ui_warn "$kind 对 $l 有拒绝或限速规则，请检查现有规则。"; return 0 ;;
                *) ui_warn "无法查询 $kind 的规则，请检查防火墙状态。"; return 0 ;;
            esac
        done
        if (( ${#missing[@]} )); then
            ui_kv '本机防火墙' "${C_YELLOW}$kind 未放行${C_RESET}" '可执行以下命令'
            for l in "${missing[@]}"; do
                if [[ $kind == ufw ]]; then ui_code "  ufw allow $l"
                else ui_code "  firewall-cmd --permanent --add-port=$l && firewall-cmd --add-port=$l"; fi
            done
        elif [[ $(jq -r '.meta.fw_rules // [] | length' "$DRAFT") != 0 ]]; then
            ui_kv '本机防火墙' "$kind 已自动放行" '卸载时撤销脚本添加的规则'
        else
            ui_kv '本机防火墙' "$kind 已放行"
        fi
    elif have iptables && grep -qE '^-P INPUT DROP|-j (DROP|REJECT)' <<< "$(iptables -S INPUT 2>/dev/null || true)"; then
        ui_kv '本机防火墙' "${C_YELLOW}iptables 有拦截规则${C_RESET}" '连不上时先检查这里'
    fi
    ui_note '如有云安全组，也需放行这些端口。'
}

show_install_result() {
    ui_blank
    ui_title '安装完成' "$(scheme_label "$(scheme)")" ok
    print_nodes
    ui_rule
    firewall_hints
    ui_rule
    ui_line "输入 ${C_KEY}zxray${C_RESET} 可打开主页。"
    ui_line '在「分享链接」中查看或复制链接。'
}

show_modify_result() {
    local changed removed l
    local -a changed_labels=()
    ui_blank
    ui_title "${1:-修改已生效}" "$(scheme_label "$(scheme)")" ok
    if [[ ! -f $STAGE/nodes-before.json ]]; then
        ui_warn '旧清单缺失或损坏。以下是重新生成的全部链接。'
        print_nodes || return 1
        ui_rule
        firewall_hints
        return
    fi
    changed=$(jq -rn --slurpfile a "$STAGE/nodes-before.json" --slurpfile b "$NODES_JSON" '
        ($a[0] | map({(.label): .link}) | add // {}) as $old
        | $b[0][] | select($old[.label] != .link) | .label')
    removed=$(jq -rn --slurpfile a "$STAGE/nodes-before.json" --slurpfile b "$NODES_JSON" '
        ([$b[0][].label]) as $now | $a[0][] | select(.label as $l | $now | index($l) | not) | .label')
    if [[ -n $removed ]]; then
        ui_warn '以下节点已移除，可从客户端删除：'
        while IFS= read -r l; do ui_line "  $l"; done <<< "$removed"
    fi
    if [[ -z $changed && -z $removed ]]; then
        ui_ok '节点链接未变。'
    elif [[ -z $changed ]]; then
        ui_ok '其余节点链接未变。'
    else
        ui_warn '请在客户端导入以下新增或变更的链接：'
        mapfile -t changed_labels <<< "$changed"
        print_nodes "${changed_labels[@]}" || return 1
    fi
    ui_rule
    firewall_hints
}


node_list_json() {
    [[ ! -L $NODES_JSON && -f $NODES_JSON ]] || return 1
    jq -ces '
        def field: type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
        if length == 1 and (.[0] | type == "array" and all(.[]; (.label | field) and (.link | field)))
        then .[0] else error("invalid node list") end' "$NODES_JSON" 2>/dev/null
}

snapshot_node_links() {
    local list
    if list=$(node_list_json); then
        printf '%s\n' "$list" > "$STAGE/nodes-before.json"
    else
        # This generated list is optional for repairs; no valid baseline means no diff.
        rm -f -- "$STAGE/nodes-before.json"
    fi
}

load_node_links() {
    local rows label link
    NODE_LABELS=() NODE_LINKS=()
    if ! rows=$(node_list_json | jq -r '.[] | .label, .link'); then
        if [[ -L $NODES_JSON || ( -e $NODES_JSON && ! -f $NODES_JSON ) ]]; then
            die "节点清单须为普通文件，请核查：$NODES_JSON"
        else
            die '链接清单缺失或损坏。请在「修改配置」中重新应用。'
        fi
        return 1
    fi
    [[ -n $rows ]] || return 0
    while IFS= read -r label && IFS= read -r link; do
        NODE_LABELS+=("$label"); NODE_LINKS+=("$link")
    done <<< "$rows"
}

print_loaded_node_links() {
    local note=$1 n=${#NODE_LINKS[@]} i label printed=0
    shift
    for (( i = 0; i < n; i++ )); do
        if (( $# )) && ! in_list "${NODE_LABELS[$i]}" "$@"; then continue; fi
        (( ! printed )) || printf '\n' >&4
        printed=1
        printf -v label '  %s%*d%s  ' "$C_KEY" "${#n}" "$(( i + 1 ))" "$C_RESET"
        if [[ -t 4 ]]; then ui_text_row "$label" "${NODE_LABELS[$i]}" "$C_BOLD"
        else printf '%s%s%s%s\n' "$label" "$C_BOLD" "${NODE_LABELS[$i]}" "$C_RESET" >&4; fi
        printf '%s\n' "${NODE_LINKS[$i]}" >&4
    done
    [[ -z $note ]] || ui_note "$note"
    return 0
}

print_nodes() {
    local note
    load_node_links || return 1
    note=$(reality_short_id_note "$STATE") || return 1
    print_loaded_node_links "$note" "$@"
}

NODE_LABELS=() NODE_LINKS=()

nd_build() {
    local i n
    ui_page '分享链接' "$node_scheme_label"
    n=${#NODE_LABELS[@]}
    KEY_W=${#n}
    for i in "${!NODE_LABELS[@]}"; do
        tui_item $(( i + 1 )) "${NODE_LABELS[$i]}"
    done
    ui_blank
    ui_kv '链接文件' "$INFO_FILE"
    ui_kv '订阅 Base64' "$SUB_B64"
    ui_kv '复现参数' "$STATE"
    ui_note 'state.json 含服务端密钥。请离线备份，重装时可按原值填写。'
    [[ -z $node_short_id_note ]] || ui_note "$node_short_id_note"
    TUI_FOOT='上下键 移动   回车 查看   c 复制   Esc 返回'
    TUI_FOOT_PLAIN="$(key_range "$n") 显示链接   回车 返回"
}

osc52_copy() {
    local b
    b=$(printf '%s' "$1" | base64 | tr -d '\r\n')
    (( ${#b} <= 100000 )) || return 1
    if [[ -n ${TMUX:-} || ${TERM:-} == tmux* ]]; then printf '\ePtmux;\e\e]52;c;%s\a\e\\' "$b" >&4
    elif [[ -n ${STY:-} ]]; then
        # Stay below even older Screen DCS limits; never emit a truncated link.
        (( ${#b} <= 500 )) || return 1
        printf '\eP\e]52;c;%s\a\e\\' "$b" >&4
    else printf '\e]52;c;%s\a' "$b" >&4; fi
}

action_nodes() {
    local sel=0 direct_output=0 has_file=0 node_scheme_label='' node_short_id_note=''
    if [[ ! -t 1 ]] || (( ASSUME_YES )); then direct_output=1; fi
    NODE_LABELS=() NODE_LINKS=()
    if [[ -f $STATE && ! -L $STATE ]]; then
        has_file=1
        load_node_links || return 1
        node_short_id_note=$(reality_short_id_note "$STATE") || return 1
        if (( ! direct_output )) && state_ok; then
            local DRAFT=$STATE
            node_scheme_label=$(scheme_label "$(scheme)") || return 1
        fi
    elif [[ -e $NODES_JSON || -L $NODES_JSON ]]; then
        die '分享链接缺少对应的安装记录，请先核查部署状态。'; return 1
    fi
    # Keep only display data while the terminal waits or a pipe is backpressured.
    release_lock || return 1
    if (( ! has_file )); then
        if (( direct_output )); then ui_line '还没有节点，请先在主页选择「安装」。'; return 0; fi
        ui_page '分享链接'
        ui_line '还没有节点，请先在主页选择「安装」。'
        ui_rule
        ui_pause
        exit "$RC_QUIET"
    fi
    if (( direct_output )); then print_loaded_node_links "$node_short_id_note"; return; fi
    if (( ${#NODE_LINKS[@]} == 0 )); then ui_note '当前没有可显示的节点链接。'; ui_pause; exit "$RC_QUIET"; fi
    while :; do
        tui_menu nd_build "$sel" c
        sel=$TUI_CUR
        case $TUI_KEY in
            c)
                if (( ! TUI )); then
                    TUI_MSG='输入编号查看完整链接'; continue
                fi
                if osc52_copy "${NODE_LINKS[$TUI_CUR]}"; then
                    TUI_MSG='已发送复制请求，需终端支持剪贴板'
                else
                    TUI_MSG='无法直接复制，请按回车查看完整链接'
                fi ;;
            ENTER) show_node_link "${NODE_LINKS[$TUI_CUR]}" "${NODE_LABELS[$TUI_CUR]}" ;;
            *) exit "$RC_QUIET" ;;
        esac
    done
}




show_node_link() {
    local link=$1 label=$2
    ui_page "$label" '完整节点链接'
    printf '%s\n' "$link" >&4
    [[ -z $node_short_id_note ]] || ui_note "$node_short_id_note"
    ui_rule
    ui_pause
}

mt_build() {
    local rollback_time
    ui_page '更新与维护'
    tui_item 1 '更新组件' '' '更新当前方案使用的组件，保留配置'
    tui_item 2 '更新规则' '' '更新 Xray 大陆拦截所用规则'
    tui_item 3 '重启服务' '' '重启后检查运行状态'
    tui_item 4 '运行状态' '' '查看服务、端口、防火墙和日志'
    tui_item 5 '候选站点' '' '管理 REALITY 伪装站点测速列表'
    if prev_state_ok && rollback_time=$(date -r "$DATA_DIR/state.prev.json" '+%m-%d %H:%M' 2>/dev/null); then
        tui_item 6 '回滚配置' '' "恢复 $rollback_time 保存的配置"
    fi
    TUI_FOOT='上下键 移动   回车 选择   Esc 返回'
}

action_maintain() {
    local sel=0
    release_lock || return 1
    while :; do
        tui_menu mt_build "$sel" ''
        sel=$TUI_CUR
        [[ $TUI_KEY == ENTER ]] || return 0
        case ${TUI_IKEYS[$TUI_CUR]} in
            1)
                run_sub action_update
                ;;
            2) run_sub action_geo_update ;;
            3) run_sub action_restart ;;
            4) run_sub action_status ;;
            5) run_sub action_sni_pool ;;
            6) run_sub action_rollback ;;
        esac
    done
}

action_rollback() {
    local prev=$DATA_DIR/state.prev.json
    require_state
    (( STATE_READY )) || return 0
    prev_state_ok || { ui_warn '没有可以回滚的配置。'; return 0; }
    MODE=modify
    DRAFT=$STAGE/draft.json
    jq --slurpfile cur "$STATE" '.meta = $cur[0].meta | .installed = $cur[0].installed
        | .installed_at = $cur[0].installed_at | .schema = $cur[0].schema
        | if (.name // "") != "" then .name_initialized = 1 else . end' "$prev" > "$DRAFT" || return 1
    normalize_draft_for_apply installed
    pv_snapshot "$STATE"
    mapfile -t PV_KEYS < <(preview_items)
    snapshot_node_links || return 1
    pause_draft_lock || return 1
    pv_confirm '回滚配置' || exit "$RC_QUIET"
    apply_draft
    show_modify_result '已回滚'
}

check_state_file() {
    [[ -e $STATE || -L $STATE ]] || return 0
    [[ ! -L $STATE && -f $STATE ]] || fatal "状态文件须为普通文件，请先核查：$STATE"
    state_ok && return 0
    local sv
    sv=$(jq -r '.schema // 0' "$STATE" 2>/dev/null || true)
    if [[ $sv =~ ^[1-9][0-9]{0,8}$ ]] && (( 10#$sv > STATE_SCHEMA )); then
        fatal "配置格式 $sv 高于脚本 v$SCRIPT_VERSION 的支持范围，请用新版脚本打开。"
    fi
    ui_err "状态文件无法识别：$STATE"
    if prev_state_ok; then
        ui_note '可用以下命令恢复上一次配置，再运行脚本：'
        ui_code "  cp $DATA_DIR/state.prev.json $STATE"
    fi
    exit 1
}

prev_state_ok() {
    state_ok "$DATA_DIR/state.prev.json"
}

save_prev_state() {
    state_ok || return 0
    local a b
    a=$(jq -S -c 'del(.installed, .installed_at, .updated_at, .script, .meta, .name_initialized)' "$STATE") || return 1
    b=$(jq -S -c 'del(.installed, .installed_at, .updated_at, .script, .meta, .name_initialized)' "$DRAFT") || return 1
    [[ $a != "$b" ]] || return 0
    atomic_install "$STATE" "$DATA_DIR/state.prev.json" 600
}

run_sub() {
    run_child "$@"
    SUB_RC=$CHILD_RC
    if (( SUB_RC == RC_QUIET )); then return 0; fi
    if (( SUB_RC == 130 || SUB_RC == 143 )); then exit "$SUB_RC"; fi
    ui_pause
    return 0
}

require_state() {
    STATE_READY=0
    if ! state_ok; then
        ui_warn '还没有安装，请先在主页选择「安装」。'
        return 0
    fi
    load_state_draft
    STATE_READY=1
}

action_update() {
    ui_blank
    ui_note '更新当前方案使用的组件，保留现有节点和配置。'
    update_cores
}

require_update_core() {
    local bin=$1 name=$2
    if [[ $bin == "$XRAY_BIN" ]]; then check_xray_asset_dir || return 1; fi
    if is_regular_executable "$bin"; then
        trusted_executable_path "$bin" >/dev/null && return 0
        die "$name 核心或父目录的属主、写权限异常：$bin" '请确认路径由 root 管理，组和其他用户不可写，再重新应用配置。'
        return 1
    fi
    if [[ ! -L $bin && -d $bin ]]; then
        die "$name 核心路径是目录：$bin。请先移走该目录，再重新应用配置。"
    else
        die "$name 核心须为可执行的普通文件，请先重新应用配置以修复核心。"
    fi
    return 1
}

load_update_draft() {
    DRAFT=$STAGE/draft.json
    cp -f -- "$STATE" "$DRAFT" || return 1
    # Updating a core must preserve the installed state without normalizing it.
    jq -e "$JQ_EGRESS_FLAG"'[.egress.cn, .egress.bt] | map(egress_flag)' "$DRAFT" >/dev/null 2>&1 ||
        { die '出口限制的开关无效，请检查 state.json 中的 egress.cn 和 egress.bt。'; return 1; }
}

action_geo_update() {
    if ! state_ok; then ui_warn '还没有安装，请先在主页选择「安装」。'; return 0; fi
    load_update_draft || return 1
    if ! needs_full_geo; then
        ui_warn '当前方案未启用 Xray 大陆拦截，无需更新完整地理规则。'
        return 0
    fi
    check_launcher_slot || return 1
    require_update_core "$XRAY_BIN" Xray || return 1
    MODE=modify
    STEP_NO=0 STEP_TOTAL=1
    ui_step '下载并校验地理规则'
    : > "$STEP_LOG"
    download_full_geodata
    USE_XRAY=$XRAY_BIN
    ui_step_done
    replace_cores '地理规则已更新，连接参数不变。'
}


nginx_binary_package() {
    local bin=$1 owner
    owner=$(timeout -k 2 15 dpkg-query -S -- "$bin") || return 1
    [[ $owner != *$'\n'* && $owner == *": $bin" ]] || return 1
    owner=${owner%": $bin"}
    [[ $owner =~ ^(nginx|nginx-(core|full|light|extras|mainline|stable))(:[a-z0-9-]+)?$ ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

nginx_main_pid() {
    local pid cmd
    pid=$(timeout -k 2 5 systemctl show zxray-nginx -p MainPID --value 2>>"${STEP_LOG:-/dev/null}") || return 2
    [[ $pid =~ ^[1-9][0-9]*$ && -L /proc/$pid/exe ]] || return 1
    cmd=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") && [[ " $cmd " == *" -c $NGINX_DIR/nginx.conf "* ]] || return 1
    printf '%s' "$pid"
}

nginx_running_current() {
    local bin=$1 pid=$2 rc=0
    [[ /proc/$pid/exe -ef $bin ]] || return 1
    # A distro security revision can replace only the loaded module or library.
    awk '$NF == "(deleted)" && $(NF-1) ~ /[.]so([.]|$)/ {stale=1} END {if (stale) exit 10}' "/proc/$pid/maps" 2>/dev/null || rc=$?
    case $rc in 0) return 0 ;; 10) return 1 ;; *) return 2 ;; esac
}

nginx_package_version() {
    timeout -k 2 15 dpkg-query -W -f='${Version}' -- "$1"
}

check_running_nginx() {
    local bin=$1 refresh=${2:-1} i master port rows reason state rc=0
    if (( refresh )); then
        master=$(nginx_main_pid) || { service_log_to_step zxray-nginx; svc_fail zxray-nginx '无法确认托管 Nginx 的主进程。'; return 1; }
        nginx_running_current "$bin" "$master" || rc=$?
        if (( rc == 2 )); then
            svc_fail zxray-nginx '无法读取 Nginx 主进程已加载的程序或模块。'; return 1
        elif (( rc )); then
            check_service_ownership zxray-nginx || return 1
            svc_do restart zxray-nginx || { service_log_to_step zxray-nginx; svc_fail zxray-nginx '更新后 Nginx 前置服务重启失败。'; return 1; }
        fi
    fi
    port=$(st .reality.port) || return 1
    for (( i=0; i<20; i++ )); do
        reason='无法确认托管 Nginx 的主进程。'
        rc=0; master=$(nginx_main_pid) || rc=$?
        if (( rc == 2 )); then break
        elif (( rc == 0 )); then
            if (( refresh )); then nginx_running_current "$bin" "$master" || rc=$?; fi
            if (( rc )); then
                reason='无法确认 Nginx 前置服务已加载更新后的程序和模块。'
                (( rc != 2 )) || break
            else
                rows=$(listeners tcp "$port") || { port_query_failed; return 1; }
                reason="Nginx 前置服务未监听 TCP $port。"
                if [[ -n $rows ]]; then
                    service_owns_listeners "$rows" zxray-nginx "$master" reason && break
                fi
            fi
        fi
        (( i == 19 )) || sleep 0.3
    done
    [[ -z $reason ]] || { service_log_to_step zxray-nginx; svc_fail zxray-nginx "$reason"; return 1; }
    svc_state_line state xray update || return 1
    if [[ $state != 'xray 1 '* ]]; then
        ui_note 'Xray 未运行，已跳过本轮 REALITY 端到端检查。'
        return 0
    fi
    reality_check
}

cleanup_nginx_test_runtime() {
    local dir_ref=$1 pid_ref=$2 state pid=$1/nginx.pid
    [[ -e $NGINX_RUN || -L $NGINX_RUN ]] || return 0
    # If systemd took over, its RuntimeDirectory now follows the real service.
    if [[ ! -L $NGINX_RUN && $NGINX_RUN -ef $dir_ref ]] &&
        state=$(timeout -k 2 5 systemctl show zxray-nginx --all -p ActiveState -p ControlPID -p Job -p MainPID 2>/dev/null | LC_ALL=C sort) &&
        [[ $state == $'ActiveState=inactive\nControlPID=0\nJob=\nMainPID=0' || $state == $'ActiveState=failed\nControlPID=0\nJob=\nMainPID=0' ]]; then
        # The open descriptors pin both inodes, including if either pathname was replaced.
        if [[ -n $pid_ref && ! -L $pid && -f $pid && ! -s $pid && $pid -ef $pid_ref ]]; then
            rm -f -- "$pid" || return 1
        fi
        if [[ ! -L $NGINX_RUN && $NGINX_RUN -ef $dir_ref ]] && rmdir -- "$NGINX_RUN" 2>/dev/null; then return 0; fi
    fi
    ui_note "运行目录已有其他内容、归属变化或服务正在使用，已保留：$NGINX_RUN"
}

test_nginx_custom_runtime() (
    local dir_fd pid_fd='' ref pid_ref='' interrupted=0
    # mkdir without -p grants cleanup ownership only to the creator.
    trap 'interrupted=1' HUP INT TERM
    if ! mkdir -m 755 -- "$NGINX_RUN"; then
        [[ ! -L $NGINX_RUN && -d $NGINX_RUN ]] || { die "无法创建 Nginx 运行目录：$NGINX_RUN"; return 1; }
        (( ! interrupted )) || return 1
        test_nginx_config
        return
    fi
    exec {dir_fd}<"$NGINX_RUN" || return 1
    ref=/proc/$BASHPID/fd/$dir_fd
    trap 'cleanup_nginx_test_runtime "$ref" "$pid_ref"' EXIT
    trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
    (( ! interrupted )) || return 1
    # nginx -t opens the PID file without writing a PID. Precreate our own inode
    # exclusively; an existing/replaced file is never ours to unlink.
    set -C
    if { exec {pid_fd}>"$ref/nginx.pid"; } 2>/dev/null; then pid_ref=/proc/$BASHPID/fd/$pid_fd; fi
    set +C
    test_nginx_config
)

test_nginx_for_update() {
    local running=$1 candidate=$STAGE/nginx-check.conf
    check_private_dirs "$NGINX_DIR" "$NGINX_RUN" || return 1
    if [[ ! -d $NGINX_RUN ]]; then
        if (( ! running )); then
            render_nginx "$candidate" || return 1
            if cmp -s -- "$candidate" "$NGINX_DIR/nginx.conf"; then
                # This exact managed template uses absolute paths. Keep nginx -t's
                # PID file and Unix socket inside the disposable action directory.
                local NGINX_RUN=$STAGE/nginx-check-run
                mkdir -p -m 700 -- "$NGINX_RUN" || return 1
                render_nginx "$candidate" && test_nginx_config "$candidate"
                return
            fi
        fi
        # Keep the original configuration path, including relative includes.
        if (( running )); then
            die "运行中的 Nginx 缺少运行目录：$NGINX_RUN"; return 1
        fi
        test_nginx_custom_runtime
        return
    fi
    test_nginx_config
}

update_nginx() {
    local bin owner installed p before after active=0 state baseline='' new_hash verified_hash
    local -a packages=() service_env=()
    ui_step '更新 Nginx 和模块'
    check_service_ownership || return 1
    bin=$(type -P nginx) && bin=$(readlink -f -- "$bin") || { die '找不到当前方案使用的 Nginx。'; return 1; }
    svc_state_line state zxray-nginx update || return 1
    [[ -n $state ]] || { die '缺少 Nginx 前置服务，请先重新应用配置。'; return 1; }
    if [[ $state == 'zxray-nginx 1 '* ]]; then active=1; fi
    if ! owner=$(nginx_binary_package "$bin" 2>>"$STEP_LOG"); then
        if (( active )); then check_running_nginx "$bin" 0 || return 1; fi
        ui_step_skip '未自动更新'
        ui_warn "无法确认 $bin 的软件包来源，请通过原安装方式更新 Nginx。"
        return 0
    fi
    installed=$(pkg_snapshot) || { die '无法核实已安装的 Nginx 软件包。'; return 1; }
    while IFS= read -r p; do
        case $p in
            "$owner"|nginx|nginx-common|nginx-core|nginx-full|nginx-light|nginx-extras|nginx-module-*|libnginx-mod-*) packages+=("$p") ;;
        esac
    done <<< "$installed"
    in_list "$owner" "${packages[@]}" || { die 'Nginx 软件包状态异常，已停止更新。'; return 1; }
    before=$(nginx_package_version "$owner") || { die '无法读取已安装的 Nginx 软件包版本。'; return 1; }
    svc_state_line state nginx update || return 1
    if [[ $state != 'nginx 1 '* ]]; then
        # The distro's default web server is separate from the managed SNI gate.
        service_env=(SYSTEMD_OFFLINE=1)
    fi
    nginx_detect && test_nginx_for_update "$active" || return 1
    if jq -e '(.meta.nginx_packages // []) | length > 0' "$DRAFT" >/dev/null; then
        baseline=$(st .meta.nginx_hash)
        nginx_hash_matches "$baseline" "${packages[@]}" || baseline=''
    fi
    {
        pkg_refresh && pkg_run env "${service_env[@]}" DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
            apt-get -o DPkg::Lock::Timeout=180 -o Dpkg::Options::=--force-confold install -y \
            --only-upgrade --no-remove --no-install-recommends "${packages[@]}"
    } >> "$STEP_LOG" 2>&1 || { die 'Nginx 软件包更新失败，请检查软件源、版本锁定和日志。'; return 1; }
    if [[ -n $baseline ]]; then
        new_hash=$(nginx_system_hash) || return 1
        if [[ $new_hash != "$baseline" ]] && nginx_stock_config "${packages[@]}"; then
            # Stock-file verification traverses the tree. Re-read the digest so a
            # concurrent configuration edit cannot become a trusted package baseline.
            verified_hash=$(nginx_system_hash) || return 1
            if [[ $verified_hash == "$new_hash" ]]; then
                # Package changes survive a later core-update failure.
                st_sets .meta.nginx_hash "$new_hash" && atomic_install "$DRAFT" "$STATE" 600 || return 1
            fi
        fi
    fi
    nginx_detect && test_nginx_for_update "$active" || return 1
    if (( active )); then check_running_nginx "$bin" || return 1; fi
    after=$(nginx_package_version "$owner") || { die '无法核实更新后的 Nginx 软件包版本。'; return 1; }
    ui_step_done
    if [[ $before == "$after" ]]; then ui_line "  Nginx $after（已按当前软件源检查）"
    else ui_line "  Nginx $before → $after"; fi
}

update_cores() {
    local -a todo=() notes=()
    local cur new tag t dir want core_bin core_name
    STATE_READY=0
    if ! state_ok; then ui_warn '还没有安装，请先在主页选择「安装」。'; return 0; fi
    check_launcher_slot || return 1
    load_update_draft || return 1
    STATE_READY=1
    if needs_ss_rust; then core_bin=$SS_BIN core_name=SS-Rust
    else core_bin=$XRAY_BIN core_name=Xray; fi
    require_update_core "$core_bin" "$core_name" || return 1
    MODE=modify
    STEP_NO=0; STEP_TOTAL=1
    : > "$STEP_LOG"
    if needs_nginx; then STEP_TOTAL=2; update_nginx || return 1; fi
    ui_step '检查核心版本'
    : > "$STEP_LOG"
    dir=$STAGE/core
    mkdir -p "$dir"
    if [[ $core_name == Xray ]]; then
        cur=$(xray_version_of "$core_bin") || {
            die '无法读取当前 Xray 版本，请重新应用配置以修复核心。'; return 1;
        }
        want=$(st .core.xray)
        case $want in
            compat|latest) latest_tag XTLS/Xray-core tag || return 1 ;;
            *)
                [[ ${cur#v} == "${want#v}" ]] || { die "当前 Xray 与固定版本 $want 不符，请重新应用配置。"; return 1; }
                tag=''; notes+=("Xray 已固定为 $want") ;;
        esac
        if [[ -n $tag && ${tag#v} != "${cur#v}" ]] && ver_ge "${tag#v}" "${cur#v}"; then
            download_xray "$tag" "$dir/xray-pkg"
            new=$(cat "$dir/xray-pkg/xray.version")
            todo+=("Xray ${cur:-未知} -> $new")
            USE_XRAY=$dir/xray-pkg/xray USE_XRAY_ASSET=$dir/xray-pkg
        fi
    else
        cur=$(ss_version_of "$core_bin") || {
            die '无法读取当前 SS-Rust 版本，请重新应用配置以修复核心。'; return 1;
        }
        want=$(st .core.ss)
        if [[ $want == latest ]]; then latest_tag shadowsocks/shadowsocks-rust new || return 1
        else
            [[ ${cur#v} == "${want#v}" ]] || { die "当前 SS-Rust 与固定版本 $want 不符，请重新应用配置。"; return 1; }
            new=''; notes+=("SS-Rust 已固定为 $want")
        fi
        if [[ -n $new ]] && ! ver_ge "$cur" "$new"; then
            download_ss "$new" "$dir/ss-pkg"
            todo+=("SS-Rust ${cur:-未知} -> $new")
            USE_SS=$dir/ss-pkg/ssserver
        fi
    fi
    if needs_full_geo; then
        if ! full_geo_fresh; then
            download_full_geodata
            todo+=("GeoIP Full / GeoSite Expanded 更新")
            [[ -n $USE_XRAY ]] || USE_XRAY=$XRAY_BIN
        elif (( ! GEO_REFRESH )); then USE_XRAY_ASSET=$XRAY_ASSET_DIR; fi
    elif [[ $core_name == Xray && -z $USE_XRAY ]] && ! installed_geodata_usable; then
        # Restore bundled assets from the same release without replacing the running binary.
        download_xray "v${cur#v}" "$dir/xray-pkg" || return 1
        USE_XRAY=$XRAY_BIN USE_XRAY_ASSET=$dir/xray-pkg
        todo+=("修复 GeoIP / GeoSite 规则文件")
    fi
    # Compat preference is only a version-selection alias and does not change live nodes.
    [[ $(st .core.xray) != compat ]] || st_sets .core.xray latest
    if (( ${#todo[@]} == 0 )); then
        record_installed_versions || return 1
        if (( ${#notes[@]} )); then ui_step_skip "${notes[0]}"; else ui_step_skip '已是最新'; fi
        : > "$STEP_LOG"
        tx_begin
        install_self
        atomic_install "$DRAFT" "$STATE" 600
        tx_commit
    else
        ui_step_done
        for t in "${todo[@]}"; do ui_line "  $t"; done
        replace_cores
    fi
    return 0
}

replace_cores() {
    local result=${1:-核心已更新，连接参数不变。} geo_only=0 deprecated_delay=0 candidate_tag
    check_launcher_slot || return 1
    verify_service_user || return 1
    if [[ $USE_XRAY == "$XRAY_BIN" && -z $USE_SS && $USE_XRAY_ASSET != "$XRAY_ASSET_DIR" ]]; then geo_only=1; fi
    STEP_NO=0 STEP_TOTAL=1
    ui_blank
    if [[ -n $USE_XRAY || -n $USE_SS ]]; then
        STEP_TOTAL=2
        if (( geo_only )); then ui_step '校验配置'; else ui_step '用新核心校验配置'; fi
        : > "$STEP_LOG"
        if [[ -n $USE_XRAY ]]; then
            if ! validate_xray_config "$CONFIG_FILE"; then
                if [[ $USE_XRAY != "$XRAY_BIN" ]]; then
                    candidate_tag=$(<"$USE_XRAY.version")
                    ui_warn "Xray $candidate_tag 校验现有配置失败，原核心和配置已保留。"
                    ui_note "脚本生成的配置：在「修改配置 → 高级设置 → 核心版本」指定 $candidate_tag，再应用修改。"
                    ui_note '手工配置请先备份，按日志调整副本。确认旧版和目标版都能使用后，替换配置并重试；仅目标版可用时，需将核心与配置一起切换。'
                fi
                return 1
            fi
            if [[ $USE_XRAY != "$XRAY_BIN" ]] && grep -Fq 'finalRules.blockDelay is deprecated' "$STEP_LOG"; then
                deprecated_delay=1
            fi
        fi
        if [[ -n $USE_SS ]]; then validate_ss_rust "$SS_CONFIG" "$SS_ACL" || return 1; fi
        ui_step_done
    fi
    if (( geo_only )); then ui_step '替换规则并重启'; else ui_step '替换核心并重启'; fi
    : > "$STEP_LOG"
    tx_begin
    stop_owned_services || return 1
    if [[ -n $USE_XRAY ]]; then
        if [[ $USE_XRAY != "$XRAY_BIN" ]]; then install_bin "$USE_XRAY" "$XRAY_BIN"; fi
        install_xray_geodata || return 1
        check_service_access "$XRAY_BIN" "$CONFIG_FILE" "$XRAY_ASSET_DIR/geoip.dat" "$XRAY_ASSET_DIR/geosite.dat" || return 1
    fi
    if [[ -n $USE_SS ]]; then
        install_bin "$USE_SS" "$SS_BIN" || return 1
        check_service_access "$SS_BIN" "$SS_CONFIG" "$SS_ACL" || return 1
    fi
    start_services
    health_check
    record_installed_versions
    install_self
    atomic_install "$DRAFT" "$STATE" 600
    tx_commit
    ui_step_done
    ui_ok "$result"
    if (( deprecated_delay )); then
        ui_warn '当前配置仍使用已弃用的 finalRules.blockDelay。'
        ui_note '脚本生成的配置可在「修改配置」中重新应用。'
        ui_note '手工配置请在副本上将相应规则中的 blockDelay 改为 delay，保留原值，用当前核心校验后部署。'
    fi
}


action_restart() {
    check_service_ownership || return 1
    require_state
    (( STATE_READY )) || return 0
    ui_blank
    STEP_NO=0 STEP_TOTAL=2
    ui_step '重启服务'
    : > "$STEP_LOG"
    verify_service_user || return 1
    stop_owned_services runtime-only || return 1
    start_services runtime-only || return 1
    ui_step_done
    ui_step '检查运行状态'
    : > "$STEP_LOG"
    health_check
    ui_step_done
    ui_ok '服务已重启，运行正常。'
}

# Read display-only socket state once per screen; ownership checks use listeners() separately.
status_listeners() {
    LC_ALL=C timeout -k 2 5 ss -H -nltu 2>/dev/null | LC_ALL=C awk '
        NF {
            if (($1 != "tcp" && $1 != "udp") || NF < 6 || $5 !~ /:[0-9]+$/) exit 1
            port=$5; sub(/^.*:/, "", port)
            if (port + 0 > 65535) exit 1
            key=$1 "/" (port + 0)
            if (!seen[key]++) print key
        }'
}

status_build() {
    local s v proto port label kind rc rows listening='' query_ok=0
    ui_page '运行状态' "$(scheme_label "$(scheme)")"
    ui_group '服务'
    while read -r s; do
        [[ -n $s ]] || continue
        rc=0; svc_active "$s" || rc=$?
        case $rc in
            0) v="${C_GREEN}运行中${C_RESET}" ;;
            1) v="${C_RED}未就绪${C_RESET}" ;;
            *) v="${C_YELLOW}查询失败${C_RESET}" ;;
        esac
        case $s in
            xray) ui_kv "$(svc_label "$s")" "$v" "$(st .installed.xray)" ;;
            zxray-ss) ui_kv "$(svc_label "$s")" "$v" "$(st .installed.ss)" ;;
            *) ui_kv "$(svc_label "$s")" "$v" ;;
        esac
    done <<< "$(wanted_services)"
    ui_blank
    ui_group '端口'
    kind=$(fw_kind)
    rows=$(public_ports) || { rows=''; ui_warn '无法读取对外端口。'; }
    if [[ -n $rows ]] && listening=$(status_listeners); then
        query_ok=1
        listening=$'\n'$listening$'\n'
    fi
    while read -r proto port label; do
        [[ -n $port ]] || continue
        if (( ! query_ok )); then v="${C_YELLOW}无法查询${C_RESET}"
        elif [[ $listening == *$'\n'"$proto/$port"$'\n'* ]]; then v="${C_GREEN}监听中${C_RESET}"
        else v="${C_RED}未监听${C_RESET}"; fi
        if [[ -n $kind ]]; then
            rc=0; fw_has "$kind" "$port/$proto" || rc=$?
            case $rc in
                0) v+="，$kind 已放行" ;;
                1) v+="，${C_YELLOW}$kind 未放行${C_RESET}" ;;
                3) v+="，${C_YELLOW}$kind 规则冲突${C_RESET}" ;;
                *) v+="，${C_YELLOW}$kind 状态未知${C_RESET}" ;;
            esac
        fi
        ui_kv "${proto^^} $port" "$v" "$label"
    done <<< "$rows"
    ui_blank
    tui_item 1 '最近日志' '' '每项服务最多 50 条'
    TUI_FOOT='回车 查看日志   Esc 返回'
    TUI_FOOT_PLAIN='1 查看日志   回车 返回'
}

LOG_SOURCES=() LOG_SERVICE='' LOG_RAW='' LOG_AUTO=1 LOG_FOLLOW=1

logs_build() {
    local s note
    LOG_SOURCES=()
    ui_page '最近日志'
    if (( TUI )); then ui_hint '最多显示 50 条。每 2 秒刷新，翻阅时暂停。'
    else ui_hint '最多显示 50 条。重新打开可刷新。'; fi
    ui_blank
    while read -r s; do
        [[ -n $s ]] || continue
        LOG_SOURCES+=("$s")
        note='服务日志'
        [[ $s != zxray-nginx ]] || note='优先查看 Nginx error.log'
        tui_item "${#LOG_SOURCES[@]}" "$(svc_label "$s")" '' "$note"
    done <<< "$(wanted_services)"
    TUI_FOOT='上下键 移动   回车 查看   Esc 返回'
}

log_fetch() {
    local s=$1
    {
        if [[ $s == zxray-nginx && -s $NGINX_DIR/error.log ]]; then
            tail -n 50 -- "$NGINX_DIR/error.log" 2>/dev/null
        else
            timeout -k 2 5 journalctl -q -u "$s" -n 50 --no-pager -o short-iso 2>/dev/null
        fi
    } | terminal_text 1024
}

log_view_read() {
    local fresh
    LOG_READ_CHANGED=0
    if fresh=$(log_fetch "$LOG_SERVICE"); then
        if (( LOG_READ_FAILED )) || [[ $fresh != "$LOG_RAW" ]]; then LOG_READ_CHANGED=1; fi
        LOG_RAW=$fresh LOG_READ_FAILED=0
    else
        (( LOG_READ_FAILED )) || LOG_READ_CHANGED=1
        LOG_READ_FAILED=1
    fi
}

log_view_measure() {
    local sz=''
    if input_is_tty; then sz=$(stty size <&"$INPUT_FD" 2>/dev/null || true); fi
    if [[ ! $sz =~ ^[0-9]+\ [0-9]+$ && -t 1 ]]; then sz="$(tput lines 2>/dev/null || true) $(tput cols 2>/dev/null || true)"; fi
    if [[ $sz =~ ^([0-9]+)\ ([0-9]+)$ ]] && (( BASH_REMATCH[1] > 0 && BASH_REMATCH[2] > 0 )); then
        UI_H=${BASH_REMATCH[1]} UI_W=${BASH_REMATCH[2]}
    fi
    (( UI_H >= 3 )) || UI_H=3
    (( UI_W >= 4 )) || UI_W=4
}

log_view_build() {
    local line wrapped piece
    UI_BUF=() TUI_HEAD=0
    if [[ -z $LOG_RAW ]]; then
        if (( LOG_READ_FAILED )); then UI_BUF=('未取得日志。'); else UI_BUF=('暂无日志。'); fi
    else
        while IFS= read -r line; do
            line=${line//$'\r'/}
            line=${line//$'\t'/    }
            strip_ansi "$line" line
            wrap_text "$line" "$UI_W" wrapped
            while IFS= read -r piece; do UI_BUF+=("$piece"); done <<< "$wrapped"
        done <<< "$LOG_RAW"
    fi
}

log_view_bottom() {
    local top=$(( ${#UI_BUF[@]} - LOG_VIEW_ROWS ))
    (( top >= 0 )) || top=0
    printf -v "$1" '%d' "$top"
}

log_view_rebuild() {
    local bottom toggle='继续'
    if (( LOG_AUTO )); then toggle='暂停'; fi
    footer_lines "Esc 返回   上下键 翻阅   a $toggle   r 刷新   PgUp/PgDn 翻页   End 最新" LOG_VIEW_FOOTER
    LOG_VIEW_ROWS=$(( UI_H - 1 - ${#LOG_VIEW_FOOTER[@]} ))
    # A window this short cannot show controls and a log row. The caller's menu can use plain mode.
    (( LOG_VIEW_ROWS > 0 )) || exit 0
    log_view_build
    log_view_bottom bottom
    if (( LOG_FOLLOW )); then TUI_TOP=$bottom
    else
        (( TUI_TOP >= TUI_HEAD )) || TUI_TOP=$TUI_HEAD
        (( TUI_TOP <= bottom )) || TUI_TOP=$bottom
    fi
}

log_view_draw() {
    local row line pos out='' status='已暂停'
    local -a frame=()
    if (( LOG_READ_FAILED )); then status='读取失败'
    elif (( LOG_AUTO )); then status='每 2 秒刷新'; fi
    fit_width " $(svc_label "$LOG_SERVICE") | 最近 50 条 | $status" "$UI_W" line end
    frame+=("$C_TITLE$line$C_RESET")
    for (( row = 0; row < LOG_VIEW_ROWS; row++ )); do
        frame+=("${UI_BUF[$(( TUI_TOP + row ))]-}")
    done
    frame+=("${LOG_VIEW_FOOTER[@]}")
    for row in "${!frame[@]}"; do
        (( ! TUI_PREV_OK )) || [[ ${frame[$row]} != "${TUI_PREV[$row]-}" ]] || continue
        printf -v pos '\e[%d;1H\e[2K' $(( row + 1 ))
        out+=$pos${frame[$row]}
    done
    TUI_PREV=("${frame[@]}") TUI_PREV_OK=1
    printf '%s' "$out" >&4
}

log_view() (
    # Isolate full-screen dimensions, buffers and signal cleanup from all menus.
    local k bottom ticks=0 step tty_state='' LOG_VIEW_ACTIVE=0 LOG_VIEW_ROWS=0
    local LOG_READ_FAILED=0 LOG_READ_CHANGED=0 empty='暂无日志。'
    local -a LOG_VIEW_FOOTER=()
    LOG_SERVICE=$1 LOG_RAW='' LOG_AUTO=1 LOG_FOLLOW=1
    log_view_read
    if (( ! TUI )); then
        if (( LOG_READ_FAILED )); then empty='无法读取日志。'; fi
        printf '\n%s - 最近 50 条日志\n%s\n' "$(svc_label "$LOG_SERVICE")" "${LOG_RAW:-$empty}" >&4
        ui_pause
        return 0
    fi
    tty_state=$(stty -g <&"$INPUT_FD" 2>/dev/null || true)
    trap 'printf "\e[0m\e[?1049l\e[?25h" >&4; [[ -z $tty_state ]] || stty "$tty_state" <&"$INPUT_FD" 2>/dev/null || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    trap 'TUI_RESIZED=1' WINCH
    LOG_VIEW_ACTIVE=1
    [[ -z $tty_state ]] || stty susp undef <&"$INPUT_FD" 2>/dev/null || true
    printf '\e[?1049h\e[H\e[2J' >&4
    log_view_measure
    TUI_TOP=0 TUI_PREV_OK=0 TUI_RESIZED=0
    log_view_rebuild
    ui_flush
    tty_echo -echo
    tui_cursor off
    while :; do
        log_view_draw
        tui_read_key k timed
        case $k in
            ESC|q|Q|LEFT) break ;;
            RESIZE) log_view_measure; TUI_PREV_OK=0; log_view_rebuild ;;
            TICK)
                ticks=$(( ticks + 1 ))
                if (( LOG_AUTO && ticks >= 2 )); then
                    ticks=0
                    log_view_read
                    if (( LOG_READ_CHANGED )); then log_view_rebuild; fi
                fi ;;
            r|R)
                log_view_read
                log_view_rebuild ;;
            a|A)
                LOG_AUTO=$(( 1 - LOG_AUTO ))
                if (( LOG_AUTO )); then
                    LOG_FOLLOW=1
                    log_view_read
                fi
                ticks=0
                log_view_rebuild ;;
            END)
                LOG_AUTO=1 LOG_FOLLOW=1 ticks=0
                log_view_read
                log_view_rebuild ;;
            UP|DOWN|PGUP|PGDN|HOME)
                if (( LOG_AUTO )); then
                    LOG_AUTO=0 LOG_FOLLOW=0
                    log_view_rebuild
                fi
                LOG_FOLLOW=0
                step=1
                [[ $k != PGUP && $k != PGDN ]] || step=$LOG_VIEW_ROWS
                (( step >= 1 )) || step=1
                log_view_bottom bottom
                case $k in
                    UP|PGUP) TUI_TOP=$(( TUI_TOP - step )) ;;
                    DOWN|PGDN) TUI_TOP=$(( TUI_TOP + step )) ;;
                    HOME) TUI_TOP=$TUI_HEAD ;;
                esac
                (( TUI_TOP >= TUI_HEAD )) || TUI_TOP=$TUI_HEAD
                (( TUI_TOP <= bottom )) || TUI_TOP=$bottom ;;
            b|B) go_home_if_b b || true ;;
        esac
    done
)

logs_menu() {
    local sel=0
    while :; do
        tui_menu logs_build "$sel" ''
        sel=$TUI_CUR
        [[ $TUI_KEY == ENTER ]] || return 0
        log_view "${LOG_SOURCES[$TUI_CUR]}"
    done
}

action_status() {
    local sel=0
    require_state
    release_lock || return 1
    (( STATE_READY )) || return 0
    while :; do
        tui_menu status_build "$sel" ''
        sel=$TUI_CUR
        [[ $TUI_KEY == ENTER ]] || exit "$RC_QUIET"
        logs_menu
    done
}

snapshot_sni_pool() {
    local src=$1 dest=$2
    if [[ -L $src || ( -e $src && ! -f $src ) ]]; then
        die "候选站点列表须为普通文件：$src"; return 1
    fi
    if [[ -f $src ]]; then cp -- "$src" "$dest"; else rm -f -- "$dest"; fi
}

sni_stage_begin() {
    SNI_POOL_STAGED=1
    rm -f -- "$STAGE/sni-pool.txt" "$STAGE/sni-pool-base.txt"
    if [[ -f $SNI_POOL_FILE ]]; then
        cp -f -- "$SNI_POOL_FILE" "$STAGE/sni-pool.txt"
        cp -f -- "$SNI_POOL_FILE" "$STAGE/sni-pool-base.txt"
    fi
}

sni_pool_changed() {
    (( SNI_POOL_STAGED )) || return 1
    local old=$STAGE/sni-pool-base.txt new=$STAGE/sni-pool.txt
    if [[ -f $old && ! -f $new || ! -f $old && -f $new ]]; then return 0; fi
    [[ ! -f $old ]] && return 1
    ! cmp -s -- "$old" "$new"
}

sni_pool_file() {
    if (( SNI_POOL_STAGED )); then printf '%s' "$STAGE/sni-pool.txt"
    else printf '%s' "$SNI_POOL_FILE"; fi
}

POOL=()

pool_build() {
    local i f=${pool_view:-$(sni_pool_file)}
    mapfile -t POOL < <(sni_pool "$f")
    if [[ -f $f ]]; then ui_page '候选站点' '自定义列表'; else ui_page '候选站点' '默认列表'; fi
    ui_hint $'自动测速并选择可用站点，最多同时检测 12 个。'
    if (( SNI_POOL_STAGED )); then ui_note '应用配置时保存列表。'
    else ui_note '列表修改立即保存。'; fi
    ui_blank
    KEY_W=${#POOL[@]}
    KEY_W=${#KEY_W}
    for i in "${!POOL[@]}"; do tui_item $(( i + 1 )) "${POOL[$i]}" '' '' '回车后确认删除此站点。'; done
    ui_blank
    tui_item a '添加站点' '' '' '输入支持 TLS 1.3 和 HTTP/2 的站点域名。'
    if [[ -f $f ]]; then tui_item r '恢复默认' '' '' '删除自定义列表，恢复默认站点。'; fi
    TUI_HELP_H=1
    TUI_FOOT='上下键 移动   回车 选择   Esc 返回'
    if [[ -f $f ]]; then TUI_FOOT_PLAIN='编号 删除   a 添加   r 恢复默认   回车 返回'
    else TUI_FOOT_PLAIN='编号 删除   a 添加   回车 返回'; fi
}

edit_sni_pool() {
    local d key f pool_view sel=0
    local -a rest=()
    f=$(sni_pool_file)
    pool_view=$f
    if (( ! SNI_POOL_STAGED )); then pool_view=$STAGE/editor-pool.txt; fi
    while :; do
        if (( ! SNI_POOL_STAGED )) && [[ -z $DRAFT_GENERATION ]]; then
            snapshot_sni_pool "$f" "$pool_view" || return 1
            pause_draft_lock || return 1
        fi
        tui_menu pool_build "$sel" ''
        sel=$TUI_CUR
        [[ $TUI_KEY == ENTER ]] || return 0
        key=${TUI_IKEYS[$TUI_CUR]}
        case $key in
            a)
                if (( ${#POOL[@]} >= 64 )); then TUI_MSG='列表已满（64 个站点），请先删除一项。'; continue; fi
                input_page '添加站点' '' '只填域名，例如 www.example.com。'
                read_line '域名（回车取消）：' d || continue
                [[ -n $d ]] || continue
                d=${d,,}
                if ! valid_domain "$d"; then TUI_MSG='格式不对：只填域名，例如 www.example.com。'; continue; fi
                if in_list "$d" "${POOL[@]}"; then
                    TUI_MSG='该站点已经在列表里了。'
                    continue
                fi
                if (( ! SNI_POOL_STAGED )); then resume_draft_lock || return 1; fi
                printf '%s\n' "${POOL[@]}" "$d" | atomic_write "$f" 600 || return 1 ;;
            r)
                ask_no '删除自定义列表，恢复默认' || continue
                if (( ! SNI_POOL_STAGED )); then resume_draft_lock || return 1; fi
                rm -f -- "$f" || return 1 ;;
            *)
                if (( ${#POOL[@]} == 1 )); then TUI_MSG='列表里至少要留一个站点。'; continue; fi
                ask_no "从列表里删除 ${POOL[$((key - 1))]}" || continue
                if (( ! SNI_POOL_STAGED )); then resume_draft_lock || return 1; fi
                rest=("${POOL[@]}")
                unset "rest[$(( key - 1 ))]"
                printf '%s\n' "${rest[@]}" | atomic_write "$f" 600 || return 1
                sel=0 ;;
        esac
    done
}

action_sni_pool() {
    require_state
    (( STATE_READY )) || return 0
    edit_sni_pool
    exit "$RC_QUIET"
}


release_uninstall_packages() {
    local old=$1 pk hash
    local -a pkgs=()
    pk=$(jq -c '.meta.nginx_packages // []' "$old" 2>/dev/null || printf '[]')
    if [[ $pk != '[]' ]]; then
        hash=$(jq -r '.meta.nginx_hash // empty' "$old" 2>/dev/null || true)
        mapfile -t pkgs < <(jq -r '.[]' <<< "$pk")
        if [[ -z $hash ]] || nginx_packages_in_use \
            || ! nginx_hash_matches "$hash" "${pkgs[@]}"; then
            ui_note '保留 Nginx 软件包：仍在使用、状态不明或配置已改动。'
        else
            pkg_remove_safe "${pkgs[@]}" >/dev/null 2>&1 || ui_warn 'Nginx 软件包未能移除，可手动检查。'
        fi
    fi
    release_extra_packages "$old" || true
    return 0
}

remove_managed_units() {
    local s file link
    for s in "${MANAGED_SERVICES[@]}"; do
        file=$SYSTEMD_DIR/$s.service
        is_managed_file "$file" || continue
        link=$SYSTEMD_DIR/multi-user.target.wants/$s.service
        if [[ -L $link && $link -ef $file ]]; then rm -f -- "$link" || return 1; fi
        rm -f -- "$file" || return 1
    done
}

uninstall_has_untracked_files() {
    local -a paths=()
    collect_untracked_files paths
    (( ${#paths[@]} ))
}

uninstall_preflight() {
    local d
    [[ ! -e $STATE && ! -L $STATE && ! -e $TX && ! -L $TX ]] || return 0
    if uninstall_has_untracked_files; then
        TUI_MSG='缺少安装记录，请先核查残留文件。'
        TOP_RC=1
    elif has_manager_script || is_manager_launcher "$QUICK_BIN" || is_manager_launcher "$PUBLIC_XRAY" || is_core_link; then
        return 0
    elif [[ -e $DATA_DIR || -L $DATA_DIR || -e $SELF_DIR || -L $SELF_DIR ||
            -e $CONFIG_DIR || -L $CONFIG_DIR || -e $XRAY_ASSET_DIR || -L $XRAY_ASSET_DIR ]]; then
        TUI_MSG='缺少安装记录，请先核查残留文件。'
        TOP_RC=1
    else
        # Enter the normal locked cleanup path for interrupted pre-install work.
        for d in "$STAGE_BASE".*; do is_stale_stage "$d" && return 0; done
        TUI_MSG='尚未安装，无需卸载。下载的脚本可直接删除。'
        TOP_RC=0
    fi
    if [[ $ACTION == uninstall ]]; then
        if (( TOP_RC )); then
            ui_warn "$TUI_MSG"
            ui_note '请用原安装方式卸载，或先恢复状态文件。'
            ui_code "  $STATE"
        else
            ui_line "$TUI_MSG"
        fi
    fi
    return 1
}

action_uninstall() {
    local own_user=0 user_ids='' p source_count node_count
    local -a progs=() retained=()
    local exe pid
    ui_page '卸载'
    clean_stale_stages || return 1
    if ! state_ok; then
        if uninstall_has_untracked_files; then
            ui_warn '发现残留文件，安装记录缺失、损坏或版本不兼容。'
            ui_note '卸载已停止。请用原版本脚本卸载，或先恢复状态文件：'
            ui_code "  $STATE"
            return 1
        fi
        ui_line '没有检测到本脚本部署的服务。'
        prepare_source_cleanup '' || return 1
        source_count=$(jq 'length' "$STAGE/source-cleanup.json")
        if has_manager_script || is_manager_launcher "$QUICK_BIN" || is_manager_launcher "$PUBLIC_XRAY" || is_core_link || (( source_count > 0 )); then
            ui_rule
            pause_draft_lock || return 1
            if ask_no '删除管理脚本、zxray 命令及已确认的原始脚本'; then
                resume_draft_lock || return 1
                remove_self_files
                cleanup_source_scripts
                if (( SOURCE_CLEANUP_LEFT )); then ui_warn '管理脚本已删除；部分原始文件保留，见上方路径。'
                else ui_ok '管理脚本及已确认的原始文件已删除。'; fi
                exit 20
            fi
            exit "$RC_QUIET"
        fi
        return 0
    fi
    DRAFT=$STATE
    prepare_source_cleanup "$STATE" || return 1
    source_count=$(jq 'length' "$STAGE/source-cleanup.json")
    ui_hint '将删除托管服务和配置，并撤销脚本管理的系统改动。'
    ui_blank
    if node_count=$(node_list_json | jq -r 'length'); then node_count+=' 条'
    else node_count='清单不可用'; fi
    ui_kv '节点' "$node_count" '删除本机保存的链接和配置'
    while read -r p; do [[ -z $p ]] || progs+=("$(svc_label "$p")"); done <<< "$(wanted_services)"
    ui_kv '服务' "$(join_by '、' "${progs[@]}")"
    ui_kv '系统改动' "$(uninstall_changes)"
    ui_kv '托管脚本' 'zxray 命令和托管安装文件'
    if (( source_count > 0 )); then
        ui_kv '原始脚本' "$source_count 个" '校验通过后一并删除'
        ui_note '校验不符或路径不安全的原始文件保留。'
    else
        ui_note '无可确认的原始脚本记录，旧下载文件需手动清理。'
    fi
    ui_rule
    pause_draft_lock || return 1
    ask_no '确定完整卸载' || exit "$RC_QUIET"
    resume_draft_lock || return 1
    if [[ $(jq -r '.meta.created_user // 0' "$STATE" 2>/dev/null) == 1 ]]; then
        own_user=1
        user_ids=$(jq -r '.meta.created_user_ids // empty' "$STATE") || return 1
    fi
    cp -f -- "$STATE" "$STAGE/state-old.json"
    STEP_NO=0 STEP_TOTAL=3
    ui_blank
    ui_step '保存快照并停止服务'
    : > "$STEP_LOG"
    tx_begin repair
    stop_owned_services
    # Other local services may use these binaries with entirely separate configs.
    for p in "$XRAY_BIN" "$SS_BIN"; do
        [[ -f $p && ! -L $p ]] || continue
        for exe in /proc/[0-9]*/exe; do
            [[ $exe -ef $p ]] || continue
            retained+=("$p")
            pid=${exe#/proc/}
            ui_note "保留进程 ${pid%/exe} 正在使用的核心：$p"
            if [[ $p == "$CORE_BIN" ]] && is_core_link; then retained+=("$PUBLIC_XRAY"); fi
            break
        done
    done
    ui_step_done

    ui_step '撤销规则与清除托管文件'
    : > "$STEP_LOG"
    fw_remove_recorded "$STATE"
    restore_bbr_original
    if is_managed_file "$SYSCTL_FILE"; then rm -f -- "$SYSCTL_FILE"; fi
    remove_managed_units
    for p in "${MANAGED_PATHS[@]}"; do
        in_list "$p" "${retained[@]}" && continue
        case $p in
            "$SYSTEMD_DIR/"*|"$SELF_DIR"|"$QUICK_BIN") continue ;;
            "$DATA_DIR")
                remove_private_files "$NGINX_DIR" || return 1
                remove_private_files "$DATA_DIR/log" || return 1
                remove_private_files "$DATA_DIR" || return 1
                continue ;;
            "$CONFIG_DIR") remove_xray_files "$p" config.json || return 1; continue ;;
            "$XRAY_ASSET_DIR")
                if in_list "$XRAY_BIN" "${retained[@]}"; then
                    if [[ ! -L $p && ( -f $p/.zxray-full-geo || -L $p/.zxray-full-geo ) ]]; then
                        rm -f -- "$p/.zxray-full-geo" || return 1
                    fi
                    if [[ -d $p || -L $p ]]; then ui_note "保留其他 Xray 进程可能使用的地理规则：$p"; fi
                else
                    remove_xray_files "$p" geoip.dat geosite.dat .zxray-full-geo || return 1
                fi
                continue ;;
            "$SYSCTL_FILE"|"$ROOT/etc/logrotate.d/zxray") is_managed_file "$p" || continue ;;
        esac
        if foreign_command_at "$p"; then continue; fi
        rm -f -- "$p" || return 1
    done
    remove_nginx_runtime 0 || return 1
    svc_reload_units
    for p in "${MANAGED_SERVICES[@]}"; do timeout -k 2 5 systemctl reset-failed "$p" >/dev/null 2>&1 || true; done
    ui_step_done

    ui_step '提交卸载并清理依赖'
    : > "$STEP_LOG"
    # Keep zxray usable through firewall, file and systemd cleanup. Remove the
    # managed entry points as the last rollbackable writes before commit.
    remove_private_files "$SELF_DIR" "${retained[@]}" || return 1
    if is_manager_launcher "$QUICK_BIN"; then rm -f -- "$QUICK_BIN" || return 1; fi
    tx_commit || return 1
    release_uninstall_packages "$STAGE/state-old.json"
    if (( own_user )); then
        remove_service_user "$user_ids" || ui_warn "运行账户或用户组 $SERVICE_USER 的归属已变化，或清理失败，请手动核查。"
    fi
    jq -r '.meta.created_dirs // [] | .[]' "$STAGE/state-old.json" 2>/dev/null | remove_created_dirs
    ui_step_done
    cleanup_source_scripts
    if (( SOURCE_CLEANUP_LEFT )); then ui_warn '卸载完成；部分原始脚本保留，见上方路径。'
    elif (( ${#retained[@]} )); then ui_ok '卸载完成，其他进程使用的核心及相关文件已保留。'
    else ui_ok '卸载完成，托管文件及已确认的原始脚本已清理。'; fi
    ui_note 'curl、jq 等通用工具保留。'
    exit 20
}

uninstall_changes() {
    local -a o=()
    if is_managed_file "$SYSCTL_FILE" || [[ -e $DATA_DIR/bbr-original.json || -L $DATA_DIR/bbr-original.json ]]; then o+=('BBR 设置'); fi
    if [[ $(jq -r '.meta.fw_rules // [] | length' "$STATE") != 0 ]]; then o+=('防火墙规则'); fi
    if [[ $(jq -r '(.meta.nginx_packages // []) + (.meta.extra_packages // []) | length' "$STATE") != 0 ]]; then o+=('安装的软件包'); fi
    if [[ $(jq -r '.meta.created_user // 0' "$STATE") == 1 ]]; then o+=("用户 $SERVICE_USER"); fi
    (( ${#o[@]} )) || o=('无')
    join_by '、' "${o[@]}"
}

has_manager_script() {
    local file=${1:-$SELF_SCRIPT_PATH}
    [[ ( $file != "$SELF_SCRIPT_PATH" || ! -L $SELF_DIR ) && ! -L $file && -f $file ]] &&
        grep -Fxq 'readonly SCRIPT_MARKER="ZXRAY_MANAGER"' "$file"
}

remove_self_files() {
    # Without installation state, only the recognized script and launchers are owned.
    if has_manager_script; then rm -f -- "$SELF_SCRIPT_PATH" || return 1; fi
    if is_manager_launcher "$QUICK_BIN"; then rm -f -- "$QUICK_BIN" || return 1; fi
    if is_core_link || is_manager_launcher "$PUBLIC_XRAY"; then rm -f -- "$PUBLIC_XRAY" || return 1; fi
    rmdir -- "$SELF_DIR" "$DATA_DIR" 2>/dev/null || true
    # Keep the /run lock inode until process exit/reboot: unlinking it breaks flock exclusion.
    return 0
}


action_install_cli() {
    check_launcher_slot || return 1
    check_foreign_install || return 1
    if state_ok && (( ! FORCE )); then
        die '本机已经安装过，重新安装会让现有节点失效。' '确定要重新安装，请改用 --force。'
        return 1
    fi
    detect_public_ips
    DRAFT=$STAGE/draft.json
    MODE=new
    local s=${CLI_SCHEME:-reality-raw}
    if scheme_is_split "$s" && [[ -z $NET_V4 || -z $NET_V6 ]]; then die '上下行分离需要本机同时有公网 IPv4 和 IPv6。'; return 1; fi
    draft_new "$s"
    carry_meta_from_state
    [[ -z $CLI_CORE_TAG ]] || st_sets .core.xray "$CLI_CORE_TAG"
    prepare_new_draft
    if scheme_has_reality "$s" && [[ -z $(st .reality.sni) ]]; then die '候选列表里没有可用的伪装站点。'; return 1; fi
    [[ -n $(st .net.host) ]] || { die '检测不到本机公网地址。'; return 1; }
    apply_draft
    show_install_result
}

system_running() {
    local s services=$1
    [[ -n $services ]] || return 2
    while read -r s; do
        [[ -n $s ]] || continue
        svc_active "$s" || return $?
    done <<< "$services"
    return 0
}

home_alerts() {
    local running=$1 port_rows=$2 cur=$3 proto port rest f kind='' xv rc listeners missing=0 first=''
    local -a a=()
    if [[ -z $port_rows ]]; then
        a+=('无法读取方案端口')
    elif (( running == 2 )); then
        a+=('请检查 systemd 是否可用')
    elif (( ! running )); then
        a+=('请到「更新与维护 → 运行状态」查看日志')
    elif listeners=$(status_listeners); then
        listeners=$'\n'$listeners$'\n'
        while read -r proto port rest; do
            [[ $proto == tcp || $proto == udp ]] && valid_port "$port" || continue
            if [[ $listeners != *$'\n'"$proto/$port"$'\n'* ]]; then
                (( missing += 1 ))
                [[ -n $first ]] || first="${proto^^} $port"
            fi
        done <<< "$port_rows"
        case $missing in
            0) ;;
            1) a+=("$first 未监听") ;;
            *) a+=("$missing 项监听缺失，见「运行状态」") ;;
        esac
    else
        a+=('无法查询监听端口，请检查 ss 命令')
    fi
    if [[ -n $port_rows && $(st '.firewall // "auto"') == auto ]]; then kind=$(fw_kind); fi
    if [[ -n $kind ]]; then
        local -A checked=()
        while read -r proto port rest; do
            [[ $proto == tcp || $proto == udp ]] && valid_port "$port" || continue
            f=$port/$proto
            [[ -z ${checked[$f]:-} ]] || continue
            checked[$f]=1
            rc=0; fw_has "$kind" "$f" || rc=$?
            case $rc in
                0) ;;
                1) a+=("$kind 未放行 $f"); break ;;
                3) a+=("$kind 对 $f 有冲突规则"); break ;;
                *) a+=("无法查询 $kind 规则"); break ;;
            esac
        done <<< "$port_rows"
    fi
    f=$DATA_DIR/update-check.json
    if [[ -n $cur && -f $f && ! -L $f && $(st .core.xray) == latest ]] \
        && xv=$(jq -er '.xray | strings | select(test("[[:cntrl:]]") | not)' "$f" 2>/dev/null) && (( ${#xv} <= 32 )) && valid_xray_version "${xv#v}" \
        && ! ver_ge "$cur" "$xv"; then
        a+=("Xray $xv 可更新")
    fi
    for f in "${a[@]}"; do ui_kv '' "$C_YELLOW! $f$C_RESET"; done
}

core_process_metrics() {
    local unit=$1 bin=$2 pid fd proc up='' mem=''
    [[ -e $bin ]] || return 1
    pid=$(timeout -k 2 5 systemctl show "$unit" -p MainPID --value 2>/dev/null) || return 1
    [[ $pid =~ ^[1-9][0-9]*$ ]] && { exec {fd}<"/proc/$pid"; } 2>/dev/null || return 1
    proc=/proc/$BASHPID/fd/$fd
    # Pin the process directory: a recycled numeric PID must not supply another process's metrics.
    if [[ $proc/exe -ef $bin ]] && pid_is_owned "$pid" && [[ $proc -ef /proc/$pid ]]; then
        up=$(proc_uptime "$proc") || up=''
        mem=$(proc_rss_mb "$proc") || mem=''
        exec {fd}<&-
        printf '%s:%s' "$up" "$mem"
    else
        exec {fd}<&-
        return 1
    fi
}

proc_uptime() {
    local st up hz
    local -a fs=()
    read -r st 2>/dev/null < "$1/stat" || return 1
    st=${st##*) }
    read -r -a fs <<< "$st"
    [[ ${fs[19]:-} =~ ^[0-9]+$ ]] || return 1
    hz=$(getconf CLK_TCK 2>/dev/null || true)
    [[ $hz =~ ^[0-9]+$ ]] && (( hz > 0 )) || hz=100
    read -r up _ 2>/dev/null < /proc/uptime || return 1
    up=${up%%.*}
    printf '%d' $(( up - fs[19] / hz < 0 ? 0 : up - fs[19] / hz ))
}

human_uptime() {
    local t=$1 d h m
    d=$(( t / 86400 )) h=$(( t % 86400 / 3600 )) m=$(( t % 3600 / 60 ))
    if (( d > 0 )); then printf '%d 天 %d 小时' "$d" "$h"
    elif (( h > 0 )); then printf '%d 小时 %d 分钟' "$h" "$m"
    else printf '%d 分钟' "$m"; fi
}

proc_rss_mb() {
    local k v u
    while read -r k v u; do
        if [[ $k == VmRSS: && $v =~ ^[0-9]+$ ]]; then printf '%d' $(( (v + 512) / 1024 )); return 0; fi
    done 2>/dev/null < "$1/status"
    return 1
}

tcp_conn_count() {
    local ports
    [[ -n $1 ]] || return 1
    ports=$(awk '$1 == "tcp" {printf " %s", $2}' <<< "$1") || return 1
    [[ -n $ports ]] || { printf '0'; return 0; }
    timeout -k 1 3 ss -Htn state established 2>/dev/null | awk -v ps="$ports " '{n = split($3, a, ":"); if (index(ps, " " a[n] " ")) c++} END {print c + 0}'
}

# A version probe executes the file. Check both the search path and the final
# executable, including their ancestors, before probing a system installation.
private_staff_gid() {
    local PATH=/usr/sbin:/usr/bin:/sbin:/bin record name pass gid members accounts groups
    # An explicit group grant or a primary GID can make a local prefix replaceable.
    # Remote NSS may answer individual lookups without enumerating all members.
    # compat is locally enumerable only when neither local database delegates to NIS.
    LC_ALL=C awk '
        {sub(/#.*/, "")}
        $1 ~ /^(passwd|group|initgroups):$/ {
            seen[$1]=1
            for (i=2; i<=NF; i++) if ($i !~ /^(files|systemd|compat)$/) bad=1
        }
        END {exit (bad || !seen["passwd:"] || !seen["group:"])}
    ' "$ROOT/etc/nsswitch.conf" || return 1
    LC_ALL=C awk '/^[+-]/ {found=1} END {exit found}' "$ROOT/etc/passwd" "$ROOT/etc/group" || return 1
    record=$(timeout -k 1 4 getent group staff) || return 1
    [[ $record != *$'\n'* ]] || return 1
    IFS=: read -r name pass gid members <<< "$record"
    [[ $name == staff && $gid =~ ^[1-9][0-9]*$ && ( -z $members || $members == root ) ]] || return 1
    accounts=$(timeout -k 1 4 getent passwd) && [[ -n $accounts ]] || return 1
    groups=$(timeout -k 1 4 getent group) && [[ -n $groups ]] || return 1
    LC_ALL=C awk -F: -v gid="$gid" '$4 == gid && $3 != 0 {bad=1} END {exit bad}' <<< "$accounts" || return 1
    LC_ALL=C awk -F: -v gid="$gid" '$3 == gid && $4 != "" && $4 != "root" {bad=1} END {exit bad}' <<< "$groups" || return 1
    printf '%s' "$gid"
}

trusted_path_entries() {
    local purpose=$1 PATH=/usr/sbin:/usr/bin:/sbin:/bin item meta owner gid mode perms index=0 staff_gid=''
    shift
    local -a paths=("$@")
    meta=$(stat -Lc '%u:%g:%a' -- "${paths[@]}" 2>/dev/null) || return 1
    while IFS=: read -r owner gid mode; do
        item=${paths[index++]}
        [[ $owner == 0 || $owner == "$EUID" ]] && [[ $mode =~ ^[0-7]{1,4}$ ]] || return 1
        (( (8#$mode & 0022) != 0 )) || continue
        case $item in
            "$ROOT/usr/local"|"$ROOT/usr/local/bin"|"$ROOT/usr/local/lib"|"$ROOT/usr/local/share") ;;
            "$ROOT/usr/local/etc") [[ $purpose == managed ]] || return 1 ;;
            *) return 1 ;;
        esac
        [[ $owner == 0 && $mode == 2775 && -d $item && ! -L $item ]] || return 1
        [[ $(readlink -f -- "$item") == "$item" ]] || return 1
        if [[ -z $staff_gid ]]; then staff_gid=$(private_staff_gid) || return 1; fi
        [[ $gid == "$staff_gid" ]] || return 1
        # GNU ls marks an extended ACL with '+', an unknown access method with '?'.
        perms=$(LC_ALL=C ls -ldn --color=never -- "$item" 2>/dev/null) || return 1
        case ${perms%% *} in drwxrwsr-x|drwxrwsr-x.) ;; *) return 1 ;; esac
    done <<< "$meta"
    (( index == ${#paths[@]} ))
}

trusted_executable_path() {
    local path=$1 real item PATH=/usr/sbin:/usr/bin:/sbin:/bin
    local -a entries=()
    [[ $path == /* && $path != *[[:cntrl:]]* && -f $path && -x $path ]] || return 1
    real=$(readlink -f -- "$path") || return 1
    [[ $real == /* && $real != *[[:cntrl:]]* ]] || return 1
    [[ -z $ROOT || ( $path == "$ROOT"/* && $real == "$ROOT"/* ) ]] || return 1
    for item in "$path" "$real"; do
        while [[ $item != / && $item != "$ROOT" ]]; do
            entries+=("$item")
            item=${item%/*}; item=${item:-/}
        done
        [[ $real != "$path" ]] || break
    done
    entries+=("${ROOT:-/}")
    trusted_path_entries executable "${entries[@]}" || return 1
    printf '%s' "$real"
}

home_component_version() {
    local cmd=$1 managed=$2 slot='' bin real magic ver out search
    local -a paths=()
    local -A tried=()
    case $cmd in xray) slot=$XRAY_BIN ;; ssserver) slot=$SS_BIN ;; esac
    if [[ -n $slot && ( -e $slot || -L $slot ) ]]; then
        [[ ! -L $slot ]] || return 1
        paths=("$slot")
    else
        # A system copy must not stand in for the active, missing managed core.
        [[ $cmd != "$managed" ]] || return 1
        search="$ROOT/usr/local/sbin:$ROOT/usr/local/bin:$ROOT/usr/sbin:$ROOT/usr/bin:$ROOT/sbin:$ROOT/bin"
        [[ $cmd != nginx ]] || search+=":$ROOT/usr/local/nginx/sbin"
        [[ -n $ROOT ]] || search+="${PATH:+:$PATH}"
        mapfile -t paths < <(PATH="$search" type -aP "$cmd" 2>/dev/null)
    fi
    for bin in "${paths[@]}"; do
        real=$(trusted_executable_path "$bin") || continue
        [[ -z ${tried[$real]:-} ]] || continue
        tried[$real]=1
        # Linux cores and Nginx are native binaries. Skip script aliases (including manager launchers).
        LC_ALL=C IFS= read -r -d '' -n 4 magic 2>/dev/null < "$real" || continue
        [[ $magic == $'\177ELF' ]] || continue
        case $cmd in
            xray) ver=$(xray_version_of "$real") || continue ;;
            ssserver) ver=$(ss_version_of "$real") || continue ;;
            nginx)
                out=$(LC_ALL=C timeout -k 1 3 "$real" -v 2>&1) || continue
                ver=$(nginx_banner_version "$out") || continue ;;
        esac
        printf '%s' "$ver"
        return 0
    done
    return 1
}

home_read_versions() {
    local managed=$1 cmd ver
    local -n versions_out=$2
    for cmd in xray nginx ssserver; do
        if ver=$(home_component_version "$cmd" "$managed"); then versions_out[$cmd]=$ver; fi
    done
    return 0
}

home_core_versions() {
    local -n versions_in=$1
    local cmd name ver label='核心' entry stacked=0 room=$(( UI_W - 2 - LABEL_W - 8 ))
    if (( UI_W < 30 || ! UI_UTF8 )); then stacked=1; room=$(( UI_W - 10 )); fi
    for cmd in xray nginx ssserver; do
        ver=${versions_in[$cmd]:-}
        [[ -n $ver ]] || continue
        case $cmd in xray) name=Xray ;; nginx) name=Nginx ;; ssserver) name=SS-Rust ;; esac
        if (( stacked )) && [[ -n $label ]]; then ui_group "$label"; fi
        # Version strings contain ASCII only. Keep every suffix in the same column.
        ver=v$ver
        while [[ -n $ver ]]; do
            printf -v entry '%-8s%s' "$name" "${ver:0:room}"
            if (( stacked )); then ui_emit "  $entry"; else ui_kv "$label" "$entry"; fi
            name='' label='' ver=${ver:room}
        done
    done
    return 0
}

home_status() {
    local installed=$1 running=0 compact=0 managed='' bin='' services unit stats='' up='' rows='' mem='' conn LABEL_W=8
    local -a metrics=()
    local -A versions=()
    (( UI_W >= 30 )) || LABEL_W=6
    if (( TUI && UI_H <= 18 )); then compact=1; fi
    if (( installed )); then
        ui_kv '方案' "$(scheme_label "$(scheme)")"
        services=$(wanted_services) || services=''
        # wanted_services lists the managed core before its optional Nginx frontend.
        unit=${services%%$'\n'*}
        case $unit in xray) managed=xray bin=$XRAY_BIN ;; zxray-ss) managed=ssserver bin=$SS_BIN ;; esac
        rows=$(public_ports) || rows=''
        local rc=0
        system_running "$services" || rc=$?
        if (( ! compact && rc != 2 )) && [[ -n $bin ]] && stats=$(core_process_metrics "$unit" "$bin"); then
            up=${stats%:*} mem=${stats#*:}
        fi
        if (( rc == 0 )); then
            running=1
            if [[ -n $up ]]; then ui_kv '状态' "${C_GREEN}运行中${C_RESET}" "$(human_uptime "$up")"
            else ui_kv '状态' "${C_GREEN}运行中${C_RESET}"; fi
        elif (( rc == 2 )); then
            running=2
            ui_kv '状态' "${C_YELLOW}查询失败${C_RESET}"
        else
            ui_kv '状态' "${C_YELLOW}服务未就绪${C_RESET}"
        fi
    else
        ui_kv '状态' '尚未部署'
    fi
    home_read_versions "$managed" versions
    if (( ! compact )); then home_core_versions versions; fi
    if [[ -n $stats ]]; then
        [[ -z $mem ]] || metrics+=("内存 $mem MB")
        if conn=$(tcp_conn_count "$rows"); then metrics+=("TCP 连接 $conn"); else conn=''; fi
        if (( ${#metrics[@]} )); then
            if (( UI_W >= 32 )); then ui_kv_words '用量' "${metrics[@]}"
            else
                [[ -z $mem ]] || ui_kv '内存' "$mem MB"
                [[ -z $conn ]] || ui_kv 'TCP 连接' "$conn"
            fi
        fi
    fi
    if (( installed )); then
        local cur=''
        [[ $managed != xray ]] || cur=${versions[xray]:-}
        home_alerts "$running" "$rows" "$cur"
    fi
    # Keep installed versions next to the first menu item in a short viewport.
    if (( compact )); then home_core_versions versions; fi
}

home_build() {
    local installed=0 status='' retry=''
    ui_banner
    if (( ! TUI || UI_H > 14 )); then ui_blank; fi
    if [[ -e $TX || -L $TX ]]; then
        status='有操作进行中或待恢复' retry='检查事务'
    elif state_ok; then
        installed=1 DRAFT=$STATE
    elif [[ -e $STATE || -L $STATE ]]; then
        status='安装记录待核查' retry='检查安装记录'
    fi
    if [[ -n $retry ]]; then
        ui_kv '状态' "$status"
        ui_rule
        tui_item r "$retry" '' '加锁后重新检查'
        tui_item 0 '退出'
        TUI_FOOT='上下键 移动   回车 确认   q 退出'
        TUI_FOOT_PLAIN="r $retry   0 退出"
        return 0
    fi
    select_core_path
    home_status "$installed" || ui_note '状态正在变化，请重新打开查看。'
    ui_rule
    if (( installed )); then
        tui_item 1 '修改配置' '' '查看或调整设置'
        tui_item 2 '分享链接' '' '查看或复制链接'
        tui_item 3 '更新与维护' '' '更新、重启与回滚'
    else
        tui_item 1 '安装' '' '选择部署方案'
        tui_item 2 '分享链接' '' '安装后可用'
        tui_item 3 '更新与维护' '' '安装后可用'
    fi
    tui_item 4 '卸载' '' '移除托管组件'
    tui_item 0 '退出'
    TUI_FOOT='上下键 移动   回车 确认   q 退出'
    TUI_FOOT_PLAIN='1-4 选择   0 退出'
}

stop_update_check() {
    local j owned=0 i
    [[ -n $UPDATE_BG_PID ]] || return 0
    # Only signal a job created by this shell, in its own process group.
    for j in $(jobs -p); do [[ $j != "$UPDATE_BG_PID" ]] || owned=1; done
    if (( owned )) && kill -0 "$UPDATE_BG_PID" 2>/dev/null; then
        kill -TERM -- "-$UPDATE_BG_PID" 2>/dev/null || kill -TERM "$UPDATE_BG_PID" 2>/dev/null || true
        for (( i=0; i<20; i++ )); do
            kill -0 "$UPDATE_BG_PID" 2>/dev/null || break
            sleep 0.05
        done
        if kill -0 "$UPDATE_BG_PID" 2>/dev/null; then
            kill -KILL -- "-$UPDATE_BG_PID" 2>/dev/null || true
        fi
    fi
    wait "$UPDATE_BG_PID" 2>/dev/null || true
    [[ -z $UPDATE_BG_TMP ]] || rm -f -- "$UPDATE_BG_TMP" "$UPDATE_BG_TMP.tag"
    UPDATE_BG_PID='' UPDATE_BG_TMP=''
}

update_cache_due() {
    local file=$DATA_DIR/update-check.json mtime now
    [[ ! -e $TX && ! -L $TX && ! -L $file ]] || return 1
    [[ -e $file ]] || return 0
    [[ -f $file ]] && mtime=$(stat -c %Y -- "$file") && now=$(date +%s) || return 1
    (( now < mtime || now - mtime >= 86400 ))
}

update_check_bg() {
    local DRAFT=$STATE stamp monitor=0 x pending=''
    update_cache_due || return 0
    stamp=$(stat -c '%d:%i:%z' -- "$STATE" 2>/dev/null) || return 0
    state_ok && needs_xray || return 0
    [[ $(jq -r '.core.xray // empty' "$STATE" 2>/dev/null) == latest ]] || return 0
    # Network I/O must neither hold the manager lock nor write into an installation
    # that another terminal can snapshot, replace or uninstall in the meantime.
    UPDATE_BG_TMP=$(mktemp "$ROOT/run/.zxray-update.XXXXXXXX") || return 0
    [[ $- != *m* ]] || monitor=1
    set -m
    (
        trap - ERR INT TERM HUP EXIT
        set +m
        trap '' TSTP
        trap 'exit 143' TERM HUP
        trap 'trap "" TERM HUP; [[ -z $pending ]] || rm -f -- "$pending"; exec 9>&-; kill_jobs; rm -f -- "$UPDATE_BG_TMP" "$UPDATE_BG_TMP.tag"' EXIT
        set +e
        STEP_LOG=/dev/null
        latest_tag_try XTLS/Xray-core x "$UPDATE_BG_TMP" || exit 0
        # Use an independent open description for this brief, optional write.
        # /run starts empty after boot; concurrent first openers must use one inode.
        [[ ! -L $LOCK_FILE && ( ! -e $LOCK_FILE || -f $LOCK_FILE ) ]] || exit 0
        exec 9>> "$LOCK_FILE" || exit 0
        flock -n 9 || exit 0
        [[ ! -L $LOCK_FILE && /proc/$BASHPID/fd/9 -ef $LOCK_FILE ]] || exit 0
        update_cache_due && check_private_dirs && [[ -f $STATE && ! -L $STATE ]] || exit 0
        [[ $(stat -c '%d:%i:%z' -- "$STATE") == "$stamp" ]] || exit 0
        cd -- "$DATA_DIR" || exit 0
        pending=$(mktemp .update-check.XXXXXXXX) || exit 0
        if jq -n --arg x "$x" '{xray: $x}' > "$pending" &&
            mv -fT -- "$pending" update-check.json; then pending=''; fi
    ) </dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 8>&- 9>&- &
    UPDATE_BG_PID=$!
    (( monitor )) || set +m
}


on_main_int() {
    (( CHILD_RUNNING )) && return 0
    printf '\n'
    exit 130
}

on_main_exit() {
    stop_update_check
    tui_cursor on
    tty_echo "${INPUT_TTY_STATE:-echo}"
}

run_top() {
    stop_update_check
    run_child "$@"
    TOP_RC=$CHILD_RC
    if [[ $ACTION != menu ]] && (( TOP_RC == 42 )); then TOP_RC=1; fi
    TOP_QUIET=0
    if (( TOP_RC == RC_QUIET )); then TOP_RC=0 TOP_QUIET=1; fi
}

after_action() {
    if (( $1 == 20 )); then exit 0; fi
    return 0
}

check_private_dirs() {
    local dir mode
    for dir in "$DATA_DIR" "$SELF_DIR" "$TX" "$@"; do
        if [[ -L $dir || ( -e $dir && ! -d $dir ) ]]; then
            die "托管目录路径异常：$dir"; return 1
        fi
        [[ -d $dir ]] || continue
        # The manager runs as root; a sourced test can use its own private tree.
        if ! mode=$(stat -c %a -- "$dir" 2>/dev/null); then
            [[ ! -e $dir && ! -L $dir ]] && continue
            die "无法读取托管目录权限：$dir"; return 1
        fi
        if [[ ! -O $dir || ! $mode =~ ^[0-7]{1,4}$ ]] || (( (8#$mode & 0022) != 0 )); then
            die "托管目录的属主或权限异常：$dir" '请确认目录属于运行管理脚本的账号，且组和其他用户不可写。'
            return 1
        fi
    done
    return 0
}

verify_running_script() {
    local file=${1:-$SOURCE_PATH} digest
    [[ -z $SOURCE_DIGEST ]] && return 0
    if [[ -L $file || ! -f $file ]] || ! digest=$(sha256sum < "$file") || [[ $digest != "$SOURCE_DIGEST" ]]; then
        die '正在运行的脚本文件已变化，请退出后重新打开。'
        return 1
    fi
}

prepare_runtime() {
    # A minimal install can need util-linux before its first lock. Validate
    # the management paths before installing any dependencies in either case.
    if have flock; then acquire_lock; fi
    check_private_dirs || exit 1
    verify_running_script || exit 1
    local d resolved
    local -a prefixes=("${ROOT:-/}" "$ROOT/usr")
    for d in "$ROOT/usr/local" "$ROOT/usr/local/"{bin,lib,share,etc}; do
        if [[ -d $d ]]; then
            prefixes+=("$d")
            if [[ -L $d ]]; then
                resolved=$(readlink -f -- "$d") || exit 1
                [[ -z $ROOT || $resolved == "$ROOT"/* ]] || { die "管理目录超出根路径：$d"; exit 1; }
                while [[ $resolved != / && $resolved != "$ROOT" ]]; do
                    prefixes+=("$resolved"); resolved=${resolved%/*}; resolved=${resolved:-/}
                done
            fi
        elif [[ -e $d || -L $d ]]; then
            die "管理路径应为目录：$d"; exit 1
        fi
    done
    trusted_path_entries managed "${prefixes[@]}" || {
        die '无法确认 /usr/local 管理路径的写权限。' \
            '请核查目录属主、ACL 和 staff 组成员。共享写入者无法核实时，请由管理员收回相应目录的组写权限。'
        exit 1
    }
    ensure_deps || exit 1
    if [[ $LOCK_OWNER != "$BASHPID" ]]; then
        acquire_lock
        check_private_dirs || exit 1
        verify_running_script || exit 1
    fi
    SOURCE_RECORD=$(source_script_record "${BASH_SOURCE[0]}" "${SOURCE_DIGEST%% *}" 2>/dev/null) || SOURCE_RECORD=''
    select_core_path
    tx_recover_if_needed
    migrate_state
    select_core_path
    check_state_file
    clean_stale_stages
}

main() {
    local sel=0 key dir
    parse_args "$@" || return 1
    (( EUID == 0 )) || fatal '请用 root 运行（例如 sudo sh xray-manager.sh）。'
    # A non-login su may retain a PATH without administrative utilities.
    for dir in /usr/local/sbin /usr/sbin /sbin; do
        [[ :${PATH-}: == *:"$dir":* ]] || PATH=${PATH:+$PATH:}$dir
    done
    export PATH
    detect_system || exit 1
    input_setup
    ui_setup
    trap 'on_main_int' INT
    trap 'exit 143' TERM HUP
    trap 'on_main_exit' EXIT
    if [[ $ACTION == uninstall ]] && ! uninstall_preflight; then return "$TOP_RC"; fi
    SOURCE_PATH=$(readlink -f -- "${BASH_SOURCE[0]}") || fatal '无法定位当前脚本文件。'
    SOURCE_DIGEST=$(sha256sum < "$SOURCE_PATH") || fatal '无法核对当前脚本内容。'
    case $ACTION in
        install)
            if (( ASSUME_YES )); then run_top action_install_cli; else run_top action_install; fi
            after_action "$TOP_RC"; exit "$TOP_RC" ;;
        update)
            run_top action_update
            after_action "$TOP_RC"; exit "$TOP_RC" ;;
        uninstall) run_top action_uninstall; after_action "$TOP_RC"; exit "$TOP_RC" ;;
        nodes) run_top action_nodes; exit "$TOP_RC" ;;
    esac

    trap 'TUI_RESIZED=1' WINCH
    check_private_dirs || exit 1
    select_core_path
    if [[ -e $TX || -L $TX ]] || { [[ -e $STATE || -L $STATE ]] && ! state_ok; }; then
        run_top :
        if (( TOP_RC == 42 )); then TUI_MSG='管理锁仍被占用，请稍后重试。'
        elif (( TOP_RC != 0 )); then exit "$TOP_RC"; fi
    fi
    if [[ ! -e $TX && ! -L $TX ]]; then update_check_bg; fi
    ui_flush
    while :; do
        tui_menu home_build "$sel" q
        sel=$TUI_CUR
        case $TUI_KEY in
            q) ui_clear; exit 0 ;;
            ENTER) ;;
            *) continue ;;
        esac
        key=${TUI_IKEYS[$TUI_CUR]}
        if [[ $key == 0 ]]; then ui_clear; exit 0; fi
        if [[ ( $key == 2 || $key == 3 ) && ! -e $STATE && ! -L $STATE && ! -e $TX && ! -L $TX ]]; then
            TUI_MSG='请先完成安装。'
            continue
        fi
        if [[ $key == 4 ]] && ! uninstall_preflight; then continue; fi
        case $key in
            r) run_top : ;;
            1) run_top action_install ;;
            2) run_top action_nodes ;;
            3) run_top action_maintain ;;
            4) run_top action_uninstall ;;
        esac
        after_action "$TOP_RC"
        # Returning from a view needs no prompt. Leave failures visible before redrawing.
        if (( TOP_RC == 0 )) && [[ $key == [23r] ]]; then continue; fi
        if (( TOP_RC != 130 && ! TOP_QUIET )); then ui_pause; fi
    done
}

if [[ ${BASH_SOURCE[0]:-} == "$0" ]]; then main "$@"; fi
