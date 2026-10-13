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
exec 4>&1 5>&2

readonly SCRIPT_VERSION="0.2.0"
readonly SCRIPT_MARKER="ZXRAY_MANAGER"
readonly SCRIPT_REMOTE_URL="https://raw.githubusercontent.com/WhiteMitty/xray-manager/main/xray-manager.sh"
readonly XRAY_MIN_VERSION="26.3.27"
readonly XRAY_COMPAT_VERSION="v26.7.28"
readonly XRAY_SETTLE_DAYS=3
readonly XRAY_MLKEM_VERSION=26.9.8
readonly STATE_SCHEMA=5
readonly SERVICE_USER="zxray"
readonly MANAGED_TAG="# Managed by Xray Manager"
readonly RC_QUIET=10
readonly SCHEMES=(reality-raw reality-xhttp reality-split ss enc dual triple enc-split)
readonly DEFAULT_SNI_POOL=(c.6sc.co www.amazon.com drivers.amd.com a0.awsstatic.com d1.awsstatic.com
    s0.awsstatic.com gateway.icloud.com m.media-amazon.com addons.mozilla.org tag.demandbase.com
    t0.m.awsstatic.com images-na.ssl-images-amazon.com)

init_paths() {
    ROOT=${1:-}
    DATA_DIR=$ROOT/usr/local/share/zxray
    SELF_DIR=$ROOT/usr/local/lib/zxray
    SELF_SCRIPT_PATH=$SELF_DIR/zxray.sh
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
    INFO_FILE=$DATA_DIR/node-info.txt
    SUB_FILE=$DATA_DIR/subscription.txt
    SUB_B64=$DATA_DIR/subscription.b64
    SNI_POOL_FILE=$DATA_DIR/sni-pool.txt
    TX=$ROOT/usr/local/share/zxray-transaction
    STAGE_BASE=$ROOT/usr/local/share/zxray-stage
    LOCK_FILE=$ROOT/run/zxray.lock
    SYSCTL_FILE=$ROOT/etc/sysctl.d/99-zxray-bbr.conf
    SYSTEMD_DIR=$ROOT/etc/systemd/system
    OPENRC_DIR=$ROOT/etc/init.d
    OLD_DATA_DIR=$ROOT/usr/local/share/doudou-xray
    OLD_SELF_SCRIPT=$ROOT/usr/local/lib/doudou/xray_manager.sh
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
STEP_NO=0 STEP_TOTAL=0 STEP_OPEN=0 STEP_LOG='' STEP_LABEL='' DIE_SHOWN=0
CHILD_RC=0 SUB_RC=0 TOP_RC=0 TOP_QUIET=0 STATE_READY=0
MODE=new PREVIEW_RESULT=1 PORT_NOTE='' DRAFT_WATCH=0 DRAFT_BASE=''
PREVIEW_NOTES=() CREATED_DIRS=()
NET_V4='' NET_V6=''
SNI_BEST_MS=0
PARSE_ERR=''
SERVICE_USER_CREATED=0
NGINX_MODULE_LINE='' NGINX_REJECT_TLS=1
USE_XRAY='' USE_XRAY_ASSET='' USE_SS=''
NEW_XRAY=0 NEW_SS=0
UI_W=60 UI_H=24 LABEL_W=12 KEY_W=1
TUI=0 TUI_KEY='' TUI_CUR=0 TUI_TOP=0 TUI_HEAD=0 TUI_PREV_OK=0 INPUT_DIRTY=0 STEP_PW=0 TUI_MSG='' TUI_RESIZED=0 TUI_HELP_H=0 TUI_HELP_DIM=1 TUI_FOOT='' TUI_FOOT_PLAIN=''
UI_BUF_ON=0 SPIN_PID='' QR_DECLINED=0
UI_BUF=() TUI_ITEMS=() TUI_IKEYS=() TUI_HELPS=() TUI_PREV=()
C_KEY='' C_GROUP='' C_RULE='' C_DIM='' C_BOLD='' C_GREEN='' C_YELLOW='' C_RED='' C_RESET='' C_TITLE='' C_TITLE_OK=''

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

ui_measure() {
    local sz=''
    if input_is_tty; then sz=$(stty size <&"$INPUT_FD" 2>/dev/null || true); fi
    if [[ ! $sz =~ ^[0-9]+\ [0-9]+$ && -t 1 ]]; then sz="$(tput lines 2>/dev/null || true) $(tput cols 2>/dev/null || true)"; fi
    [[ $sz =~ ^([0-9]+)\ ([0-9]+)$ ]] || return 0
    (( BASH_REMATCH[1] > 0 && BASH_REMATCH[2] > 0 )) || return 0
    UI_H=${BASH_REMATCH[1]}
    UI_W=${BASH_REMATCH[2]}
    (( UI_W <= 60 )) || UI_W=60
    (( UI_W >= 40 )) || UI_W=40
    (( UI_H >= 12 )) || UI_H=12
}

ui_setup() {
    ui_setup_locale
    ui_measure
    if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
        C_KEY=$'\e[36m'
        C_GROUP=$'\e[1;36m'
        C_RULE=$'\e[90m'
        C_DIM=$'\e[90m'
        C_BOLD=$'\e[1m'
        C_GREEN=$'\e[32m'
        C_YELLOW=$'\e[33m'
        C_RED=$'\e[31m'
        C_RESET=$'\e[0m'
        C_TITLE=$'\e[1;93m'
        C_TITLE_OK=$'\e[1;92m'
    fi
    if [[ -t 1 ]] && input_is_tty && [[ -n ${TERM:-} && ${TERM:-} != dumb ]] && (( ! ASSUME_YES )); then TUI=1; fi
    return 0
}

byte_len() { local LC_ALL=C; printf -v "$2" '%d' "${#1}"; }

strip_ansi() {
    local __sa_s=$1
    while [[ $__sa_s =~ $'\e'\[[0-9\;]*m ]]; do __sa_s=${__sa_s/"${BASH_REMATCH[0]}"/}; done
    printf -v "$2" '%s' "$__sa_s"
}

str_width() {
    local __sw_s __sw_c __sw_b
    strip_ansi "$1" __sw_s
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
    strip_ansi "$__fw_s" __fw_s
    if (( __fw_max < 8 )); then
        __fw_out='' __fw_acc=0
        for (( __fw_i = 0; __fw_i < ${#__fw_s}; __fw_i++ )); do
            __fw_ch=${__fw_s:__fw_i:1}
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

fit_value_note() {
    local __fv_v=$1 __fv_n=$2 __fv_max=$3 __fv_vw __fv_out
    str_width "$__fv_v" __fv_vw
    if [[ -z $__fv_n ]] || (( __fv_vw + 10 > __fv_max )); then
        fit_width "$__fv_v" "$__fv_max" __fv_out
        printf -v "$4" '%s' "$__fv_out"
        return 0
    fi
    if [[ -z $__fv_v ]]; then
        fit_width "$__fv_n" "$__fv_max" __fv_out end
        printf -v "$4" '%s%s%s' "$C_DIM" "$__fv_out" "$C_RESET"
        return 0
    fi
    fit_width "$__fv_n" $(( __fv_max - __fv_vw - 2 )) __fv_out end
    printf -v "$4" '%s  %s%s%s' "$__fv_v" "$C_DIM" "$__fv_out" "$C_RESET"
}

ui_emit() {
    if (( UI_BUF_ON )); then UI_BUF+=("$1"); else printf '%s\n' "$1" >&4; fi
}

rule_line() {
    local __rl_l
    printf -v __rl_l '%*s' "$UI_W" ''
    printf -v "$1" '%s%s%s' "$C_RULE" "${__rl_l// /${2:--}}" "$C_RESET"
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
    if [[ $t != *$'\e'* ]]; then wrap_text "$t" $(( UI_W - 2 )) t; fi
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
    str_width "$t$v" w
    l=$(( (UI_W - w) / 2 ))
    ui_rule_thick
    printf -v line '%*s%s%s%s%s%s%s' "$l" '' "$C_TITLE" "$t" "$C_RESET" "$C_DIM" "$v" "$C_RESET"
    ui_emit "$line"
    ui_rule_thick
    (( ! UI_BUF_ON )) || TUI_HEAD=${#UI_BUF[@]}
}

ui_title() {
    local text=$1 sub=${2:-} c=$C_TITLE h0=${#UI_BUF[@]} w tw
    [[ ${3:-} != ok ]] || c=$C_TITLE_OK
    if [[ -n $sub ]]; then
        str_width "$text" tw
        str_width "$sub" w
        (( tw + 4 + w <= UI_W - 2 )) || fit_width "$sub" $(( UI_W - 6 - tw )) sub
    fi
    ui_rule_thick
    ui_emit "  $c$text$C_RESET${sub:+    $C_DIM$sub$C_RESET}"
    ui_rule
    (( ! UI_BUF_ON || h0 > 0 )) || TUI_HEAD=${#UI_BUF[@]}
}

ui_page() {
    KEY_W=1
    ui_clear
    ui_title "$@"
}

ui_group() { ui_emit "  $C_GROUP$1$C_RESET"; }

ui_item() {
    local key=$1 label=$2 value=${3:-} note=${4:-} padded fitted
    printf -v key '%*s' "$KEY_W" "$key"
    if [[ -z $value && -z $note ]]; then
        ui_emit "   $C_KEY$key$C_RESET  $label"
        return 0
    fi
    pad_to "$label" "$LABEL_W" padded
    fit_value_note "$value" "$note" $(( UI_W - 5 - KEY_W - LABEL_W )) fitted
    ui_emit "   $C_KEY$key$C_RESET  $padded$fitted"
}

ui_cont() {
    local pad fitted
    printf -v pad '%*s' $(( KEY_W + LABEL_W + 5 )) ''
    fit_value_note "$1" "${2:-}" $(( UI_W - 5 - KEY_W - LABEL_W )) fitted
    ui_emit "$pad$fitted"
}

ui_kv() {
    local label=$1 value=${2:-} note=${3:-} padded fitted
    pad_to "$label" "$LABEL_W" padded
    fit_value_note "$value" "$note" $(( UI_W - 2 - LABEL_W )) fitted
    ui_emit "  $padded$fitted"
}

ui_kv_words() {
    local label=$1 padded line='' w word
    shift
    pad_to "$label" "$LABEL_W" padded
    for word in "$@"; do
        str_width "$line $word" w
        if [[ -n $line ]] && (( w > UI_W - 2 - LABEL_W )); then
            ui_emit "  $padded$line"
            printf -v padded '%*s' "$LABEL_W" ''
            line=$word
        else
            line+=${line:+ }$word
        fi
    done
    ui_emit "  $padded$line"
}

ui_option() {
    local key=$1 label=$2 desc=$3 cur=$4 lw=$5 padded fitted room w tag=''
    pad_to "$label" "$lw" padded
    room=$(( UI_W - 5 - ${#key} - lw ))
    (( cur )) && room=$(( room - 6 ))
    fit_value_note '' "$desc" "$room" fitted
    if (( cur )); then
        str_width "$fitted" w
        printf -v tag '%*s%s当前%s' $(( room - w + 2 )) '' "$C_GREEN" "$C_RESET"
    fi
    ui_emit "   $C_KEY$key$C_RESET  $padded$fitted$tag"
}

footer_line() {
    local s=$1 seg key out='' plain='' w
    local -a segs=()
    [[ -z $ACTION_PID ]] || s+='   b 主页'
    while [[ $s == *'   '* ]]; do
        segs+=("${s%%   *}")
        s=${s#*   }
    done
    segs+=("$s")
    for seg in "${segs[@]}"; do
        str_width "$plain${plain:+   }$seg" w
        (( w + 2 <= UI_W )) || break
        plain+="${plain:+   }$seg"
        key=${seg%% *}
        out+="${out:+   }$C_KEY$key$C_RESET${seg#"$key"}"
    done
    printf -v "$2" '  %s' "$out"
}

ui_footer() {
    local l
    ui_rule_thick
    footer_line "$*" l
    ui_emit "$l"
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
    ) >&4 2>/dev/null 3>&- 9>&- &
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
    local r=$1
    fit_width "$r" $(( UI_W - STEP_PW )) r
    printf '%s\n' "$r" >&4
    STEP_OPEN=0
    step_mark end
}

ui_step() {
    tty_echo -echo
    INPUT_DIRTY=1
    STEP_NO=$(( STEP_NO + 1 ))
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
    [[ ! -t 1 ]] || printf '\e[H\e[2J' >&4
}

tui_cursor() {
    [[ -t 1 ]] || return 0
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
}

input_is_tty() { [[ -t $INPUT_FD ]]; }

tty_echo() {
    input_is_tty || return 0
    stty "$1" <&"$INPUT_FD" 2>/dev/null || true
}

ui_flush() {
    INPUT_DIRTY=0
    input_is_tty || return 0
    local _f
    while IFS= read -r -s -n 64 -t 0.02 -u "$INPUT_FD" _f 2>/dev/null; do :; done
    return 0
}

on_tstp() {
    tui_cursor on
    trap - TSTP
    kill -TSTP "$BASHPID"
    trap on_tstp TSTP
    tty_echo -echo
    tui_cursor off
    TUI_PREV_OK=0
    TUI_RESIZED=1
}

input_eof() {
    printf '\n' >&4
    if [[ -n $ACTION_PID ]]; then
        exit 130
    fi
    exit 0
}

draft_hash() { jq -S -c . "$DRAFT" 2>/dev/null | sha256sum | cut -c1-16; }

draft_watch_start() { DRAFT_BASE=$(draft_hash); DRAFT_WATCH=1; }
draft_watch_stop() { DRAFT_WATCH=0; DRAFT_BASE=''; }
draft_changed() { [[ -n $DRAFT_BASE && $(draft_hash) != "$DRAFT_BASE" ]]; }

confirm_discard() {
    (( DRAFT_WATCH )) && draft_changed || return 0
    DRAFT_WATCH=0
    if ask_no "$1"; then return 0; fi
    DRAFT_WATCH=1
    return 1
}

go_home_if_b() {
    [[ ( $1 == b || $1 == B ) && -n $ACTION_PID ]] || return 0
    confirm_discard '有修改还没应用，放弃这些修改并回主页' || return 1
    exit 130
}

read_line() {
    local __rl_p=$1 __rl_v='' __rl_pre=${3:-}
    ui_flush
    tty_echo echo
    tui_cursor on
    if (( TUI )) && [[ -n $__rl_pre ]]; then
        IFS= read -r -e -i "$__rl_pre" -p "  $__rl_p" -u "$INPUT_FD" __rl_v 2>&4 || input_eof
    else
        printf '  %s' "$__rl_p" >&4
        IFS= read -r -u "$INPUT_FD" __rl_v || input_eof
        input_is_tty || printf '%s\n' "$__rl_v" >&4
    fi
    __rl_v=${__rl_v#"${__rl_v%%[![:space:]]*}"}
    __rl_v=${__rl_v%"${__rl_v##*[![:space:]]}"}
    go_home_if_b "$__rl_v" || __rl_v=''
    printf -v "$2" '%s' "$__rl_v"
}

tui_read_key() {
    local __k='' __c='' __seq='' __rc
    trap on_tstp TSTP
    while :; do
        __rc=0
        IFS= read -rsn1 -t 1 -u "$INPUT_FD" __k || __rc=$?
        if (( __rc > 128 )); then
            if (( TUI_RESIZED )); then TUI_RESIZED=0; trap - TSTP; printf -v "$1" '%s' RESIZE; return 0; fi
            continue
        fi
        (( __rc == 0 )) || input_eof
        break
    done
    case $__k in
        $'\e')
            __rc=0
            IFS= read -rsn1 -t 0.1 -u "$INPUT_FD" __c || __rc=$?
            if [[ $__c == '[' || $__c == O ]]; then
                while IFS= read -rsn1 -t 0.05 -u "$INPUT_FD" __c; do
                    __seq+=$__c
                    [[ $__c != [A-Za-z~] ]] || break
                done
                case $__seq in
                    A) __k=UP ;; B) __k=DOWN ;; C) __k=RIGHT ;; D) __k=LEFT ;;
                    H|1~|7~) __k=HOME ;; F|4~|8~) __k=END ;; 5~) __k=PGUP ;; 6~) __k=PGDN ;;
                    *) __k=NONE ;;
                esac
            else
                __k=ESC
            fi ;;
        ''|$'\r'|$'\n') __k=ENTER ;;
        $'\x04') input_eof ;;
        $'\t') __k=TAB ;;
        $'\x7f'|$'\b') __k=ESC ;;
    esac
    trap - TSTP
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
}

tui_opt() {
    TUI_ITEMS+=("${#UI_BUF[@]}")
    TUI_IKEYS+=("$1")
    TUI_HELPS+=("${6:-}")
    ui_option "$1" "$2" "$3" "$4" "$5"
}

tui_build() {
    local __tb_fn=$1 __tb_i __tb_w __tb_n
    shift
    UI_BUF=() TUI_ITEMS=() TUI_IKEYS=() TUI_HELPS=() TUI_FOOT='' TUI_FOOT_PLAIN='' TUI_HELP_H=0 TUI_HELP_DIM=1 KEY_W=1 TUI_HEAD=0
    UI_BUF_ON=1
    "$__tb_fn" "$@"
    UI_BUF_ON=0
    for __tb_i in "${!UI_BUF[@]}"; do
        str_width "${UI_BUF[$__tb_i]}" __tb_n
        (( __tb_n <= UI_W )) || { fit_width "${UI_BUF[$__tb_i]}" "$UI_W" __tb_w; UI_BUF[__tb_i]=$__tb_w; }
    done
    (( TUI_HELP_H > 0 )) || return 0
    for __tb_i in "${!TUI_HELPS[@]}"; do
        wrap_text "${TUI_HELPS[$__tb_i]}" $(( UI_W - 2 )) __tb_w
        TUI_HELPS[__tb_i]=$__tb_w
        __tb_n=1
        while [[ $__tb_w == *$'\n'* ]]; do __tb_w=${__tb_w#*$'\n'}; __tb_n=$(( __tb_n + 1 )); done
        (( __tb_n <= TUI_HELP_H )) || TUI_HELP_H=$__tb_n
    done
}

wrap_text() {
    local __wt_in=$1 __wt_max=$2 __wt_out='' __wt_line __wt_w __wt_cur __wt_acc __wt_i __wt_ch __wt_b __wt_hold
    local -a __wt_lines=()
    mapfile -t __wt_lines <<< "$__wt_in"
    for __wt_line in "${__wt_lines[@]}"; do
        str_width "$__wt_line" __wt_w
        if (( __wt_w <= __wt_max )); then __wt_out+=${__wt_out:+$'\n'}$__wt_line; continue; fi
        __wt_cur='' __wt_acc=0
        for (( __wt_i = 0; __wt_i < ${#__wt_line}; __wt_i++ )); do
            __wt_ch=${__wt_line:__wt_i:1}
            byte_len "$__wt_ch" __wt_b
            if (( __wt_b > 1 )); then __wt_w=2; else __wt_w=1; fi
            if (( __wt_acc + __wt_w > __wt_max )); then
                __wt_hold=''
                if [[ $__wt_ch == [A-Za-z0-9._/:-] || $__wt_ch == [，。；：、）！？」] ]]; then
                    if [[ $__wt_cur =~ [A-Za-z0-9._/:-]+$ ]]; then __wt_hold=${BASH_REMATCH[0]}
                    elif [[ $__wt_ch != [A-Za-z0-9._/:-] ]]; then __wt_hold=${__wt_cur: -1}; fi
                    (( ${#__wt_hold} < ${#__wt_cur} && ${#__wt_hold} + 4 <= __wt_max )) || __wt_hold=''
                    __wt_cur=${__wt_cur:0:${#__wt_cur}-${#__wt_hold}}
                fi
                __wt_out+=${__wt_out:+$'\n'}${__wt_cur%' '}
                __wt_cur=$__wt_hold
                str_width "$__wt_hold" __wt_acc
                [[ $__wt_ch != ' ' ]] || continue
            fi
            __wt_cur+=$__wt_ch
            __wt_acc=$(( __wt_acc + __wt_w ))
        done
        __wt_out+=${__wt_out:+$'\n'}$__wt_cur
    done
    printf -v "$3" '%s' "$__wt_out"
}

tui_draw() {
    local i line sel=-1 se n avail top end rl rt fl h hd=$TUI_HEAD scroll=0 ind out='' mv
    local -a help=() F=()
    n=${#UI_BUF[@]}
    (( ${#TUI_ITEMS[@]} == 0 )) || sel=${TUI_ITEMS[$TUI_CUR]}
    avail=$(( UI_H - 3 ))
    if (( TUI_HELP_H > 0 )); then avail=$(( avail - TUI_HELP_H - 1 )); fi
    [[ -z $TUI_MSG ]] || avail=$(( avail - 1 ))
    (( hd + 4 <= avail )) || hd=0
    for (( i = 0; i < hd; i++ )); do F+=("${UI_BUF[$i]}"); done
    avail=$(( avail - hd ))
    (( avail >= 3 )) || avail=3
    top=$hd
    if (( n - hd > avail )); then
        scroll=1
        avail=$(( avail - 1 ))
        se=$sel
        if (( sel >= 0 )); then
            if (( TUI_CUR + 1 < ${#TUI_ITEMS[@]} )); then se=$(( TUI_ITEMS[TUI_CUR + 1] - 1 )); else se=$(( n - 1 )); fi
        fi
        (( se - sel < avail )) || se=$(( sel + avail - 1 ))
        top=$TUI_TOP
        (( top >= hd )) || top=$hd
        (( TUI_CUR > 0 )) || top=$hd
        (( sel < 0 || sel >= top )) || top=$sel
        (( se < top + avail )) || top=$(( se - avail + 1 ))
        (( top + avail <= n )) || top=$(( n - avail ))
        (( top >= hd )) || top=$hd
    fi
    TUI_TOP=$top
    end=$(( top + avail ))
    (( end <= n )) || end=$n
    for (( i = top; i < end; i++ )); do
        line=${UI_BUF[$i]}
        (( i != sel )) || tui_hl "$line" line
        F+=("$line")
    done
    if (( scroll )); then
        if (( top > hd && end < n )); then ind='^ v 上下还有内容'
        elif (( end < n )); then ind='v 下面还有内容'
        else ind='^ 上面还有内容'; fi
        F+=("  $C_DIM$ind$C_RESET")
    fi
    rule_line rl
    rule_line rt '='
    if (( TUI_HELP_H > 0 )); then
        F+=("$rl")
        mapfile -t help <<< "${TUI_HELPS[$TUI_CUR]:-}"
        for (( h = 0; h < TUI_HELP_H; h++ )); do
            if (( TUI_HELP_DIM )); then F+=("  $C_DIM${help[$h]:-}$C_RESET"); else F+=("  ${help[$h]:-}"); fi
        done
    fi
    if [[ -n $TUI_MSG ]]; then fit_width "$TUI_MSG" $(( UI_W - 2 )) line; F+=("  $C_YELLOW$line$C_RESET"); fi
    footer_line "${TUI_FOOT:-上下键 移动   回车 选择   Esc 返回}" fl
    F+=("$rt" "$fl")
    if (( TUI_PREV_OK )); then
        for i in "${!F[@]}"; do
            [[ ${F[$i]} != "${TUI_PREV[$i]-}" ]] || continue
            printf -v mv '\e[%d;1H\e[2K' $(( i + 1 ))
            out+=$mv${F[$i]}
        done
        if (( ${#F[@]} < ${#TUI_PREV[@]} )); then printf -v mv '\e[%d;1H\e[J' $(( ${#F[@]} + 1 )); out+=$mv; fi
    else
        out=$'\e[H'
        for line in "${F[@]}"; do out+=$'\e[2K'$line$'\n'; done
        out+=$'\e[J'
    fi
    printf -v mv '\e[%d;1H' $(( ${#F[@]} + 1 ))
    out+=$mv
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
    local __tm_fn=$1 __tm_keys=${3:-} __tm_k __tm_n __tm_dg='' __tm_dt=0 __tm_now
    TUI_CUR=${2:-0}
    shift $(( $# < 3 ? $# : 3 ))
    TUI_KEY=''
    if (( ! TUI )); then tui_plain "$__tm_fn" "$__tm_keys" "$@"; return 0; fi
    ui_measure
    TUI_RESIZED=0
    (( ! INPUT_DIRTY )) || ui_flush
    tui_build "$__tm_fn" "$@"
    __tm_n=${#TUI_ITEMS[@]}
    (( TUI_CUR >= 0 && TUI_CUR < __tm_n )) || TUI_CUR=0
    TUI_TOP=0
    TUI_PREV_OK=0
    tty_echo -echo
    tui_cursor off
    while :; do
        tui_draw
        TUI_MSG=''
        tui_read_key __tm_k
        case $__tm_k in
            RESIZE) ui_measure; tui_build "$__tm_fn" "$@"; __tm_n=${#TUI_ITEMS[@]}; (( TUI_CUR < __tm_n )) || TUI_CUR=0; TUI_PREV_OK=0 ;;
            UP) (( __tm_n == 0 )) || TUI_CUR=$(( (TUI_CUR + __tm_n - 1) % __tm_n )) ;;
            DOWN|TAB) (( __tm_n == 0 )) || TUI_CUR=$(( (TUI_CUR + 1) % __tm_n )) ;;
            HOME|PGUP) TUI_CUR=0 ;;
            END|PGDN) (( __tm_n == 0 )) || TUI_CUR=$(( __tm_n - 1 )) ;;
            ENTER) (( __tm_n == 0 )) || { TUI_KEY=ENTER; break; } ;;
            ESC|LEFT) TUI_KEY=ESC; break ;;
            b|B)
                if [[ -n $ACTION_PID ]]; then
                    go_home_if_b b || true
                    tty_echo -echo
                    tui_cursor off
                    TUI_PREV_OK=0
                fi ;;
            *)
                if [[ ${#__tm_k} == 1 && -n $__tm_keys && $__tm_keys == *"$__tm_k"* ]]; then TUI_KEY=$__tm_k; break; fi
                if [[ $__tm_k == q || $__tm_k == Q ]]; then TUI_KEY=ESC; break; fi
                if [[ $__tm_k == [0-9] ]]; then
                    __tm_now=$(now_ms)
                    if [[ -n $__tm_dg ]] && (( __tm_now - __tm_dt < 1000 )) && tui_jump "$__tm_dg$__tm_k"; then __tm_dg=''
                    else tui_jump "$__tm_k" || true; __tm_dg=$__tm_k; fi
                    __tm_dt=$__tm_now
                elif [[ ${#__tm_k} == 1 ]]; then
                    tui_jump "$__tm_k" || true
                fi ;;
        esac
    done
    return 0
}

tui_plain() {
    local __tp_fn=$1 __tp_keys=$2 __tp_k
    shift 2
    UI_BUF_ON=0 TUI_ITEMS=() TUI_IKEYS=() TUI_HELPS=() TUI_FOOT='' TUI_FOOT_PLAIN='' TUI_HELP_H=0 KEY_W=1
    "$__tp_fn" "$@"
    ui_footer "${TUI_FOOT_PLAIN:-$(key_range ${#TUI_IKEYS[@]}) 选择   回车 返回}"
    while :; do
        read_line '请选择：' __tp_k
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
    local p=$1 sel=$2 k yes no t last l w
    local -a pl=()
    ui_flush
    tty_echo -echo
    tui_cursor off
    wrap_text "$p" $(( UI_W - 2 )) t
    mapfile -t pl <<< "$t"
    last=${pl[${#pl[@]} - 1]}
    for l in "${pl[@]:0:${#pl[@]} - 1}"; do printf '\r\e[2K  %s\n' "$l" >&4; done
    str_width "$last" w
    if (( w + 15 > UI_W )); then printf '\r\e[2K  %s\n' "$last" >&4; last=''; fi
    while :; do
        if (( sel )); then yes=$'\e[7m 是 \e[0m' no=' 否 '; else yes=' 是 ' no=$'\e[7m 否 \e[0m'; fi
        printf '\r\e[2K  %s%s%s  %s' "$last" "${last:+   }" "$yes" "$no" >&4
        tui_read_key k
        case $k in
            LEFT|RIGHT|UP|DOWN|TAB) sel=$(( 1 - sel )) ;;
            y|Y) sel=1 ;;
            n|N) sel=0 ;;
            ENTER) printf '\n' >&4; (( sel )) && return 0; return 1 ;;
            ESC) printf '\n' >&4; return 1 ;;
        esac
    done
}

ask_yes() {
    local a
    (( ASSUME_YES )) && return 0
    if (( TUI )); then tui_confirm "$1" 1; return; fi
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
    if (( TUI )); then tui_confirm "$1" 0; return; fi
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
        read_line "$__an_pr：" __an_n "$__an_def"
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
    local i opt w lw=8 desc line pad
    for opt in "${OP_OPTS[@]}"; do
        str_width "${opt%%|*}" w
        (( w + 2 <= lw )) || lw=$(( w + 2 ))
    done
    (( lw >= 12 )) || lw=12
    ui_page "$OP_TITLE" "$OP_SUB"
    if [[ -n $OP_HINT ]]; then ui_hint "$OP_HINT"; ui_blank; fi
    for i in "${!OP_OPTS[@]}"; do
        opt=${OP_OPTS[$i]}
        [[ $opt == *'|'* ]] || opt+='|'
        desc=${opt#*|}
        tui_opt "$(( i + 1 ))" "${opt%%|*}" "${desc%%$'\n'*}" $(( i + 1 == OP_CUR )) "$lw"
        while [[ $desc == *$'\n'* ]]; do
            desc=${desc#*$'\n'}
            fit_width "${desc%%$'\n'*}" $(( UI_W - 7 - lw )) line
            printf -v pad '%*s' $(( 6 + lw )) ''
            ui_emit "$pad$C_DIM$line$C_RESET"
        done
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
    local k
    if (( TUI )); then
        printf '  %s按回车返回%s' "$C_DIM" "$C_RESET" >&4
        ui_flush
        tty_echo -echo
        tui_cursor off
        while :; do
            tui_read_key k
            case $k in ENTER|ESC|q|Q) break ;; b|B) go_home_if_b b || true ;; esac
        done
        printf '\n' >&4
        return 0
    fi
    read_line '按回车返回：' k
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
        (umask 022 && mkdir -p -- "$d")
        for p in "${missing[@]}"; do
            is_managed_path "$p" && continue
            CREATED_DIRS+=("$p")
            [[ ! -d $TX ]] || printf '%s\n' "$p" >> "$TX/created-dirs"
        done
    done
}

remove_created_dirs() {
    local d
    while IFS= read -r d; do
        [[ -n $d ]] && rmdir -- "$d" 2>/dev/null || true
    done < <(sort -ru)
}

repair_std_dirs() {
    local d m
    for d in "$ROOT/usr/local" "$ROOT/usr/local/bin" "$ROOT/usr/local/etc" "$ROOT/usr/local/lib" "$ROOT/usr/local/share"; do
        [[ -d $d && ! -L $d ]] || continue
        m=$(stat -c %a -- "$d" 2>/dev/null) || continue
        (( (8#$m & 5) == 5 )) || chmod go+rx -- "$d"
    done
}

atomic_install() {
    local src=$1 dest=$2 mode=${3:-600} tmp
    make_dir "$(dirname -- "$dest")"
    tmp=$(mktemp "$dest.new.XXXXXX")
    if ! cp -- "$src" "$tmp" || ! chmod "$mode" "$tmp" || ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        die "无法写入 $dest"
    fi
}

atomic_write() {
    local dest=$1 mode=${2:-600} tmp
    make_dir "$(dirname -- "$dest")"
    tmp=$(mktemp "$dest.new.XXXXXX")
    if ! cat > "$tmp" || ! chmod "$mode" "$tmp" || ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        die "无法写入 $dest"
    fi
}

is_managed_file() { [[ -f $1 ]] && grep -q "^$MANAGED_TAG" "$1" 2>/dev/null; }

human_bytes() {
    awk -v b="$1" 'BEGIN {
        if (b >= 1048576) { v = b / 1048576; u = "M" } else if (b >= 1024) { v = b / 1024; u = "K" } else { printf "%d", b; exit }
        s = sprintf("%.1f", v); sub(/\.0$/, "", s); printf "%s%s", s, u }'
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
        *) die "暂不支持 ${id:-这个系统}。" '目前支持 Debian、Ubuntu、Alpine、RHEL 系和 Arch。'; return 1 ;;
    esac
    if [[ -d $ROOT/run/systemd/system ]]; then
        INIT=systemd
    elif have rc-service && [[ $OS_FAMILY == alpine ]]; then
        INIT=openrc
    else
        die '需要 systemd，或者 Alpine 上的 OpenRC。'
        return 1
    fi
}

pkg_run() { (umask 022 && "$@") 3>&- 4>&- 9>&-; }

pkg_install() {
    case $PKG in
        apk) pkg_run apk add --no-cache "$@" ;;
        apt) DEBIAN_FRONTEND=noninteractive pkg_run apt-get -o DPkg::Lock::Timeout=180 install -y -qq "$@" ;;
        dnf) pkg_run dnf install -y -q "$@" ;;
        yum) pkg_run yum install -y -q "$@" ;;
        pacman) pkg_run pacman -S --noconfirm --needed "$@" ;;
    esac
}

pkg_refresh() {
    case $PKG in
        apt) pkg_run apt-get -o DPkg::Lock::Timeout=180 update -qq ;;
        *) : ;;
    esac
}

pkg_remove() {
    (( $# )) || return 0
    case $PKG in
        apk) pkg_run apk del "$@" ;;
        apt) DEBIAN_FRONTEND=noninteractive pkg_run apt-get -o DPkg::Lock::Timeout=180 purge -y -qq "$@" ;;
        dnf) pkg_run dnf remove -y -q "$@" ;;
        yum) pkg_run yum remove -y -q "$@" ;;
        pacman) pkg_run pacman -Rns --noconfirm "$@" ;;
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

pkg_snapshot() {
    case $PKG in
        apt) dpkg-query -W -f='${db:Status-Status} ${Package}\n' 2>/dev/null | awk '$1 == "installed" {print $2}' ;;
        apk) apk info 2>/dev/null ;;
        dnf|yum) rpm -qa --qf '%{NAME}\n' 2>/dev/null ;;
        pacman) pacman -Qq 2>/dev/null ;;
    esac | sort -u
}

pkg_install_tracked() {
    local __pi_var=$1 __pi_before __pi_after __pi_rc=0 __pi_p __pi_new=''
    shift
    __pi_before=$(pkg_snapshot)
    pkg_install "$@" || __pi_rc=$?
    __pi_after=$(pkg_snapshot)
    if [[ $PKG == apt ]]; then
        __pi_new=$(comm -13 <(printf '%s\n' "$__pi_before") <(printf '%s\n' "$__pi_after") | paste -sd ' ' -)
    else
        for __pi_p in "$@"; do
            grep -qxF "$__pi_p" <<< "$__pi_before" && continue
            grep -qxF "$__pi_p" <<< "$__pi_after" && __pi_new+="${__pi_new:+ }$__pi_p"
        done
    fi
    printf -v "$__pi_var" '%s' "$__pi_new"
    return "$__pi_rc"
}

pkg_remove_safe() {
    local p x bad set=" $* "
    local -a safe=()
    for p in "$@"; do
        pkg_installed "$p" || continue
        if [[ $PKG == apt ]]; then
            bad=0
            while read -r x; do
                [[ -z $x || $set == *" $x "* ]] || { bad=1; break; }
            done <<< "$(apt-get -s purge "$p" 2>/dev/null | awk '$1 == "Purg" || $1 == "Remv" {sub(/:.*/, "", $2); print $2}')"
            (( bad )) || safe+=("$p")
        else
            safe+=("$p")
        fi
    done
    (( ${#safe[@]} )) || return 0
    pkg_remove "${safe[@]}"
}

json_words() { tr -s ' ' '\n' <<< "$1" | jq -R . | jq -cs 'map(select(. != ""))'; }

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
    ui_line "正在安装依赖：${need[*]}"
    pkg_refresh >/dev/null 2>&1 || true
    if ! pkg_install "${need[@]}" >/dev/null 2>&1; then
        die "依赖安装失败：${need[*]}" '请检查软件源和网络后重试。'
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
    local -a argv=()
    if [[ $INIT == openrc ]]; then
        case $action in
            enable) argv=(rc-update add "$name" default) ;;
            disable) argv=(rc-update del "$name" default) ;;
            *) argv=(rc-service "$name" "$action") ;;
        esac
    else
        argv=(systemctl "$action" "$name")
    fi
    (umask 022 && "${argv[@]}") >/dev/null 2>>"${STEP_LOG:-/dev/null}" 3>&- 4>&- 9>&-
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
        if ! have setcap; then
            local added=''
            pkg_install_tracked added libcap-setcap >/dev/null 2>&1 || true
            if [[ -n $added ]]; then
                [[ ! -d $TX ]] || tr -s ' ' '\n' <<< "$added" >> "$TX/new-packages"
                st_filter --argjson add "$(json_words "$added")" '.meta.extra_packages = (((.meta.extra_packages // []) + $add) | unique)'
            fi
        fi
        have setcap || { die '缺少 setcap，服务没法以普通用户监听 1024 以下的端口。'; return 1; }
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
        die "无法创建运行用户 $SERVICE_USER：系统里没有 useradd 或 adduser。"
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

check_service_access() {
    local f
    have su || return 0
    su -s /bin/sh -c true "$SERVICE_USER" >/dev/null 2>&1 || return 0
    for f in "$@"; do
        su -s /bin/sh -c "test -r '$f'" "$SERVICE_USER" >/dev/null 2>&1 && continue
        die "运行用户 $SERVICE_USER 读不到 $f。" "请检查它所在各级目录的权限（其他用户需要有 x 权限）。"
        return 1
    done
}


fw_kind() {
    if have ufw && [[ $(ufw status 2>/dev/null || true) == *'Status: active'* ]]; then printf 'ufw'
    elif have firewall-cmd && [[ $(firewall-cmd --state 2>/dev/null || true) == running ]]; then printf 'firewalld'; fi
    return 0
}

fw_has() {
    case $1 in
        ufw) ufw status 2>/dev/null | awk -v r="$2" -v p="${2%/*}" '($1 == r || $1 == p) && $2 == "ALLOW" && ($3 == "Anywhere" || $3 == "IN") {f = 1} END {exit !f}' ;;
        firewalld) firewall-cmd -q --query-port="$2" 2>/dev/null && firewall-cmd -q --permanent --query-port="$2" 2>/dev/null ;;
        *) return 1 ;;
    esac
}

fw_add() {
    case $1 in
        ufw) ufw allow "$2" >/dev/null 2>>"${STEP_LOG:-/dev/null}" ;;
        firewalld)
            firewall-cmd -q --permanent --add-port="$2" 2>>"${STEP_LOG:-/dev/null}" &&
                firewall-cmd -q --add-port="$2" 2>>"${STEP_LOG:-/dev/null}" ;;
        *) return 1 ;;
    esac
}

fw_del() {
    case $1 in
        ufw)
            have ufw || return 0
            ufw delete allow "$2" >/dev/null 2>&1 || true ;;
        firewalld)
            have firewall-cmd || return 0
            if [[ $(firewall-cmd --state 2>/dev/null || true) == running ]]; then
                firewall-cmd -q --permanent --remove-port="$2" >/dev/null 2>&1 || true
                firewall-cmd -q --remove-port="$2" >/dev/null 2>&1 || true
            elif have firewall-offline-cmd; then
                firewall-offline-cmd -q --remove-port="$2" >/dev/null 2>&1 || return 1
            else
                return 1
            fi ;;
    esac
    return 0
}

fw_wanted() {
    public_ports | awk '{print $2 "/" $1}' | sort -t/ -k1,1n -k2,2 -u
}

fw_sync() {
    local kind r
    local -a old=() keep=() want=()
    kind=$(fw_kind)
    mapfile -t old < <(jq -r '.meta.fw_rules // [] | .[]' "$DRAFT")
    if [[ -n $kind && $(st '.firewall // "auto"') == auto ]]; then mapfile -t want < <(fw_wanted); fi
    for r in "${old[@]}"; do
        [[ -n $r ]] || continue
        if [[ ${r%%:*} == "$kind" ]] && in_list "${r#*:}" "${want[@]}"; then
            fw_has "$kind" "${r#*:}" || fw_add "$kind" "${r#*:}" || true
            keep+=("$r")
            continue
        fi
        if fw_del "${r%%:*}" "${r#*:}"; then printf '%s\n' "$r" >> "$TX/fw-removed"
        else keep+=("$r"); fi
    done
    for r in "${want[@]}"; do
        [[ -n $r ]] || continue
        in_list "$kind:$r" "${keep[@]}" && continue
        fw_has "$kind" "$r" && continue
        if fw_add "$kind" "$r"; then
            keep+=("$kind:$r")
            printf '%s\n' "$kind:$r" >> "$TX/fw-added"
        fi
    done
    st_set .meta.fw_rules "$(printf '%s\n' "${keep[@]}" | jq -R 'select(length > 0)' | jq -cs .)"
}

fw_undo_tx() {
    local r
    if [[ -s $TX/fw-added ]]; then
        while IFS= read -r r; do [[ -z $r ]] || fw_del "${r%%:*}" "${r#*:}"; done < "$TX/fw-added"
    fi
    if [[ -s $TX/fw-removed ]]; then
        while IFS= read -r r; do [[ -z $r ]] || fw_add "${r%%:*}" "${r#*:}" || true; done < "$TX/fw-removed"
    fi
    return 0
}

fw_remove_recorded() {
    local r
    while IFS= read -r r; do
        [[ -z $r ]] || fw_del "${r%%:*}" "${r#*:}" || ui_warn "防火墙规则 $r 没能删除（firewalld 没在运行），请启动 firewalld 后手动删除。"
    done < <(jq -r '.meta.fw_rules // [] | .[]' "$1" 2>/dev/null)
    return 0
}

acquire_lock() {
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
        die '有一次未完成的操作，请重新运行脚本先恢复。' "快照目录：$TX"
        return 1
    fi
    mkdir -p "$TX/backup"
    chmod 700 "$TX"
    : > "$TX/created-dirs"
    local i p s c
    printf '%s\n' "${MANAGED_PATHS[@]}" > "$TX/paths"
    for i in "${!MANAGED_PATHS[@]}"; do
        p=${MANAGED_PATHS[$i]}
        if [[ -e $p || -L $p ]]; then cp -a -- "$p" "$TX/backup/$i"; fi
    done
    : > "$TX/caps"
    if [[ $INIT == openrc ]] && have getcap; then
        for p in "$XRAY_BIN" "$SS_BIN"; do
            [[ -f $p ]] || continue
            c=$(getcap "$p" 2>/dev/null | sed -E 's/^[^ ]+ (= )?//' || true)
            [[ -z $c ]] || printf '%s\t%s\n' "$p" "$c" >> "$TX/caps"
        done
    fi
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
    local -a paths=()
    if [[ -s $TX/paths ]]; then mapfile -t paths < "$TX/paths"; else paths=("${MANAGED_PATHS[@]}"); fi
    for s in "${MANAGED_SERVICES[@]}"; do
        if svc_exists "$s"; then
            svc_do stop "$s" >/dev/null 2>&1 || true
            svc_do disable "$s" >/dev/null 2>&1 || true
        fi
    done
    for i in "${!paths[@]}"; do
        p=${paths[$i]}
        [[ -n $p ]] || continue
        rm -rf -- "$p" || failed=1
        if [[ -e $TX/backup/$i || -L $TX/backup/$i ]]; then
            (umask 022 && mkdir -p -- "$(dirname -- "$p")")
            cp -a -- "$TX/backup/$i" "$p" || failed=1
        fi
    done
    if [[ -s $TX/caps ]] && have setcap; then
        while IFS=$'\t' read -r p s; do
            [[ ! -f $p ]] || setcap "$s" "$p" 2>/dev/null || failed=1
        done < "$TX/caps"
    fi
    if [[ -f $TX/nginx-masked && $INIT == systemd ]]; then systemctl unmask nginx >/dev/null 2>&1 || true; fi
    if [[ -f $TX/pkgs-before ]]; then comm -13 "$TX/pkgs-before" <(pkg_snapshot) >> "$TX/new-packages" 2>/dev/null || true; fi
    svc_reload_units || failed=1
    while read -r s active enabled; do
        [[ -n $s ]] || continue
        if [[ $enabled == 1 ]]; then svc_do enable "$s" >/dev/null 2>&1 || failed=1; fi
        if [[ $active == 1 ]]; then svc_do start "$s" >/dev/null 2>&1 || failed=1; fi
    done < "$TX/services"
    if [[ -s $TX/cc ]]; then sysctl -q -w "net.ipv4.tcp_congestion_control=$(cat "$TX/cc")" >/dev/null 2>&1 || true; fi
    if [[ -s $TX/qdisc ]]; then sysctl -q -w "net.core.default_qdisc=$(cat "$TX/qdisc")" >/dev/null 2>&1 || true; fi
    fw_undo_tx
    if [[ -s $TX/new-packages ]]; then
        local -a pkgs=()
        mapfile -t pkgs < "$TX/new-packages"
        pkg_remove_safe "${pkgs[@]}" >/dev/null 2>&1 || failed=1
    fi
    if [[ -f $TX/created-user ]]; then remove_service_user; fi
    if [[ -s $TX/created-dirs ]]; then remove_created_dirs < "$TX/created-dirs"; fi
    if (( failed )); then
        KEEP_TX=1
        ui_err '没能完全恢复，重新运行脚本会再试一次。'
        ui_note "快照目录：$TX"
        return 1
    fi
    rm -f -- "$TX/ready"
    rm -rf -- "$TX"
    TX_ACTIVE=0
    if state_ok; then ui_line '已恢复到操作前的状态，原有节点照常可用。'; else ui_line '已恢复到操作前的状态。'; fi
}

tx_commit() {
    rm -f -- "$TX/ready"
    rm -rf -- "$TX"
    TX_ACTIVE=0
}

tx_recover_if_needed() {
    [[ -d $TX ]] || return 0
    if [[ ! -f $TX/ready ]]; then
        rm -rf -- "$TX"
        return 0
    fi
    [[ $(cat "$TX/init" 2>/dev/null) == "$INIT" ]] || fatal "快照记录的服务管理方式与当前系统不一致，请手动检查 $TX。"
    ui_warn '上次操作中途被打断，系统可能处于改了一半的状态。'
    if ! ask_yes '现在恢复到那次操作之前的状态'; then
        fatal '需要先完成恢复，才能进行其他操作。'
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
    UI_BUF_ON=0
    case $code in
        130) step_end '已取消' ;;
        143) ui_step_fail; ui_err '操作被中止。' ;;
        *)
            ui_step_fail
            if (( ! DIE_SHOWN )) && [[ ! -e ${STAGE:-/nonexistent}/.died ]]; then
                if [[ $cmd == return* || -z $cmd ]]; then ui_err '操作没有完成。'
                else ui_err "执行出错：$cmd"; fi
                ui_note "位置：${func:-main} 第 $line 行，退出码 $code"
            fi
            show_step_log ;;
    esac
    kill_jobs
    if (( TX_ACTIVE )); then tx_rollback; fi
    [[ -z $STAGE ]] || rm -rf -- "$STAGE"
    exit "$code"
}

on_action_exit() {
    local rc=$?
    [[ $BASHPID == "${ACTION_PID:-$BASHPID}" ]] || exit "$rc"
    trap - EXIT
    set +e
    UI_BUF_ON=0
    if (( rc != 0 )); then ui_step_fail; fi
    kill_jobs
    if (( TX_ACTIVE && ! KEEP_TX )); then tx_rollback; fi
    [[ -z $STAGE ]] || rm -rf -- "$STAGE"
    exit "$rc"
}

kill_jobs() {
    local j
    [[ -z $CHECK_PID ]] || kill "$CHECK_PID" 2>/dev/null || true
    for j in $(jobs -p); do kill "$j" 2>/dev/null || true; done
    return 0
}

show_step_log() {
    [[ -n $STEP_LOG && -s $STEP_LOG ]] || return 0
    local l
    printf '  %s相关日志：%s\n' "$C_DIM" "$C_RESET" >&5
    while IFS= read -r l; do
        [[ -n ${l//[[:space:]]/} ]] || continue
        printf '  %s|%s %s\n' "$C_DIM" "$C_RESET" "$l" >&5
    done < <(tail -n 15 "$STEP_LOG")
}

run_action() (
    set -Eeuo pipefail
    ACTION_PID=$BASHPID
    trap 'on_action_error $? $LINENO "${FUNCNAME[0]:-}" "$BASH_COMMAND"' ERR
    trap 'on_action_error 130 $LINENO' INT
    trap 'on_action_error 143 $LINENO' TERM HUP
    trap 'TUI_RESIZED=1' WINCH
    trap on_action_exit EXIT
    make_dir "$(dirname -- "$STAGE_BASE")"
    STAGE=$(mktemp -d "$STAGE_BASE.XXXXXXXX")
    STEP_LOG=$STAGE/step.log
    : > "$STEP_LOG"
    "$@" 2>> "$STEP_LOG"
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

latest_tag_try() {
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
    [[ $tag =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    printf '%s' "$tag"
}

xray_newest_tag() {
    local now json tag='' upd t ts
    local -a settled=()
    now=$(date +%s)
    json=$(curl --proto '=https' -fsSL --connect-timeout 10 --max-time 30 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=30" 2>>"${STEP_LOG:-/dev/null}" || true)
    if [[ -n $json ]]; then
        tag=$(jq -r --argjson now "$now" --argjson d "$XRAY_SETTLE_DAYS" '
            [.[] | select((.draft | not) and (.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")))
                 | select(((.published_at // "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) <= ($now - $d * 86400))
                 | .tag_name]
            | sort_by(ltrimstr("v") | split(".") | map(tonumber)) | last // empty' <<< "$json" 2>/dev/null || true)
    fi
    if [[ -z $tag ]]; then
        while read -r upd t; do
            [[ $t =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
            ts=$(jq -rn --arg u "$upd" '$u | sub("\\.[0-9]+"; "") | sub("[+]00:00$"; "Z") | fromdateiso8601' 2>/dev/null || echo "$now")
            (( ts <= now - XRAY_SETTLE_DAYS * 86400 )) && settled+=("$t")
        done <<< "$(curl --proto '=https' -fsSL --connect-timeout 10 --max-time 30 \
            https://github.com/XTLS/Xray-core/releases.atom 2>>"${STEP_LOG:-/dev/null}" | awk '
            /<entry>/ { u = ""; t = "" }
            /<updated>/ { line = $0; gsub(/.*<updated>|<\/updated>.*/, "", line); u = line }
            /releases\/tag\// { if (match($0, /releases\/tag\/[^"]+/)) t = substr($0, RSTART + 13, RLENGTH - 13) }
            /<\/entry>/ { if (u != "" && t != "") print u, t }' || true)"
        (( ${#settled[@]} == 0 )) || tag=$(printf '%s\n' "${settled[@]}" | sort -V | tail -n 1)
    fi
    [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s' "$tag"
}

xray_resolve_tag() {
    case $1 in
        compat) printf '%s' "$XRAY_COMPAT_VERSION" ;;
        latest) xray_newest_tag || { die '查不到 Xray 的最新版本，请检查本机能否访问 GitHub。'; return 1; } ;;
        *) printf '%s' "$(normalize_tag "$1")" ;;
    esac
}

latest_tag() {
    local t
    t=$(latest_tag_try "$1") || { die "无法获取 $1 的最新版本号，请检查本机能否访问 GitHub。"; return 1; }
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
    if [[ $tag == latest || $tag == compat ]]; then tag=$(xray_resolve_tag "$tag"); fi
    base=https://github.com/XTLS/Xray-core/releases/download/$tag
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
    curl --proto '=https' --tlsv1.2 -fLsS --retry 2 --connect-timeout 10 --max-time 60 \
        -o "$out" "$SCRIPT_REMOTE_URL" >> "$STEP_LOG" 2>&1 || return 1
    grep -q "$SCRIPT_MARKER" "$out" || return 2
    bash -n "$out" 2>>"$STEP_LOG" || return 3
    [[ -n $(script_version_of "$out") ]] || return 3
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

port_foreign() {
    local rows pid
    rows=$(listeners "$1" "$2")
    [[ -n $rows ]] || return 1
    while read -r pid; do
        [[ -n $pid ]] || continue
        pid_is_owned "$pid" || return 0
    done <<< "$(grep -oE 'pid=[0-9]+' <<< "$rows" | cut -d= -f2 || true)"
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
    local d f
    local -a pool=()
    f=$(sni_pool_file)
    if [[ -f $f ]]; then
        while IFS= read -r d; do
            d=${d%%#*}
            d=${d//[[:space:]]/}
            [[ -n $d ]] || continue
            if valid_domain "$d"; then pool+=("${d,,}"); fi
        done < "$f"
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

sni_probe_job() {
    local d=$1 out=$2 i t1 t2
    for i in 1 2 3; do
        t1=$(now_ms)
        if sni_probe "$d" "$out.log"; then
            t2=$(now_ms)
            printf '%s\n' $(( t2 - t1 )) >> "$out.ms"
        fi
    done
    : > "$out.done"
}

sni_auto_select() {
    local __sa_out=$1 __sa_dir __sa_i __sa_total __sa_done __sa_best='' __sa_bscore=999999999 __sa_score __sa_ms __sa_ok
    local -a __sa_pool=() __sa_pids=() __sa_sorted=()
    mapfile -t __sa_pool < <(sni_pool)
    __sa_total=${#__sa_pool[@]}
    __sa_dir=$STAGE/sni-test
    tty_echo -echo
    rm -rf -- "$__sa_dir"
    mkdir -p -- "$__sa_dir"
    for __sa_i in "${!__sa_pool[@]}"; do
        sni_probe_job "${__sa_pool[$__sa_i]}" "$__sa_dir/$__sa_i" 3>&- 4>&- 9>&- &
        __sa_pids+=("$!")
    done
    while :; do
        __sa_done=$(find "$__sa_dir" -name '*.done' 2>/dev/null | wc -l)
        if [[ -t 4 ]]; then printf '\r  正在测速伪装站点 %d/%d ...' "$__sa_done" "$__sa_total" >&4; fi
        (( __sa_done < __sa_total )) || break
        sleep 0.3
    done
    wait "${__sa_pids[@]}" 2>/dev/null || true
    if [[ -t 4 ]]; then printf '\r%*s\r' "$UI_W" '' >&4; fi
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
        query=${main#*\?}
        main=${main%%\?*}
        local qv
        qv=$(query_get "$query" plugin || true)
        [[ -z $qv ]] || { PARSE_ERR='不支持带插件（plugin）的 SS 链接'; return 1; }
        qv=$(query_get "$query" type || true)
        case $qv in ''|tcp|raw) ;; *) PARSE_ERR="只支持 TCP 类型的 SS 落地（当前 $qv）"; return 1 ;; esac
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
    local method=${creds%%:*} password=${creds#*:} klen=0 key
    case $method in
        2022-blake3-aes-128-gcm) klen=16 ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) klen=32 ;;
        aes-128-gcm|aes-256-gcm|chacha20-poly1305|chacha20-ietf-poly1305|xchacha20-poly1305|xchacha20-ietf-poly1305) ;;
        *) PARSE_ERR="Xray 不支持这种加密方式：$method"; return 1 ;;
    esac
    if (( klen )); then
        local -a keys=()
        IFS=: read -r -a keys <<< "$password"
        for key in "${keys[@]}"; do
            if [[ $key =~ ^[A-Za-z0-9+/]+={0,2}$ ]] && (( ${#key} % 4 == 0 )) \
                && [[ $(printf '%s' "$key" | base64 -d 2>/dev/null | wc -c) == "$klen" ]]; then continue; fi
            PARSE_ERR="$method 的密码应是 $klen 字节密钥的 Base64，这个链接的密码不对"
            return 1
        done
    fi
    PARSED_KIND=ss
    PARSED_LABEL=$(uri_decode "$frag" 2>/dev/null || true)
    PARSED_LABEL=${PARSED_LABEL//[[:cntrl:]]/}
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
    case $flow in
        '') ;;
        xtls-rprx-vision|xtls-rprx-vision-udp443)
            [[ $security == reality || $encryption != none ]] || { PARSE_ERR='flow 只能配合 REALITY 或 VLESS-ENC 使用'; return 1; } ;;
        *) PARSE_ERR="暂不支持的 flow：$flow"; return 1 ;;
    esac
    local stream
    if [[ $security == reality ]]; then
        [[ -n $sni && -n $pbk ]] || { PARSE_ERR='REALITY 落地缺少 sni 或 pbk'; return 1; }
        valid_domain "$sni" || { PARSE_ERR="sni 不是合法的域名：$sni"; return 1; }
        [[ $pbk =~ ^[A-Za-z0-9_-]{43}$ ]] || { PARSE_ERR='pbk 格式不对'; return 1; }
        [[ -z $sid || ( $sid =~ ^[0-9a-fA-F]{2,16}$ && $(( ${#sid} % 2 )) == 0 ) ]] || { PARSE_ERR='sid 应是 2-16 位十六进制'; return 1; }
        [[ -n $fp ]] || fp=chrome
        case $fp in
            chrome|firefox|safari|ios|android|edge|360|qq|random|randomized|randomizednoalpn) ;;
            *) PARSE_ERR="不认识的指纹：$fp"; return 1 ;;
        esac
        stream=$(jq -cn --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg fp "$fp" \
            '{network:"raw", security:"reality",
              realitySettings:({serverName:$sni, publicKey:$pbk, fingerprint:$fp, spiderX:"/"}
                + (if $sid == "" then {} else {shortId:$sid} end))}')
    else
        stream='{"network":"raw"}'
    fi
    PARSED_KIND=vless
    PARSED_LABEL=$(uri_decode "$frag" 2>/dev/null || true)
    PARSED_LABEL=${PARSED_LABEL//[[:cntrl:]]/}
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
    jq -r '.users[] | select((.port // 0) > 0) | "tcp \(.port) 落地\(.name | ltrimstr("landing"))"' "$DRAFT"
    if [[ $s == ss ]]; then jq -r '.users[] | select((.port // 0) > 0) | "udp \(.port) 落地\(.name | ltrimstr("landing"))"' "$DRAFT"; fi
}


draft_new() {
    local s=$1
    PREVIEW_NOTES=()
    jq -n --arg s "$s" --arg v4 "$NET_V4" --arg v6 "$NET_V6" --argjson schema "$STATE_SCHEMA" \
        --arg name "$(default_node_name)" --argjson jitter "$(limit_jitter_new)" '{
        schema: $schema, scheme: $s, name: $name, script: "", installed_at: "",
        net: {host: (if $v4 != "" then $v4 elif $v6 != "" then $v6 else "" end), v4: $v4, v6: $v6, manual: 0, v6_link: 1},
        outbound: (if $v4 == "" and $v6 != "" then "v6first" else "v4first" end),
        bbr: 1, firewall: "auto",
        core: {xray: "compat", ss: "latest"},
        reality: {port: 0, internal: 0, gate: 0, sni: "", sni_auto: 1, private_key: "", public_key: "", short_id: "",
                  fp: "chrome", guard: "nginx", limit: "orig", limit_custom: {ua: 8192, ur: 1024, da: 32768, dr: 2048},
                  limit_jitter: $jitter, conn_ip: 256, conn_total: 4096},
        xhttp: {path: "", xmux: null, enc: 0, split: "v6_up_v4_down"},
        enc: {port: 0, rtt: "0rtt", shape: "random", auth: "x25519", ticket: "600s", pad: "off",
              pad_client: "", pad_server: "", server_key: "", client_key: ""},
        ss: {port: 0, method: "2022-blake3-aes-128-gcm", password: ""},
        users: [{name: "direct", id: "", out: "direct"}],
        landings: [],
        meta: {nginx_packages: [], nginx_hash: "", created_user: 0, selinux_note: 0, fw_rules: [], extra_packages: []}
    }' > "$DRAFT"
    local p
    PORT_NOTE=''
    if scheme_has_reality "$s"; then
        p=443
        if port_taken tcp 443; then
            p=$(random_free_port)
            if [[ $s == triple ]]; then note_add "TCP 443 被 $(port_owner_label tcp 443) 占用，REALITY 改用随机端口 $p。"
            else PORT_NOTE="443 已被 $(port_owner_label tcp 443) 占用"; fi
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
    local base
    case $1 in
        orig) base='8192 1024 32768 2048' ;;
        std) base='262144 32768 1048576 65536' ;;
    esac
    jq -r --arg b "$base" '(.reality.limit_jitter // [100,100,100,100]) as $j | ($b | split(" ") | map(tonumber)) as $v
        | [range(0; 4) | ($v[.] * $j[.] / 100 | floor | tostring)] | join(" ")' "$DRAFT"
}

limit_values() {
    case $(st .reality.limit) in
        orig|std) limit_preset "$(st .reality.limit)" ;;
        custom) jq -r '.reality.limit_custom | "\(.ua) \(.ur) \(.da) \(.dr)"' "$DRAFT" ;;
    esac
}

limit_label() {
    case $(st .reality.limit) in
        orig) printf '严格' ;; std) printf '宽松' ;; custom) printf '自定义' ;;
    esac
}

limit_text() {
    local -a lv=()
    read -r -a lv <<< "${1:-$(limit_values)}"
    printf '上行 %s 后 %s/s\n下行 %s 后 %s/s' "$(human_bytes "${lv[0]}")" "$(human_bytes "${lv[1]}")" \
        "$(human_bytes "${lv[2]}")" "$(human_bytes "${lv[3]}")"
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
        compat) printf '兼容版 %s' "$XRAY_COMPAT_VERSION" ;;
        latest)
            [[ $(jq -r ".core.$1 // empty" "$STATE" 2>/dev/null) == latest ]] || iv=''
            if [[ -n $iv ]]; then printf '最新版 %s' "$iv"; else printf '最新版'; fi ;;
        *) printf '%s 固定' "$v" ;;
    esac
}

system_summary() {
    local -a o=("$(outbound_label "$(st .outbound)")")
    if [[ $(st .bbr) == 1 ]]; then o+=('BBR 开'); else o+=('BBR 关'); fi
    if scheme_has_reality "$(scheme)"; then o+=("指纹 $(st .reality.fp)"); fi
    join_by '，' "${o[@]}"
    if needs_xray; then printf '\nXray %s' "$(core_label xray)"; fi
    if needs_ss_rust; then printf '\nSS-Rust %s' "$(core_label ss)"; fi
}

node_name() { st '.name // "zxray"'; }

default_node_name() {
    local h
    h=$(hostname -s 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || true)
    h=${h%%.*}
    [[ $h =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,23}$ && $h != localhost* ]] || h=zxray
    printf '%s' "$h"
}

valid_node_name() {
    local w
    [[ -n $1 && $1 != *[[:space:]#?\&/\\%\"\']* ]] || return 1
    str_width "$1" w
    (( w <= 24 ))
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

v6_links_on() {
    [[ -n $(st .net.v6) && $(st '.net.v6_link // 1') == 1 && $(st .net.host) == "$(st .net.v4)" ]]
}

note_add() { PREVIEW_NOTES+=("$1"); }


CS_DEF=1 CS_MARK=0
PV_KEYS=()
declare -A PV_ORIG=() PV_FP=()

cs_build() {
    local i
    local -a name=('RAW + Vision' 'XHTTP 单路' 'XHTTP 上下行分离' 'SS2022' 'VLESS-ENC'
        'SS2022 + VLESS-ENC' 'REALITY + SS + ENC' 'XHTTP + ENC 分离')
    local -a note=('推荐，各种客户端都能用' '可选 XMUX；sing-box 不支持' '需要双栈；sing-box 不支持'
        '客户端支持最广' '抗量子握手；sing-box 不支持' '两个入口，各给一条链接' '三个入口，各给一条链接'
        '需要双栈；sing-box 不支持')
    local -a group=([0]='REALITY：借用伪装站点的 TLS 握手' [3]='不需要伪装站点' [5]='多入口组合' [7]='实验')
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
    local s
    s=$(scheme)
    printf '%s\n' @基本 port
    if scheme_has_reality "$s"; then printf '%s\n' sni; fi
    printf '%s\n' addr name
    case $s in dual|triple|enc-split) ;; *) printf '%s\n' landings ;; esac
    case $s in
        reality-xhttp) printf '%s\n' @传输 xhttp ;;
        reality-split|enc-split) printf '%s\n' @传输 split ;;
    esac
    if scheme_has_ss "$s" || scheme_has_enc_inbound "$s"; then
        printf '%s\n' @加密
        if scheme_has_ss "$s"; then printf '%s\n' ssm; fi
        if scheme_has_enc_inbound "$s"; then printf '%s\n' encp; fi
    fi
    if scheme_has_reality "$s"; then
        printf '%s\n' @防护 guard
        if [[ $(st .reality.guard) == nginx ]]; then printf '%s\n' conn; fi
        printf '%s\n' limit
    fi
    printf '%s\n' @高级 system
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
        system) printf '高级设置' ;;
    esac
}

item_help() {
    case $1 in
        port) printf '%s\n%s' '客户端连接用的端口。' '改了以后，客户端要重新导入节点。' ;;
        sni) printf '%s\n%s' 'REALITY 借用这个网站的 TLS 握手，不合法的连接会转给它。' '更换后，客户端要重新导入节点。' ;;
        addr) printf '%s' '写进节点链接的服务器地址：本机 IP，或解析到本机的域名。' ;;
        name) printf '%s' '显示在客户端节点列表里，用来区分不同的服务器。' ;;
        landings) printf '%s\n%s' '默认从本机直接出去。每添加一个落地，会多一条节点链接，' '用它的流量改从落地服务器出去。' ;;
        xhttp) printf '%s' 'XHTTP 的路径、连接复用（XMUX），以及可叠加的 VLESS 加密。' ;;
        split) printf '%s' '上传和下载分别走本机的 IPv4 和 IPv6。' ;;
        ssm) printf '%s' 'SS2022 的加密方式。更换会生成新密码。' ;;
        encp) printf '%s' 'VLESS 加密的握手方式、认证方式、外观和填充。' ;;
        guard) printf '%s\n%s' 'SNI 不是伪装站点的连接直接断开，' '防止服务器被当成访问任意网站的跳板。' ;;
        conn) printf '%s' 'Nginx 在验证之前限制并发连接，超出的直接断开。' ;;
        limit) printf '%s\n%s' '被转给伪装站点的流量，传到一定量后限速，防止被偷流量。' '数值在预设附近随机微调，每台服务器都不一样。' ;;
        system) printf '%s' '出站 IP、BBR、TLS 指纹、IPv6 链接、防火墙和核心版本。' ;;
    esac
}

item_value() {
    local s v n note
    s=$(scheme)
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
            if (( n == 0 )); then printf '本机直连'
            else
                printf '本机直连 + %d 个落地' "$n"
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
        limit) printf '%s\n' "$(limit_label)"; limit_text | sed 's/^/\t/' ;;
        system) system_summary ;;
    esac
}

same_item() {
    local a=$2 b=$3
    if [[ $1 == sni ]]; then first_value "$2" a; first_value "$3" b; fi
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
    local src=${1:-$DRAFT} saved=$DRAFT key
    local -a rows=()
    PV_ORIG=() PV_FP=()
    DRAFT=$src
    mapfile -t rows < <(preview_items)
    for key in "${rows[@]}"; do
        [[ $key != @* ]] || continue
        PV_ORIG[$key]=$(item_value "$key")
        PV_FP[$key]=$(item_fp "$key")
    done
    DRAFT=$saved
    cp -f -- "$src" "$STAGE/pv-base.json"
}

link_fields() {
    jq -S -c '{scheme, name, net: (.net | {host, v4, v6}),
        reality: (.reality | {port, sni, fp, public_key, short_id}), xhttp, enc: (.enc | del(.ticket)), ss,
        v6_link: (if .net.host == .net.v4 and (.net.v6 // "") != "" then (.net.v6_link // 1) else null end),
        users: [.users[] | {name, id, port}], landings: [.landings[] | .tag]}' "$1"
}

links_will_change() {
    [[ -f $STAGE/pv-base.json ]] || return 0
    [[ $(link_fields "$STAGE/pv-base.json") != "$(link_fields "$DRAFT")" ]]
}

item_fp() {
    local f
    case $1 in
        port) f='[.reality.port, .ss.port, .enc.port, [.users[] | .port // 0]]' ;;
        sni) f='[.reality.sni]' ;;
        addr) f='[.net.host, .net.v4, .net.v6]' ;;
        name) f='[.name]' ;;
        landings) f='[.landings, [.users[] | {name, out}]]' ;;
        xhttp) f='[.xhttp, (if .xhttp.enc == 1 then (.enc | del(.port)) else null end)]' ;;
        split) f='[.xhttp]' ;;
        ssm) f='[.ss.method, .ss.password, [.users[] | .id]]' ;;
        encp) f='[.enc | del(.port)]' ;;
        guard) f='[.reality.guard]' ;;
        conn) f='[.reality.conn_ip, .reality.conn_total]' ;;
        limit) f='[.reality.limit, .reality.limit_custom, .reality.limit_jitter]' ;;
        system) f='[.outbound, .bbr, .reality.fp, .net.v6_link, .firewall, .core]' ;;
        *) f='null' ;;
    esac
    jq -c "$f" "$DRAFT"
}

item_changed() {
    [[ -n ${PV_ORIG[$1]+x} ]] || return 1
    ! same_item "$1" "$2" "${PV_ORIG[$1]}" || [[ $(item_fp "$1") != "${PV_FP[$1]:-}" ]]
}

pv_changed_count() {
    local key n=0
    for key in "${PV_KEYS[@]}"; do
        item_changed "$key" "$(item_value "$key")" && n=$(( n + 1 ))
    done
    printf '%d' "$n"
}

pv_build() {
    local key v note n=0 i full orig
    local -a rows=() vals=() olds=() marks=()
    mapfile -t rows < <(preview_items)
    for key in "${rows[@]}"; do [[ $key == @* ]] || n=$(( n + 1 )); done
    if [[ $MODE == modify ]]; then ui_page '当前配置' "$(scheme_label "$(scheme)")"
    else ui_page '预览' "$(scheme_label "$(scheme)")"; fi
    KEY_W=${#n}
    PV_KEYS=()
    for key in "${rows[@]}"; do
        if [[ $key == @* ]]; then ui_group "${key#@}"; continue; fi
        PV_KEYS+=("$key")
        full=$(item_value "$key")
        mapfile -t vals <<< "$full"
        olds=() marks=()
        if [[ $MODE == modify ]] && item_changed "$key" "$full"; then
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
                if [[ ${marks[$i]} == 2 ]]; then note='细节参数有改动'
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
        i=$(pv_changed_count)
        if (( i > 0 )); then v="已改 $i 项"; else v='还没有修改'; fi
        tui_item a '应用修改' '' "$v" '把上面的设置写入服务器并重启服务，应用前会再确认一次。'
        tui_item c '换方案' '' '重新选择方案，会生成全新的节点' '换成别的方案，现有节点会全部失效。'
        TUI_FOOT_PLAIN="1-$n 修改   a 应用修改   c 换方案   0 返回"
    else
        tui_item y '开始安装' '' '确认无误后开始部署' '下载核心、生成配置并启动服务，大约需要一分钟。'
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
    if scheme_is_split "$s" && [[ -z $(st .net.v4) || -z $(st .net.v6) ]]; then
        ui_warn '上下行分离需要填写本机的 IPv4 和 IPv6 地址。'
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
    local key cur o v n=0 lab m i shown
    local -a ol=() nl=()
    ui_page "$PC_TITLE" "$(scheme_label "$(scheme)")"
    if [[ $(jq -r .scheme "$STAGE/pv-base.json") != "$(scheme)" ]]; then
        ui_kv '方案' "$(scheme_label "$(jq -r .scheme "$STAGE/pv-base.json")") -> $(scheme_label "$(scheme)")"
        n=1
    else
        for key in "${PV_KEYS[@]}"; do
            cur=$(item_value "$key")
            item_changed "$key" "$cur" || continue
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
            (( shown )) || ui_kv "$lab" "${C_YELLOW}已修改$C_RESET" '细节参数有改动'
        done
    fi
    if (( n == 0 )); then ui_line '没有修改，会按当前设置重新生成配置并重启服务。'; fi
    ui_blank
    if links_will_change; then ui_warn '应用后节点链接会变，客户端需要重新导入。'
    else ui_ok '节点链接不变，客户端不用改动。'; fi
    if scheme_has_reality "$(scheme)" && core_breaks_singbox "$(st .core.xray)" \
        && ! core_breaks_singbox "$(jq -r '.core.xray // "compat"' "$STAGE/pv-base.json")"; then
        ui_warn '换用新核心后，sing-box 内核的客户端会连不上 REALITY。'
    fi
    ui_rule
    tui_item 1 "$PC_TITLE" '' '写入配置并重启服务'
    tui_item 2 '再看看' '' '回到上一页'
    TUI_FOOT='上下键 移动   回车 确认   Esc 返回'
    TUI_FOOT_PLAIN="1 $PC_TITLE   2 再看看"
}

core_breaks_singbox() {
    case $1 in
        compat) return 1 ;;
        latest) return 0 ;;
        *) ver_ge "${1#v}" "$XRAY_MLKEM_VERSION" ;;
    esac
}

pc_row() {
    local w
    str_width "$2 -> $3" w
    if (( w <= UI_W - 2 - LABEL_W )); then
        ui_kv "$1" "$C_DIM$2$C_RESET -> $C_YELLOW$3$C_RESET"
    else
        ui_kv "$1" "$C_DIM原 $2$C_RESET"
        ui_kv '' "$C_YELLOW改为 $3$C_RESET"
    fi
}

pv_confirm() {
    PC_TITLE=${1:-应用修改}
    tui_menu pc_build 0 ''
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
                confirm_discard '有修改还没应用，确定放弃' || continue
                draft_watch_stop
                PREVIEW_RESULT=1
                return 0 ;;
            ENTER)
                key=${TUI_IKEYS[$TUI_CUR]}
                case $key in
                    y|a)
                        preview_ready || continue
                        if [[ $MODE == modify ]]; then pv_confirm || continue; fi
                        draft_watch_stop
                        PREVIEW_RESULT=0
                        return 0 ;;
                    c)
                        confirm_discard '有修改还没应用，换方案会放弃这些修改，确定' || continue
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
    ask_no "$1，客户端要重新导入节点。确定"
}

input_page() {
    local title=$1 sub=$2 hint=$3
    shift 3
    ui_page "$title" "$sub"
    [[ -z $hint ]] || ui_hint "$hint"
    ui_blank
    while (( $# >= 2 )); do
        ui_kv "$1" "$2"
        shift 2
    done
    if (( TUI )); then ui_footer '回车 确认，原样回车就是不改'
    else ui_footer '回车 不改'; fi
}


ask_port() {
    local __ap_cur=$1 __ap_proto=$2 __ap_p __ap_x __ap_busy
    while :; do
        read_line '新端口：' __ap_p "$__ap_cur"
        [[ -n $__ap_p && $__ap_p != "$__ap_cur" ]] || { printf -v "$3" '%s' "$__ap_cur"; return 0; }
        if [[ $__ap_p == r || $__ap_p == R ]]; then
            __ap_p=$(random_free_port)
            ui_note "随机选到 $__ap_p"
        fi
        if ! valid_port "$__ap_p"; then ui_warn '端口需在 1-65535 之间。'; continue; fi
        __ap_p=$(( 10#$__ap_p ))
        if [[ $__ap_p != "$__ap_cur" ]] && port_in_draft "$__ap_p"; then
            ui_warn "端口 $__ap_p 已经被本方案的其他入口用了。"
            continue
        fi
        __ap_busy=''
        for __ap_x in tcp udp; do
            [[ $__ap_proto == both || $__ap_proto == "$__ap_x" ]] || continue
            if port_taken "$__ap_x" "$__ap_p"; then __ap_busy=$__ap_x; break; fi
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
        option_page k 0 '端口' '这个方案有多个入口，选择要修改的一个。' "${opts[@]}"
        [[ -n $k ]] || return 0
        idx=$(( k - 1 ))
    fi
    [[ ${keys[$idx]} != .ss.port && ${keys[$idx]} != .users* ]] || proto=both
    cur=$(st "${keys[$idx]}")
    if [[ $proto == both ]]; then hint='客户端连接用的端口，TCP 和 UDP 都会用到。'
    else hint='客户端连接用的 TCP 端口。'; fi
    [[ $MODE != modify ]] || hint+=$'\n改了以后，客户端里这个节点的端口也要跟着改。'
    input_page '端口' "${labels[$idx]}" "$hint" '当前' "$cur" '可以填' '1-65535，或输入 r 随机选一个空闲端口'
    ask_port "$cur" "$proto" p
    [[ $p != "$cur" ]] || return 0
    st_set "${keys[$idx]}" "$p"
    [[ ${keys[$idx]} != .reality.port ]] || PORT_NOTE=''
}

edit_sni() {
    local c d cur
    cur=$(st .reality.sni)
    option_page c 0 '伪装站点' $'REALITY 借用这个网站的 TLS 握手，不合法的连接会转给它。\n要求支持 TLS 1.3 和 HTTP/2，离本机越近越好。' \
        '自动挑选|同时测速候选站点，选最快的可用站点' '手动输入|填写一个指定的域名' '候选列表|查看或修改自动挑选用的站点'
    case $c in
        1)
            confirm_identity_change '更换伪装站点' || return 0
            ui_blank
            if sni_auto_select d; then
                st_sets .reality.sni "$d"
                st_set .reality.sni_auto 1
            else
                ui_warn '候选列表里没有可用的站点，请手动输入。'
                ui_pause
            fi ;;
        2)
            confirm_identity_change '更换伪装站点' || return 0
            input_page '伪装站点' '手动输入' '只填域名，例如 www.example.com，不带 https:// 和路径。' '当前' "${cur:-未选择}"
            while :; do
                read_line '域名：' d "$cur"
                [[ -n $d && $d != "$cur" ]] || return 0
                d=${d,,}
                if ! valid_domain "$d"; then ui_warn '只填域名，例如 www.example.com，不带 https:// 和路径。'; continue; fi
                ui_note "正在检测 $d ..."
                if sni_probe "$d" "$STAGE/sni-manual.log"; then
                    st_sets .reality.sni "$d"
                    st_set .reality.sni_auto 0
                    return 0
                fi
                ui_warn "$d 不满足要求（TLS 1.3、HTTP/2、证书有效），请换一个。"
            done ;;
        3) edit_sni_pool ;;
    esac
}

edit_addr() {
    local c v cur=0 host i
    local -a opts=() vals=()
    if scheme_is_split "$(scheme)"; then
        input_page '节点地址' '上下行分离' '上传和下载分别连本机的 IPv4 和 IPv6 地址。' \
            'IPv4' "$(st .net.v4 | grep . || printf '未填写')" 'IPv6' "$(st .net.v6 | grep . || printf '未填写')"
        while :; do
            read_line 'IPv4：' v "$(st .net.v4)"
            [[ -n $v && $v != "$(st .net.v4)" ]] || break
            if valid_ipv4 "$v"; then st_sets .net.v4 "$v"; st_set .net.manual 1; break; fi
            ui_warn 'IPv4 格式不正确。'
        done
        while :; do
            read_line 'IPv6：' v "$(st .net.v6)"
            [[ -n $v && $v != "$(st .net.v6)" ]] || break
            if valid_ipv6 "$v"; then st_sets .net.v6 "$v"; st_set .net.manual 1; break; fi
            ui_warn 'IPv6 格式不正确。'
        done
        return 0
    fi
    host=$(st .net.host)
    if [[ -n $NET_V4 ]]; then opts+=("IPv4|$NET_V4"); vals+=("$NET_V4"); fi
    if [[ -n $NET_V6 ]]; then opts+=("IPv6|$NET_V6"); vals+=("$NET_V6"); fi
    for i in "${!vals[@]}"; do [[ ${vals[$i]} != "$host" ]] || cur=$(( i + 1 )); done
    if (( cur == 0 )) && [[ -n $host ]]; then opts+=("自定义|$host"); vals+=("$host"); cur=${#vals[@]}; fi
    opts+=('输入新地址|域名或 IP')
    option_page c "$cur" '节点地址' '写进节点链接的服务器地址：本机 IP，或解析到本机的域名。' "${opts[@]}"
    [[ -n $c && $c != "$cur" ]] || return 0
    if (( c <= ${#vals[@]} )); then st_sets .net.host "${vals[$((c - 1))]}"; return 0; fi
    input_page '节点地址' '输入新地址' '填写域名、IPv4 或 IPv6 地址。域名要已经解析到本机。' '当前' "${host:-未填写}"
    while :; do
        read_line '域名或 IP：' v "$host"
        [[ -n $v && $v != "$host" ]] || return 0
        if valid_host "$v"; then st_sets .net.host "${v,,}"; return 0; fi
        ui_warn '格式不正确，请填写域名、IPv4 或 IPv6 地址。'
    done
}

edit_name() {
    local v cur
    cur=$(node_name)
    input_page '节点名称' '' $'显示在客户端节点列表里，有多台服务器时用来区分。\n可以用中文、字母、数字和横线，最长 24 个字符宽。' \
        '当前' "$cur" '链接名称' "$(name_example | sed 's/^链接里显示为 //')"
    while :; do
        read_line '新名称：' v "$cur"
        [[ -n $v && $v != "$cur" ]] || return 0
        if valid_node_name "$v"; then st_sets .name "$v"; return 0; fi
        ui_warn '名称不能有空格和 # ? & / \ % 引号，最长 24 个字符宽。'
    done
}

next_landing_index() {
    jq '[.landings[].tag | ltrimstr("landing") | tonumber] | (max // 0) + 1' "$DRAFT"
}

ld_build() {
    local n i tag
    n=$(jq '.landings | length' "$DRAFT")
    ui_page '出口'
    ui_hint $'默认所有流量从本机直接访问网站。每添加一个落地，\n会多生成一条节点链接，用它的流量改从落地服务器出去。'
    ui_blank
    KEY_W=${#n}
    ui_item '' '直出' '本机' '默认出口'
    for (( i = 0; i < n; i++ )); do
        tag=$(jq -r ".landings[$i].tag" "$DRAFT")
        tui_item "${tag#landing}" "$(landing_label "$tag")" \
            "$(jq -r ".landings[$i] | \"\(.kind) \(.host):\(.port)\"" "$DRAFT")" \
            "$(jq -r ".landings[$i].label // \"\"" "$DRAFT")" '回车可以删除这个落地。'
    done
    ui_blank
    tui_item a '添加落地' '' 'ss:// 或 vless:// 链接' '支持 ss:// 和 vless://（TCP，无加密或 REALITY）。'
    TUI_HELP_H=1
    TUI_FOOT='上下键 移动   回车 选择   Esc 返回'
    if (( n > 0 )); then TUI_FOOT_PLAIN='a 添加落地   落地编号 删除   回车 返回'
    else TUI_FOOT_PLAIN='a 添加落地   回车 返回'; fi
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
            if (( n >= 10 )); then TUI_MSG='最多添加 10 个落地。'; (( TUI )) || ui_warn "$TUI_MSG"; continue; fi
            input_page '添加落地' '' $'粘贴落地服务器的分享链接。\n支持 ss:// 和 vless://（TCP，无加密或 REALITY）。'
            while :; do
                read_line '落地链接（回车取消）：' link
                [[ -n $link ]] || break
                if parse_landing_link "$link"; then
                    add_landing "$(normalize_link "$link")"
                    break
                fi
                ui_warn "这个链接用不了：$PARSE_ERR"
            done
        else
            tag="landing$key"
            ask_no "删除$(landing_label "$tag")（$(jq -r --arg t "$tag" '.landings[] | select(.tag == $t) | "\(.host):\(.port)"' "$DRAFT")）" || continue
            st_filter --arg t "$tag" '.landings |= map(select(.tag != $t)) | .users |= map(select(.out != $t))'
            cur=0
        fi
    done
}

add_landing() {
    local link=$1 idx tag port=0
    idx=$(next_landing_index)
    tag="landing$idx"
    if [[ $(scheme) == ss ]]; then port=$(random_free_port); fi
    st_filter --arg tag "$tag" --arg link "$link" --argjson ob "$PARSED_OUTBOUND_JSON" --arg kind "$PARSED_KIND" \
        --arg host "$PARSED_HOST" --argjson port "$PARSED_PORT" --arg label "$PARSED_LABEL" --argjson up "$port" \
        '.landings += [{tag:$tag, link:$link, outbound:$ob, kind:$kind, host:$host, port:$port, label:$label}]
         | .users += [{name:$tag, id:"", out:$tag} + (if $up > 0 then {port:$up} else {} end)]'
}

edit_path() {
    local p cur hint='客户端请求用的路径，相当于一个暗号。'
    cur=$(st .xhttp.path)
    [[ $MODE != modify ]] || hint+=$'\n改了以后，客户端需要重新导入节点。'
    input_page 'XHTTP 路径' '' "$hint" '当前' "$cur" '可以填' '以 / 开头，字母、数字和 . _ - /，最长 64 位'
    while :; do
        read_line '新路径：' p "$cur"
        [[ -n $p && $p != "$cur" ]] || return 0
        if [[ $p =~ ^/[A-Za-z0-9._/-]{1,63}$ ]]; then st_sets .xhttp.path "$p"; return 0; fi
        ui_warn '格式不对：以 / 开头，只用字母、数字和 . _ - /'
    done
}

xh_build() {
    local v
    ui_page 'XHTTP 传输'
    tui_item 1 '路径' "$(st .xhttp.path)" '' '客户端请求用的路径，相当于一个暗号。'
    tui_item 2 'XMUX' "$(xmux_label)" '客户端复用连接的方式' '控制客户端怎样复用连接，参数写进节点链接，只在客户端生效。'
    if [[ $(st .xhttp.enc) == 1 ]]; then v='开'; else v='关'; fi
    tui_item 3 'VLESS 加密' "$v" '在 REALITY 之外再加一层加密' '在 REALITY 之外再加一层 VLESS 加密，客户端需要支持。'
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
            if [[ $c == 2 ]]; then input_page 'XMUX' '按并发数' '每条底层连接最多同时承载几路请求，可以填数字或区间。'
            else input_page 'XMUX' '按连接数' '客户端最多开几条底层连接，可以填数字或区间。'; fi
            while :; do
                if [[ $c == 2 ]]; then read_line '每条连接承载几路（例如 16-32）：' r "${r0:-16-32}"
                else read_line '底层连接数（例如 2-4）：' r "${r0:-2-4}"; fi
                [[ -n $r ]] || return 0
                [[ $r =~ ^[0-9]{1,4}(-[0-9]{1,4})?$ ]] && break
                ui_warn '请填写数字或区间，例如 16-32。'
            done
            while :; do
                read_line '每条连接最长复用几秒：' s "$s0"
                [[ -n $s ]] || s=$s0
                [[ $s =~ ^[0-9]{1,6}(-[0-9]{1,6})?$ ]] && break
                ui_warn '请填写数字或区间，例如 1800-3000。'
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
    ui_hint $'上传和下载分别走本机的 IPv4 和 IPv6，\n客户端也要同时有 IPv4 和 IPv6。'
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

edit_ssm() {
    local c cur want
    index_of cur "$(st .ss.method)" 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm
    option_page c "$cur" 'SS2022 加密方式' '' '2022-blake3-aes-128-gcm|推荐' '2022-blake3-aes-256-gcm|密钥更长'
    [[ -n $c && $c != "$cur" ]] || return 0
    if [[ $c == 1 ]]; then want=2022-blake3-aes-128-gcm; else want=2022-blake3-aes-256-gcm; fi
    confirm_identity_change '更换加密方式会生成新密码' || return 0
    st_sets .ss.method "$want"
    st_sets .ss.password ''
    if [[ $(scheme) == ss ]]; then st_filter '.users |= map(if .name != "direct" then .id = "" else . end)'; fi
    if [[ $MODE == modify && -f $STAGE/pv-base.json && $(jq -r .ss.method "$STAGE/pv-base.json") == "$want" ]]; then
        st_filter --slurpfile b "$STAGE/pv-base.json" '.ss.password = $b[0].ss.password
            | .users |= map(. as $u | if .id == "" then .id = ([$b[0].users[] | select(.name == $u.name) | .id][0] // "") else . end)'
    fi
}

ec_build() {
    ui_page 'VLESS-ENC 参数'
    tui_item 1 '握手方式' "$(rtt_label "$(st .enc.rtt)")" '' '0-RTT 复用会话票据，重连更快；1-RTT 每次完整握手。'
    tui_item 2 '认证方式' "$(auth_label "$(st .enc.auth)")" '' 'X25519 密钥短；ML-KEM-768 抗量子，但链接会长很多。'
    tui_item 3 '握手外观' "$(st .enc.shape)" '' '握手数据在网络上看起来的样子。'
    tui_item 4 '填充' "$(pad_label "$(st .enc.pad)")" '' '在握手数据里加入随机长度的填充。'
    tui_item 5 '票据有效期' "$(st .enc.ticket | tr -d s) 秒" '只影响服务端' '0-RTT 会话票据在服务端保留多久。'
    TUI_HELP_H=1
    TUI_FOOT='上下键 移动   回车 修改   Esc 返回'
}

edit_encp() {
    local v cur sel=0
    while :; do
        tui_menu ec_build "$sel" ''
        sel=$TUI_CUR
        [[ $TUI_KEY == ENTER ]] || return 0
        case ${TUI_IKEYS[$TUI_CUR]} in
            1)
                cur=1; [[ $(st .enc.rtt) != 1rtt ]] || cur=2
                option_page v "$cur" '握手方式' '' '0-RTT|复用会话票据，重连更快' '1-RTT|每次都完整握手'
                [[ -n $v && $v != "$cur" ]] || continue
                confirm_identity_change '修改握手方式' || continue
                if [[ $v == 1 ]]; then st_sets .enc.rtt 0rtt; else st_sets .enc.rtt 1rtt; fi ;;
            2)
                cur=1; [[ $(st .enc.auth) != mlkem768 ]] || cur=2
                option_page v "$cur" '认证方式' '' 'X25519|密钥短，推荐' 'ML-KEM-768|抗量子，链接会长很多'
                [[ -n $v && $v != "$cur" ]] || continue
                confirm_identity_change '更换认证方式会生成新密钥' || continue
                if [[ $v == 1 ]]; then st_sets .enc.auth x25519; else st_sets .enc.auth mlkem768; fi
                st_filter '.enc.server_key = "" | .enc.client_key = ""'
                if [[ $MODE == modify && -f $STAGE/pv-base.json && $(jq -r .enc.auth "$STAGE/pv-base.json") == "$(st .enc.auth)" ]]; then
                    st_filter --slurpfile b "$STAGE/pv-base.json" '.enc.server_key = $b[0].enc.server_key | .enc.client_key = $b[0].enc.client_key'
                fi ;;
            3)
                index_of cur "$(st .enc.shape)" random xorpub native
                option_page v "$cur" '握手外观' '握手数据在网络上看起来的样子。' \
                    'random|全部看起来是随机字节，推荐' 'xorpub|公钥部分做混淆' 'native|不做处理'
                [[ -n $v && $v != "$cur" ]] || continue
                confirm_identity_change '修改握手外观' || continue
                case $v in 1) st_sets .enc.shape random ;; 2) st_sets .enc.shape xorpub ;; 3) st_sets .enc.shape native ;; esac ;;
            4) edit_padding ;;
            5)
                input_page '票据有效期' '' $'0-RTT 会话票据在服务端保留多久。\n只影响服务端，客户端不用重新导入。' \
                    '当前' "$(st .enc.ticket | tr -d s) 秒" '可以填' '1-86400 秒'
                ask_number '有效期（秒）' 1 86400 "$(st .enc.ticket | tr -d s)" v
                st_sets .enc.ticket "${v}s" ;;
        esac
    done
}

edit_padding() {
    local c p q cur
    index_of cur "$(st .enc.pad)" off gentle aggressive custom
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
            input_page '填充' '自定义' $'格式：多段「概率-最小-最大」用点连接，\n第一段概率须为 100，长度不小于 35。'
            while :; do
                read_line '客户端规则：' p "$(st .enc.pad_client | grep . || printf '100-96-768.60-0-80')"
                [[ -n $p ]] || return 0
                valid_padding "$p" && break
                ui_warn '格式不正确。'
            done
            while :; do
                read_line '服务端规则：' q "$(st .enc.pad_server | grep . || printf '100-128-1024.70-0-96')"
                [[ -n $q ]] || return 0
                valid_padding "$q" && break
                ui_warn '格式不正确。'
            done
            st_filter --arg p "$p" --arg q "$q" '.enc.pad = "custom" | .enc.pad_client = $p | .enc.pad_server = $q' ;;
    esac
}

edit_guard() {
    local c cur=1
    [[ $(st .reality.guard) == nginx ]] || cur=2
    option_page c "$cur" '过滤方式' $'SNI 不是伪装站点的连接直接断开，\n防止服务器被当成访问任意网站的跳板。' \
        'Nginx 前置|可以限制连接数，推荐' 'Xray 内置|不装 Nginx，没有连接上限'
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
    ask_number '每个 IP 最多几条' 16 65535 "$(st .reality.conn_ip)" a
    total=$(st .reality.conn_total)
    (( total >= a )) || total=$a
    ask_number '总计最多几条' "$a" 65535 "$total" b
    st_set .reality.conn_ip "$a"
    st_set .reality.conn_total "$b"
}

edit_limit() {
    local c ua ur da dr cur
    index_of cur "$(st .reality.limit)" orig std custom
    option_page c "$cur" '回落限速' $'被转给伪装站点的流量，传到一定量后限速，防止被偷流量。\n数值在预设附近随机微调，每台服务器都不一样。' \
        "严格|$(limit_text "$(limit_preset orig)")" "宽松|$(limit_text "$(limit_preset std)")" '自定义|分别填写 4 个数值'
    [[ -n $c ]] || return 0
    if [[ $c == "$cur" && $c != 3 ]]; then return 0; fi
    case $c in
        1) st_sets .reality.limit orig ;;
        2) st_sets .reality.limit std ;;
        3)
            input_page '回落限速' '自定义' '单位是字节，1K = 1024，1M = 1048576。'
            ask_number '上行传多少字节后开始限速' 0 104857600 "$(st .reality.limit_custom.ua)" ua
            ask_number '上行限速每秒多少字节' 1 104857600 "$(st .reality.limit_custom.ur)" ur
            ask_number '下行传多少字节后开始限速' 0 104857600 "$(st .reality.limit_custom.da)" da
            ask_number '下行限速每秒多少字节' 1 104857600 "$(st .reality.limit_custom.dr)" dr
            st_set .reality.limit_custom "$(jq -cn --argjson a "$ua" --argjson b "$ur" --argjson c "$da" --argjson d "$dr" \
                '{ua:$a, ur:$b, da:$c, dr:$d}')"
            st_sets .reality.limit custom ;;
    esac
}

SYS_KEYS=()

sy_build() {
    local v fw
    ui_page '高级设置'
    SYS_KEYS=(outbound bbr)
    tui_item 1 '出站 IP' "$(outbound_label "$(st .outbound)")" '访问网站时用哪种 IP' '服务器访问目标网站时先用哪种 IP。'
    if [[ $(st .bbr) == 1 ]]; then v='开'; else v='关'; fi
    tui_item 2 'BBR' "$v" 'TCP 拥塞控制' '通常能提升高延迟、有丢包线路的速度。'
    if scheme_has_reality "$(scheme)"; then
        SYS_KEYS+=(fp)
        tui_item "${#SYS_KEYS[@]}" 'TLS 指纹' "$(st .reality.fp)" '客户端模仿的浏览器' 'chrome 兼容性最好，各种客户端都能用。'
    fi
    if [[ -n $(st .net.v6) && $(st .net.host) == "$(st .net.v4)" ]] && ! scheme_is_split "$(scheme)"; then
        SYS_KEYS+=(v6link)
        if [[ $(st '.net.v6_link // 1') == 1 ]]; then v='附带'; else v='不附带'; fi
        tui_item "${#SYS_KEYS[@]}" 'IPv6 链接' "$v" '每个节点另给一条 IPv6 链接' '本机有 IPv6 时，每个节点另外生成一条用 IPv6 连接的链接。'
    fi
    fw=$(fw_kind)
    if [[ -n $fw ]]; then
        SYS_KEYS+=(firewall)
        if [[ $(st '.firewall // "auto"') == auto ]]; then v='自动放行'; else v='不处理'; fi
        tui_item "${#SYS_KEYS[@]}" '防火墙' "$v" "本机 $fw 已启用" '自动放行用到的端口，改端口时同步，卸载时撤销。'
    fi
    SYS_KEYS+=(core)
    local -a cl=()
    if needs_xray; then cl+=("Xray $(core_label xray)"); fi
    if needs_ss_rust; then cl+=("SS-Rust $(core_label ss)"); fi
    tui_item "${#SYS_KEYS[@]}" '核心版本' "${cl[0]:-}" '' '兼容版 sing-box 也能连；最新版含预发布，sing-box 连不上。'
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
        "edit_${SYS_KEYS[$TUI_CUR]}"
    done
}

edit_outbound() {
    local c cur m
    local -a modes=(v4first v6first v4only v6only) opts=()
    opts=('IPv4 优先|推荐' 'IPv6 优先|' '只用 IPv4|' '只用 IPv6|')
    [[ -n $NET_V4 ]] || opts[2]='只用 IPv4|本机没有 IPv4，不可选'
    [[ -n $NET_V6 ]] || opts[3]='只用 IPv6|本机没有 IPv6，不可选'
    index_of cur "$(st .outbound)" "${modes[@]}"
    option_page c "$cur" '出站 IP' '服务器访问目标网站时先用哪种 IP。' "${opts[@]}"
    [[ -n $c && $c != "$cur" ]] || return 0
    if [[ ${opts[$((c - 1))]} == *不可选* ]]; then ui_warn '本机没有对应的公网地址，不能选这一项。'; ui_pause; return 0; fi
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
    option_page c "$cur" 'BBR' 'TCP 拥塞控制算法，通常能提升高延迟、有丢包线路的速度。' \
        '开|内核支持时启用 BBR + fq' '关|保持系统原有设置'
    [[ -n $c && $c != "$cur" ]] || return 0
    if [[ $c == 1 ]]; then st_set .bbr 1; else st_set .bbr 0; fi
}

edit_fp() {
    local c cur=0
    case $(st .reality.fp) in chrome) cur=1 ;; firefox) cur=2 ;; esac
    option_page c "$cur" 'TLS 指纹' $'客户端连接时模仿哪种浏览器，写进节点链接。\n其他指纹在新版服务端上会被拒绝，所以只保留这两种。' \
        'chrome|推荐，各种客户端都能用' 'firefox|最新版核心下，需要 Xray 26.3.27 以上的客户端'
    [[ -n $c && $c != "$cur" ]] || return 0
    if [[ $c == 1 ]]; then st_sets .reality.fp chrome; else st_sets .reality.fp firefox; fi
}

edit_v6link() {
    local c cur=1
    [[ $(st '.net.v6_link // 1') == 1 ]] || cur=2
    option_page c "$cur" 'IPv6 链接' '本机有 IPv6 时，给每个节点另外生成一条用 IPv6 连接的链接。' \
        '附带|IPv4 和 IPv6 各一条' '不附带|只生成节点地址那一条'
    [[ -n $c && $c != "$cur" ]] || return 0
    if [[ $c == 1 ]]; then st_set .net.v6_link 1; else st_set .net.v6_link 0; fi
}

edit_firewall() {
    local c cur=1 fw
    fw=$(fw_kind)
    [[ $(st '.firewall // "auto"') == auto ]] || cur=2
    option_page c "$cur" '防火墙' "本机 $fw 已启用。可以自动放行用到的端口，卸载时撤销。" \
        '自动放行|推荐' '不处理|自己手动放行'
    [[ -n $c && $c != "$cur" ]] || return 0
    if [[ $c == 1 ]]; then st_sets .firewall auto; else st_sets .firewall off; fi
}

co_build() {
    ui_page '核心版本'
    if needs_xray; then tui_item 1 'Xray' "$(core_label xray)" '' '兼容版 sing-box 也能连；最新版只用发布满 3 天的版本。'; fi
    if needs_ss_rust; then tui_item 2 'SS-Rust' "$(core_label ss)" '' '跟随 shadowsocks-rust 的正式版，或固定一个版本。'; fi
    TUI_HELP_H=1
    TUI_FOOT='上下键 移动   回车 修改   Esc 返回'
}

ask_core_version() {
    local __av_cur=$1 __av_v
    while :; do
        read_line '版本号：' __av_v "$__av_cur"
        [[ -n $__av_v ]] || return 1
        if [[ $__av_v =~ ^v?[0-9]+(\.[0-9]+){1,3}$ ]]; then printf -v "$2" '%s' "$(normalize_tag "$__av_v")"; return 0; fi
        ui_warn '版本号格式不正确，例如 v26.7.28。'
    done
}

edit_core() {
    local c cur v sel=0 iv
    while :; do
        tui_menu co_build "$sel" ''
        sel=$TUI_CUR
        [[ $TUI_KEY == ENTER ]] || return 0
        if [[ ${TUI_IKEYS[$TUI_CUR]} == 1 ]]; then
            case $(st .core.xray) in compat) cur=1 ;; latest) cur=2 ;; *) cur=3 ;; esac
            option_page c "$cur" 'Xray 版本' $'最新版的 REALITY 会拒绝不带抗量子密钥的握手，\nsing-box 内核的客户端因此连不上。' \
                "兼容版|$XRAY_COMPAT_VERSION，sing-box 也能连，推荐" "最新版|含预发布，只用发布满 $XRAY_SETTLE_DAYS 天的" '指定版本|填写一个版本号'
            [[ -n $c ]] || continue
            case $c in
                1) st_sets .core.xray compat ;;
                2) st_sets .core.xray latest ;;
                3)
                    iv=$(installed_version xray)
                    [[ $(st .core.xray) == compat || $(st .core.xray) == latest ]] || iv=$(st .core.xray)
                    input_page 'Xray 版本' '指定版本' "填写 Xray 的版本号，例如 $XRAY_COMPAT_VERSION。最低 v$XRAY_MIN_VERSION。"
                    ask_core_version "${iv:-$XRAY_COMPAT_VERSION}" v || continue
                    if ! ver_ge "${v#v}" "$XRAY_MIN_VERSION"; then ui_warn "最低需要 v$XRAY_MIN_VERSION。"; ui_pause; continue; fi
                    st_sets .core.xray "$v" ;;
            esac
        else
            cur=1; [[ $(st .core.ss) == latest ]] || cur=2
            option_page c "$cur" 'SS-Rust 版本' '' '最新版|跟随正式版' '指定版本|填写一个版本号'
            [[ -n $c ]] || continue
            if [[ $c == 1 ]]; then st_sets .core.ss latest; continue; fi
            input_page 'SS-Rust 版本' '指定版本' '填写 shadowsocks-rust 的版本号，例如 v1.24.0。'
            iv=$(installed_version ss)
            ask_core_version "${iv:-v1.24.0}" v || continue
            st_sets .core.ss "$v"
        fi
    done
}


listen_any() { if has_ipv6_stack; then printf '::'; else printf '0.0.0.0'; fi; }

block_rules_json() {
    jq -cn '[
      {type:"field", domain:["full:localhost","full:localhost.localdomain"], outboundTag:"blocked"},
      {type:"field", network:"tcp", port:"25,465,587,2525", outboundTag:"blocked"},
      {type:"field", network:"udp", port:"443", outboundTag:"blocked"},
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
                serverNames: [$sni], privateKey: $key, shortIds: [$sid], minClientVer: "0.0.0",
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

node_label() {
    local l
    l="$(node_name)-$1"
    [[ ${2:-direct} == direct ]] || l+="-$(landing_label "$2")"
    printf '%s' "$l"
}

node_add() { jq -cn --arg l "$1" --arg k "$2" '{label:$l, link:$k}' >> "$NODES_TMP"; }

node_add_with_v6() {
    local label=$1 link=$2 host=$3 port=$4
    node_add "$label" "$link"
    local v6
    v6=$(st .net.v6)
    if v6_links_on && [[ $host == "$(st .net.v4)" ]]; then
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
                    label=$(node_label XHTTP "$outtag")
                    local enc=none flowq='' extra=''
                    if [[ $(st .xhttp.enc) == 1 ]]; then enc=$(enc_string client); flowq='&flow=xtls-rprx-vision'; fi
                    if [[ $(stj .xhttp.xmux) != null ]]; then extra="&extra=$(url_encode "$(jq -c '{xmux: .xhttp.xmux}' "$DRAFT")")"; fi
                    link="vless://$id@$hu:$port?encryption=$(url_encode "$enc")$flowq&$(reality_query)"
                    link+="&type=xhttp&path=$(url_encode "$(st .xhttp.path)")&mode=stream-one$extra#$(url_encode "$label")"
                    node_add_with_v6 "$label" "$link" "$host" "$port" ;;
                reality-split)
                    local up down ex
                    read -r up down <<< "$(split_hosts)"
                    label=$(node_label XHTTP分离 "$outtag")
                    ex=$(jq -cn --arg a "$down" --argjson p "$port" --arg sni "$(st .reality.sni)" --arg fp "$(st .reality.fp)" \
                        --arg pbk "$(st .reality.public_key)" --arg sid "$(st .reality.short_id)" --arg path "$(st .xhttp.path)" \
                        '{downloadSettings:{address:$a, port:$p, network:"xhttp", security:"reality",
                          realitySettings:{serverName:$sni, fingerprint:$fp, publicKey:$pbk, shortId:$sid, spiderX:"/"},
                          xhttpSettings:{path:$path}}}')
                    link="vless://$id@$(uri_host "$up"):$port?encryption=none&$(reality_query)&type=xhttp"
                    link+="&path=$(url_encode "$(st .xhttp.path)")&mode=auto&extra=$(url_encode "$ex")#$(url_encode "$label")"
                    node_add "$label" "$link" ;;
                *)
                    label=$(node_label REALITY "$outtag")
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
                label=$(node_label ENC分离)
                ex=$(jq -cn --arg a "$down" --argjson p "$port" --arg path "$(st .xhttp.path)" \
                    '{downloadSettings:{address:$a, port:$p, network:"xhttp", xhttpSettings:{path:$path}}}')
                link="vless://$id@$(uri_host "$up"):$port?encryption=$enc&security=none&type=xhttp"
                link+="&path=$(url_encode "$(st .xhttp.path)")&mode=auto&extra=$(url_encode "$ex")#$(url_encode "$label")"
                node_add "$label" "$link"
            else
                label=$(node_label VLESS-ENC "$outtag")
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
        label=$(node_label SS)
        link="ss://$ui@$hu:$(st .ss.port)#$(url_encode "$label")"
        node_add_with_v6 "$label" "$link" "$host" "$(st .ss.port)"
        if [[ $s == ss ]]; then
            for (( i = 0; i < n; i++ )); do
                port=$(jq -r ".users[$i].port // 0" "$DRAFT")
                [[ $port != 0 ]] || continue
                outtag=$(jq -r ".users[$i].out" "$DRAFT")
                ui=$(b64url_nopad "$m:$(jq -r ".users[$i].id" "$DRAFT")")
                label=$(node_label SS "$outtag")
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
            limit_text | sed '1s/^/限速    /; 2,$s/^/        /'
            printf '\n'
        fi
        if [[ $(scheme_transport "$s") == xhttp ]]; then
            printf 'XHTTP   请使用 Xray 内核客户端，不要开启通用 Mux.cool\n'
        fi
        if [[ $s == ss && $(ss_core) == ss-rust ]]; then
            printf 'SS-Rust 已拦截私网地址；不含 Xray 的 SMTP 端口和 UDP 443 拦截\n'
        fi
    } > "$out"
}


installed_version() { jq -r ".installed.$1 // empty" "$STATE" 2>/dev/null || true; }

core_satisfied() {
    local which=$1 want cur old
    state_ok || return 1
    want=$(st ".core.$which")
    cur=$(installed_version "$which")
    old=$(jq -r ".core.$which // empty" "$STATE" 2>/dev/null || true)
    [[ -n $cur ]] || return 1
    case $want in
        compat) [[ $cur == "$XRAY_COMPAT_VERSION" ]] ;;
        latest) [[ $old == latest ]] ;;
        *) [[ ${cur#v} == "${want#v}" ]] ;;
    esac
}

plan_cores() {
    USE_XRAY='' USE_SS='' NEW_XRAY=0 NEW_SS=0
    if needs_xray; then
        if [[ -x $XRAY_BIN ]] && core_satisfied xray; then USE_XRAY=$XRAY_BIN USE_XRAY_ASSET=$XRAY_ASSET_DIR
        else NEW_XRAY=1; fi
    fi
    if needs_ss_rust; then
        if [[ -x $SS_BIN ]] && core_satisfied ss; then USE_SS=$SS_BIN
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
        { die 'Xray 检查配置没有通过，原因见下方日志。'; return 1; }
}

validate_ss_rust() {
    local cfg=$1 acl=$2 p child ok=0 k
    p=$(random_free_port)
    jq --argjson p "$p" '.server = "127.0.0.1" | .server_port = $p' "$cfg" > "$STAGE/ss-check.json"
    "$USE_SS" -c "$STAGE/ss-check.json" --acl "$acl" >> "$STEP_LOG" 2>&1 3>&- 4>&- 9>&- &
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
    (( ok )) || { die 'shadowsocks-rust 用这份配置试启动失败，原因见下方日志。'; return 1; }
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
        local had_nginx=0 rc=0 added=''
        if have nginx || svc_exists nginx; then had_nginx=1; fi
        pkg_refresh >> "$STEP_LOG" 2>&1 || true
        pkg_snapshot > "$TX/pkgs-before"
        if (( ! had_nginx )) && [[ $INIT == systemd ]]; then
            : > "$TX/nginx-masked"
            systemctl mask nginx >> "$STEP_LOG" 2>&1 || true
        fi
        pkg_install_tracked added "${missing[@]}" >> "$STEP_LOG" 2>&1 || rc=$?
        if [[ -f $TX/nginx-masked ]]; then
            systemctl unmask nginx >> "$STEP_LOG" 2>&1 || true
            rm -f -- "$TX/nginx-masked"
        fi
        [[ -z $added ]] || tr -s ' ' '\n' <<< "$added" >> "$TX/new-packages"
        rm -f -- "$TX/pkgs-before"
        (( rc == 0 )) || { die 'Nginx 安装失败，原因见下方日志。'; return 1; }
        if (( ! had_nginx )); then
            svc_stop_disable nginx
            st_filter --argjson add "$(json_words "$added")" '.meta.nginx_packages = ((.meta.nginx_packages + $add) | unique)'
            if [[ -z $(st .meta.nginx_hash) ]]; then st_sets .meta.nginx_hash "$(nginx_system_hash)"; fi
        elif [[ -n $added ]]; then
            st_filter --argjson add "$(json_words "$added")" '.meta.extra_packages = (((.meta.extra_packages // []) + $add) | unique)'
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
    make_dir "$(dirname -- "$SYSCTL_FILE")"
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
    done <<< "$(public_ports)"
    return 1
}
install_files_and_services() {
    local low
    repair_std_dirs
    ensure_service_user
    if (( SERVICE_USER_CREATED )); then st_set .meta.created_user 1; fi
    make_dir "$DATA_DIR/log" "$SELF_DIR" "$(dirname -- "$QUICK_BIN")"
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
        make_dir "$CONFIG_DIR"
        atomic_install "$STAGE/config.json" "$CONFIG_FILE" 640
        chown "root:$SERVICE_USER" "$CONFIG_FILE"
        chmod 750 "$CONFIG_DIR"
        chown "root:$SERVICE_USER" "$CONFIG_DIR"
        low=0
        if xray_needs_lowport; then low=1; fi
        grant_lowport "$XRAY_BIN" "$low"
        write_service xray "$XRAY_BIN" "run -config $CONFIG_FILE" 'Xray' "$SERVICE_USER" "$low" "XRAY_LOCATION_ASSET=$XRAY_ASSET_DIR"
        check_service_access "$XRAY_BIN" "$CONFIG_FILE" "$XRAY_ASSET_DIR/geoip.dat"
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
        check_service_access "$SS_BIN" "$SS_CONFIG" "$SS_ACL"
    fi
    if needs_nginx; then
        make_dir "$NGINX_DIR/tmp" "$NGINX_RUN"
        chmod 755 "$NGINX_RUN"
        atomic_install "$STAGE/nginx.conf" "$NGINX_DIR/nginx.conf" 644
        nginx -t -c "$NGINX_DIR/nginx.conf" -p "$NGINX_DIR/" >> "$STEP_LOG" 2>&1 || { die 'Nginx 配置检查没有通过。'; return 1; }
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
    done <<< "$(wanted_services)"
}

service_log_to_step() {
    local s=$1
    if [[ $INIT == systemd ]]; then
        journalctl -u "$s" -n 15 --no-pager -o cat >> "$STEP_LOG" 2>&1 || true
    elif [[ -f $DATA_DIR/log/$s.log ]]; then
        tail -n 15 "$DATA_DIR/log/$s.log" >> "$STEP_LOG" 2>&1 || true
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
    local s proto port label i owner
    while read -r s; do
        [[ -n $s ]] || continue
        if ! wait_active "$s" 10; then
            service_log_to_step "$s"
            die "$(svc_label "$s") 没有启动成功。"
            return 1
        fi
    done <<< "$(wanted_services)"
    while read -r proto port label; do
        [[ -n $port ]] || continue
        for (( i = 0; i < 20; i++ )); do
            if port_listening "$proto" "$port" && ! port_foreign "$proto" "$port"; then break; fi
            sleep 0.5
        done
        if port_foreign "$proto" "$port"; then
            die "${proto^^} $port 被 $(port_owner_label "$proto" "$port") 占用了。"
            return 1
        fi
        if ! port_listening "$proto" "$port"; then
            owner=$(port_service "$label")
            service_log_to_step "$owner"
            die "${proto^^} $port（$label）没有在监听。" "$(svc_label "$owner") 可能刚启动就退出了，原因见下方日志。"
            return 1
        fi
    done <<< "$(public_ports)"
    if scheme_has_reality "$(scheme)"; then reality_check; fi
    return 0
}

reality_check() {
    local rp sni rows probe=$STAGE/reality-probe.log ok=0 t
    rp=$(st .reality.port)
    sni=$(st .reality.sni)
    if [[ $(st .reality.guard) == nginx ]]; then
        rows=$(listeners tcp "$(st .reality.internal)")
        if [[ -z $rows || $rows != *127.0.0.1:* ]]; then
            service_log_to_step xray
            die "Xray 的内部端口 127.0.0.1:$(st .reality.internal) 没有在监听。"
            return 1
        fi
        if grep -vq '127.0.0.1:' <<< "$rows"; then die 'Xray 的内部端口意外暴露到了公网，已停止。'; return 1; fi
    fi
    if timeout 6 openssl s_client -connect "127.0.0.1:$rp" -servername invalid.example -tls1_3 -brief </dev/null > "$probe" 2>&1; then
        die '防护没有生效：访问其他域名的连接没有被拒绝。'
        return 1
    fi
    for t in 1 2; do
        if timeout 10 openssl s_client -connect "127.0.0.1:$rp" -servername "$sni" -tls1_3 -brief \
            -verify_hostname "$sni" -verify_return_error </dev/null > "$probe" 2>&1; then ok=1; break; fi
        sleep 1
    done
    if (( ! ok )); then
        tail -n 5 "$probe" >> "$STEP_LOG" 2>/dev/null || true
        die "用伪装站点 $sni 握手失败，本机可能连不上它。" '可以在「伪装站点」里换一个再试。'
        return 1
    fi
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
    ports_preflight
    ui_step_done

    tx_begin
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
    st_sets .script "$SCRIPT_VERSION"
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

    ui_step '收尾'
    tx_commit
    post_commit_cleanup
    ui_step_done
}

ports_preflight() {
    local proto port label
    while read -r proto port label; do
        [[ -n $port ]] || continue
        if port_foreign "$proto" "$port"; then
            die "${proto^^} $port（$label）已被 $(port_owner_label "$proto" "$port") 占用。" '请在「修改配置」里换一个端口，或先停掉占用它的程序。'
            return 1
        fi
    done <<< "$(public_ports)"
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
    if [[ -f $STAGE/sni-pool.txt ]]; then atomic_install "$STAGE/sni-pool.txt" "$SNI_POOL_FILE" 600; fi
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
        ui_note 'Nginx 还在被其他程序使用或配置被改过，保留它的软件包。'
        return 0
    fi
    local -a pkgs=()
    mapfile -t pkgs < <(jq -r '.[]' <<< "$pk")
    pkg_remove_safe "${pkgs[@]}" >/dev/null 2>&1 || { ui_warn 'Nginx 软件包没能卸载，下次操作时会再试。'; return 1; }
    jq '.meta.nginx_packages = [] | .meta.nginx_hash = ""' "$STATE" > "$STAGE/state-clean.json"
    atomic_install "$STAGE/state-clean.json" "$STATE" 600
}


release_extra_packages() {
    local -a pkgs=()
    mapfile -t pkgs < <(jq -r '.meta.extra_packages // [] | .[]' "$1" 2>/dev/null)
    (( ${#pkgs[@]} )) || return 0
    pkg_remove_safe "${pkgs[@]}" >/dev/null 2>&1 || ui_warn "没能卸载 ${pkgs[*]}，可以稍后手动删除。"
    return 0
}

state_ok() { [[ -f $STATE ]] && [[ $(jq -r '.schema // 0' "$STATE" 2>/dev/null) == "$STATE_SCHEMA" ]]; }

migrate_state() {
    local f tmp
    for f in "$STATE" "$DATA_DIR/state.prev.json"; do
        [[ -f $f ]] || continue
        [[ $(jq -r '.schema // 0' "$f" 2>/dev/null || true) == 4 ]] || continue
        tmp=$(mktemp "$f.XXXXXX")
        if jq --argjson s "$STATE_SCHEMA" --argjson j "$(limit_jitter_new)" '.schema = $s
            | (if .core.xray == "latest" then .core.xray = "compat" else . end)
            | .reality.limit_jitter = (.reality.limit_jitter // $j)' "$f" > "$tmp"; then
            chmod 600 "$tmp"
            mv -f -- "$tmp" "$f"
        else
            rm -f -- "$tmp"
        fi
    done
    return 0
}

foreign_install_present() {
    state_ok && return 1
    [[ -e $CONFIG_FILE || -e $XRAY_BIN || -f $OLD_DATA_DIR/state.json ]]
}

foreign_install_hint() {
    local p
    DIE_SHOWN=1
    if [[ -f $OLD_DATA_DIR/state.json ]]; then
        ui_err '发现旧版 Xray Manager 的安装，新版不能直接接管。'
        ui_line '请先卸载旧版，再重新运行本脚本：'
        if [[ -f $OLD_SELF_SCRIPT ]]; then ui_code "  bash $OLD_SELF_SCRIPT --uninstall"
        else ui_line '  zxray --uninstall'; fi
        return 1
    fi
    ui_err '发现不是由本脚本安装的 Xray，为避免破坏它，已停止。'
    for p in "$CONFIG_FILE" "$XRAY_BIN" "$STATE"; do
        [[ ! -e $p ]] || ui_code "  $p"
    done
    ui_note '确认这些文件不再需要后，把它们删除再重新运行。'
    return 1
}


install_self() {
    local src=$SOURCE_PATH
    make_dir "$SELF_DIR" "$(dirname -- "$QUICK_BIN")"
    if [[ -n $src && -f $src && $src != "$SELF_SCRIPT_PATH" ]] && grep -q "$SCRIPT_MARKER" "$src" 2>/dev/null; then
        local cur_v src_v
        src_v=$(script_version_of "$src")
        cur_v=$(script_version_of "$SELF_SCRIPT_PATH")
        if [[ -z $cur_v ]] || ver_ge "$src_v" "$cur_v"; then
            atomic_install "$src" "$SELF_SCRIPT_PATH" 700
        fi
        if [[ $src != /proc/* && $src != /dev/* ]]; then
            make_dir "$DATA_DIR"
            jq -cn --arg p "$src" --arg h "$(sha256_of "$src")" '{path:$p, sha256:$h}' >> "$DATA_DIR/sources.ndjson"
            jq -sc 'unique_by([.path, .sha256]) | .[]' "$DATA_DIR/sources.ndjson" > "$DATA_DIR/sources.ndjson.new" &&
                mv -f "$DATA_DIR/sources.ndjson.new" "$DATA_DIR/sources.ndjson"
        fi
    fi
    [[ -f $SELF_SCRIPT_PATH ]] || return 0
    if [[ -e $QUICK_BIN ]] && ! is_managed_file "$QUICK_BIN"; then
        ui_warn "$QUICK_BIN 已被其他程序占用，没有创建 zxray 快捷命令。"
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
        ui_line '正在为 REALITY 测速挑选伪装站点...'
        if sni_auto_select d; then
            st_sets .reality.sni "$d"
            st_set .reality.sni_auto 1
        else
            note_add '自动测速没有找到可用的伪装站点，请在第 2 项手动填写。'
        fi
    fi
    if [[ $(st .meta.selinux_note) == 1 ]]; then
        note_add 'SELinux 处于强制模式，前置防护改用 Xray 内置方式。'
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
    state_ok || return 0
    st_filter --slurpfile o "$STATE" '.meta = (.meta + ($o[0].meta // {}
            | {nginx_packages, nginx_hash, created_user, created_dirs, fw_rules, extra_packages}
            | with_entries(select(.value != null))))
        | .name = ($o[0].name // .name)
        | .firewall = ($o[0].firewall // .firewall)'
}

action_install() {
    if foreign_install_present; then
        foreign_install_hint
        return 1
    fi
    ui_line '正在检测本机公网地址...'
    detect_public_ips
    DRAFT=$STAGE/draft.json
    local def=1 curidx=0
    if state_ok; then
        curidx=$(scheme_index "$(jq -r .scheme "$STATE")")
        MODE=modify
        load_state_draft
        PREVIEW_NOTES=()
        refresh_net_in_draft
        def=$(scheme_index "$(scheme)")
        cp "$NODES_JSON" "$STAGE/nodes-before.json" 2>/dev/null || echo '[]' > "$STAGE/nodes-before.json"
        preview_loop
        case $PREVIEW_RESULT in
            0) apply_draft; show_modify_result; return 0 ;;
            1) exit "$RC_QUIET" ;;
        esac
    fi
    local cli_first=1
    [[ -z $CLI_SCHEME ]] || def=$(scheme_index "$CLI_SCHEME")
    while :; do
        MODE=new
        local s
        if (( cli_first )) && [[ -n $CLI_SCHEME ]]; then s=$CLI_SCHEME
        else choose_scheme s "$def" "$curidx"; fi
        cli_first=0
        [[ -n $s ]] || exit "$RC_QUIET"
        if scheme_is_split "$s" && [[ -z $NET_V4 || -z $NET_V6 ]]; then
            ui_warn '上下行分离需要本机同时有公网 IPv4 和 IPv6。'
            ui_note "检测结果：IPv4 ${NET_V4:-无}，IPv6 ${NET_V6:-无}"
            ui_pause
            continue
        fi
        draft_new "$s"
        carry_meta_from_state
        [[ -z $CLI_CORE_TAG ]] || st_sets .core.xray "$CLI_CORE_TAG"
        prepare_new_draft
        preview_loop
        if [[ $PREVIEW_RESULT != 0 ]]; then def=$(scheme_index "$s"); continue; fi
        if state_ok; then
            ui_warn '重新安装会生成全新的节点，现有节点全部失效。'
            if ! ask_no '确定重新安装'; then continue; fi
        fi
        apply_draft
        show_install_result
        return 0
    done
}

firewall_hints() {
    local kind l
    local -a ports=() missing=()
    mapfile -t ports < <(fw_wanted)
    (( ${#ports[@]} )) || return 0
    ui_kv_words '对外端口' "${ports[@]}"
    kind=$(fw_kind)
    if [[ -n $kind ]]; then
        for l in "${ports[@]}"; do fw_has "$kind" "$l" || missing+=("$l"); done
        if (( ${#missing[@]} )); then
            ui_kv '本机防火墙' "${C_YELLOW}$kind 还没放行${C_RESET}" '可以执行下面的命令'
            for l in "${missing[@]}"; do
                if [[ $kind == ufw ]]; then ui_code "  ufw allow $l"
                else ui_code "  firewall-cmd --permanent --add-port=$l && firewall-cmd --add-port=$l"; fi
            done
        elif [[ $(jq -r '.meta.fw_rules // [] | length' "$DRAFT") != 0 ]]; then
            ui_kv '本机防火墙' "$kind 已自动放行" '卸载时撤销'
        else
            ui_kv '本机防火墙' "$kind 已放行"
        fi
    elif have iptables && grep -qE '^-P INPUT DROP|-j (DROP|REJECT)' <<< "$(iptables -S INPUT 2>/dev/null || true)"; then
        ui_kv '本机防火墙' "${C_YELLOW}iptables 有拦截规则${C_RESET}" '连不上时先检查这里'
    fi
    ui_note '云服务商如果有安全组，也要放行上面的端口。'
}

show_install_result() {
    ui_blank
    ui_title '安装完成' "$(scheme_label "$(scheme)")" ok
    print_nodes
    ui_rule
    firewall_hints
    ui_rule
    ui_line "以后输入 ${C_KEY}zxray${C_RESET} 就能打开主页，"
    ui_line '在「节点链接」里可以再看链接、显示二维码。'
}

show_modify_result() {
    local changed removed l
    ui_blank
    ui_title "${1:-修改已生效}" "$(scheme_label "$(scheme)")" ok
    changed=$(jq -rn --slurpfile a "$STAGE/nodes-before.json" --slurpfile b "$NODES_JSON" '
        ($a[0] | map({(.label): .link}) | add // {}) as $old
        | $b[0][] | select($old[.label] != .link) | .label')
    removed=$(jq -rn --slurpfile a "$STAGE/nodes-before.json" --slurpfile b "$NODES_JSON" '
        ([$b[0][].label]) as $now | $a[0][] | select(.label as $l | $now | index($l) | not) | .label')
    if [[ -n $removed ]]; then
        ui_warn '下面这些节点已删除，客户端里可以删掉：'
        while IFS= read -r l; do ui_line "  $l"; done <<< "$removed"
    fi
    if [[ -z $changed && -z $removed ]]; then
        ui_ok '节点链接没有变化，客户端不用改动。'
    elif [[ -z $changed ]]; then
        ui_ok '其余节点的链接没有变化。'
    else
        ui_warn '下面这些节点的链接变了，需要在客户端重新导入：'
        while IFS= read -r l; do ui_line "  $l"; done <<< "$changed"
        ui_rule
        print_nodes
    fi
    ui_rule
    firewall_hints
}


print_nodes() {
    local n i label
    if [[ ! -f $NODES_JSON ]]; then ui_line '还没有节点，请先在主页选择「安装」。'; return 0; fi
    n=$(jq 'length' "$NODES_JSON")
    for (( i = 0; i < n; i++ )); do
        (( i == 0 )) || printf '\n' >&4
        fit_width "$(jq -r ".[$i].label" "$NODES_JSON")" $(( UI_W - 6 )) label
        printf '  %s%*d%s  %s%s%s\n' "$C_KEY" "${#n}" "$(( i + 1 ))" "$C_RESET" "$C_BOLD" "$label" "$C_RESET" >&4
        jq -r ".[$i].link" "$NODES_JSON" >&4
    done
}

NODE_LABELS=() NODE_LINKS=()

link_preview() {
    local l=$1 w=$(( UI_W - 2 )) i n out=''
    n=$(( (${#l} + w - 1) / w ))
    for (( i = 0; i < n && i < 4; i++ )); do out+=${l:i*w:w}$'\n'; done
    if (( n > 4 )); then out+="...（共 ${#l} 个字符，回车查看完整链接）"
    else out=${out%$'\n'}; fi
    printf '%s' "$out"
}

node_tag() {
    if [[ $1 == *type=xhttp* || $1 == *encryption=mlkem* ]]; then printf 'sing-box 不支持'; fi
}

nd_build() {
    local i n lw0=$LABEL_W
    if state_ok; then DRAFT=$STATE; ui_page '节点链接' "$(scheme_label "$(scheme)")"
    else ui_page '节点链接'; fi
    n=${#NODE_LABELS[@]}
    KEY_W=${#n}
    LABEL_W=24
    for i in "${!NODE_LABELS[@]}"; do
        tui_item $(( i + 1 )) "${NODE_LABELS[$i]}" '' "$(node_tag "${NODE_LINKS[$i]}")" "$(link_preview "${NODE_LINKS[$i]}")"
        (( TUI )) || printf '%s\n\n' "${NODE_LINKS[$i]}" >&4
    done
    LABEL_W=$lw0
    ui_blank
    ui_kv '链接文件' "$INFO_FILE"
    ui_kv '订阅 Base64' "$SUB_B64"
    TUI_HELP_H=5
    TUI_HELP_DIM=0
    TUI_FOOT='上下键 选节点   回车 二维码   c 复制   Esc 返回'
    TUI_FOOT_PLAIN="$(key_range "$n") 显示二维码   回车 返回"
}

osc52_copy() {
    local b
    b=$(printf '%s' "$1" | base64 | tr -d '\r\n')
    if [[ -n ${TMUX:-} || ${TERM:-} == tmux* ]]; then printf '\ePtmux;\e\e]52;c;%s\a\e\\' "$b" >&4
    elif [[ -n ${STY:-} ]]; then printf '\eP\e]52;c;%s\a\e\\' "$b" >&4
    else printf '\e]52;c;%s\a' "$b" >&4; fi
}

action_nodes() {
    local sel=0
    if [[ ! -t 1 ]] || (( ASSUME_YES )); then
        print_nodes
        return 0
    fi
    if [[ ! -s $NODES_JSON ]]; then
        ui_page '节点链接'
        ui_line '还没有节点，请先在主页选择「安装」。'
        ui_rule
        ui_pause
        exit "$RC_QUIET"
    fi
    mapfile -t NODE_LABELS < <(jq -r '.[].label' "$NODES_JSON")
    mapfile -t NODE_LINKS < <(jq -r '.[].link' "$NODES_JSON")
    while :; do
        tui_menu nd_build "$sel" c
        sel=$TUI_CUR
        case $TUI_KEY in
            c)
                osc52_copy "${NODE_LINKS[$TUI_CUR]}"
                TUI_MSG="已复制 ${NODE_LABELS[$TUI_CUR]}（终端不支持时请手动选中复制）" ;;
            ENTER) show_qr "${NODE_LINKS[$TUI_CUR]}" "${NODE_LABELS[$TUI_CUR]}" ;;
            *) exit "$RC_QUIET" ;;
        esac
    done
}

show_qr() {
    local link=$1 label=$2 added='' qr='' warn='' sz rows=0 cols=0 l w h
    if ! have qrencode && (( ! QR_DECLINED )); then
        ui_blank
        ui_note '显示二维码要用到 qrencode，卸载时会一并删除。'
        if ask_yes '现在安装 qrencode'; then
            ui_note '正在安装 qrencode...'
            pkg_refresh >/dev/null 2>&1 || true
            pkg_install_tracked added "$(qr_package)" >/dev/null 2>&1 || true
            if [[ -n $added ]] && state_ok; then
                jq --argjson add "$(json_words "$added")" '.meta.extra_packages = ((.meta.extra_packages // []) + $add | unique)' \
                    "$STATE" > "$STAGE/state-pkg.json"
                atomic_install "$STAGE/state-pkg.json" "$STATE" 600
            fi
            have qrencode || warn='qrencode 安装失败，下面只显示链接。'
        else
            QR_DECLINED=1
        fi
    fi
    if have qrencode; then
        qr=$(qrencode -t UTF8 -m 4 "$link" 2>/dev/null) || { qr=''; warn='链接太长，生成不了二维码。'; }
        if [[ -n $qr ]]; then
            sz=$(stty size <&"$INPUT_FD" 2>/dev/null || true)
            if [[ $sz =~ ^([0-9]+)\ ([0-9]+)$ ]]; then rows=${BASH_REMATCH[1]} cols=${BASH_REMATCH[2]}; fi
            l=${qr%%$'\n'*}
            strip_ansi "$l" l
            w=${#l}
            h=$(grep -c '' <<< "$qr")
            if (( cols > 0 && w > cols )); then
                warn="终端太窄，二维码需要 $w 列宽。把窗口拉宽或把字体调小后再试。"
                qr=''
            elif (( rows > 0 && h + 6 > rows )); then
                warn='终端不够高，二维码可能显示不全，可以把窗口拉高后再试。'
                qr=''
            fi
        fi
    fi
    ui_page "$label" '用客户端扫码，或复制下面的链接'
    [[ -z $warn ]] || ui_warn "$warn"
    [[ -z $qr ]] || printf '%s\n' "$qr" >&4
    printf '%s\n' "$link" >&4
    ui_rule
    ui_pause
}

qr_package() {
    case $PKG in apk) printf 'libqrencode-tools' ;; *) printf 'qrencode' ;; esac
}


mt_build() {
    ui_page '更新与维护'
    tui_item 1 '更新' '' '脚本和核心升到最新，节点不变'
    tui_item 2 '重启' '' '重启服务并检查运行状态'
    tui_item 3 '运行状态' '' '服务、端口、防火墙和最近日志'
    tui_item 4 '候选站点' '' '自动挑选伪装站点时测速的网站'
    if prev_state_ok; then
        tui_item 5 '回滚配置' '' "恢复到 $(date -r "$DATA_DIR/state.prev.json" '+%m-%d %H:%M') 那次修改之前"
    fi
    TUI_FOOT='上下键 移动   回车 选择   Esc 返回'
}

action_maintain() {
    local sel=0
    while :; do
        tui_menu mt_build "$sel" ''
        sel=$TUI_CUR
        [[ $TUI_KEY == ENTER ]] || return 0
        case ${TUI_IKEYS[$TUI_CUR]} in
            1)
                run_sub action_update
                if (( SUB_RC == 21 || SUB_RC == 23 )); then exit "$SUB_RC"; fi ;;
            2) run_sub action_restart ;;
            3) run_sub action_status ;;
            4) run_sub action_sni_pool ;;
            5) run_sub action_rollback ;;
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
        | .installed_at = $cur[0].installed_at | .schema = $cur[0].schema' "$prev" > "$DRAFT"
    pv_snapshot "$STATE"
    mapfile -t PV_KEYS < <(preview_items | grep -v '^@')
    cp "$NODES_JSON" "$STAGE/nodes-before.json" 2>/dev/null || echo '[]' > "$STAGE/nodes-before.json"
    pv_confirm '回滚配置' || exit "$RC_QUIET"
    apply_draft
    show_modify_result '已回滚'
}

check_state_file() {
    [[ -f $STATE ]] || return 0
    state_ok && return 0
    local sv
    sv=$(jq -r '.schema // 0' "$STATE" 2>/dev/null || true)
    if [[ $sv =~ ^[0-9]+$ ]] && (( sv > STATE_SCHEMA )); then
        fatal "这台服务器的配置是更新版本的脚本写的（格式 $sv），当前脚本 v$SCRIPT_VERSION 无法识别，请下载最新版脚本再运行。"
    fi
    ui_err "状态文件无法识别：$STATE"
    if prev_state_ok; then
        ui_note '上一次的配置还在，可以用下面的命令恢复后再运行：'
        ui_code "  cp $DATA_DIR/state.prev.json $STATE"
    fi
    exit 1
}

prev_state_ok() {
    [[ -f $DATA_DIR/state.prev.json ]] && [[ $(jq -r '.schema // 0' "$DATA_DIR/state.prev.json" 2>/dev/null) == "$STATE_SCHEMA" ]]
}

save_prev_state() {
    state_ok || return 0
    local a b
    a=$(jq -S -c 'del(.installed, .installed_at, .updated_at, .script, .meta)' "$STATE")
    b=$(jq -S -c 'del(.installed, .installed_at, .updated_at, .script, .meta)' "$DRAFT")
    [[ $a != "$b" ]] || return 0
    atomic_install "$STATE" "$DATA_DIR/state.prev.json" 600
}

run_sub() {
    run_child "$@"
    SUB_RC=$CHILD_RC
    if (( SUB_RC == 21 || SUB_RC == 23 || SUB_RC == RC_QUIET )); then return 0; fi
    if (( SUB_RC == 130 )); then exit 130; fi
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
    local remote_v rc=0
    require_state
    (( STATE_READY )) || return 0
    STEP_NO=0 STEP_TOTAL=2
    ui_blank
    ui_step '检查脚本更新'
    : > "$STEP_LOG"
    download_script "$STAGE/remote.sh" || rc=$?
    remote_v=''
    (( rc != 0 )) || remote_v=$(script_version_of "$STAGE/remote.sh")
    if (( rc == 1 )); then
        step_end "${C_YELLOW}连不上 GitHub，跳过${C_RESET}"
    elif (( rc == 2 )); then
        step_end "${C_YELLOW}下载到的不是本脚本，跳过${C_RESET}"
    elif (( rc == 3 )); then
        step_end "${C_YELLOW}下载的文件不完整，跳过${C_RESET}"
    elif [[ -z $remote_v ]] || ver_ge "$SCRIPT_VERSION" "$remote_v"; then
        ui_step_skip "已是最新 v$SCRIPT_VERSION"
    else
        [[ ! -f $SELF_SCRIPT_PATH ]] || cp -f -- "$SELF_SCRIPT_PATH" "$SELF_SCRIPT_PATH.prev"
        atomic_install "$STAGE/remote.sh" "$SELF_SCRIPT_PATH" 700
        install_self
        ui_step_skip "v$SCRIPT_VERSION -> v$remote_v"
        ui_line '接下来由新版脚本继续更新核心...'
        trap 'rc=130' INT TERM HUP
        ZX_REEXEC=1 bash "$SELF_SCRIPT_PATH" --update-cores "${ASSUME_YES_FLAG[@]}" <&"$INPUT_FD" 2>&5 || rc=$?
        if (( rc != 0 )); then
            ui_warn '核心没有更新成功，节点仍按原来的配置运行。'
            ui_note "如需退回旧版脚本：cp $SELF_SCRIPT_PATH.prev $SELF_SCRIPT_PATH"
            exit 23
        fi
        exit 21
    fi
    update_cores keep
}

update_cores() {
    local -a todo=() notes=()
    local cur new tag t dir want
    require_state
    (( STATE_READY )) || return 0
    MODE=modify
    [[ ${1:-} == keep ]] || { STEP_NO=0; STEP_TOTAL=1; }
    ui_step '检查核心版本'
    : > "$STEP_LOG"
    dir=$STAGE/core
    mkdir -p "$dir"
    if needs_xray; then
        cur=$(installed_version xray)
        want=$(st .core.xray)
        case $want in
            compat|latest) tag=$(xray_resolve_tag "$want") ;;
            *) tag=''; notes+=("Xray 已固定为 $want") ;;
        esac
        if [[ -n $tag && ${tag#v} != "${cur#v}" ]] && { [[ $want == compat ]] || ver_ge "${tag#v}" "${cur#v}"; }; then
            download_xray "$tag" "$dir/xray-pkg"
            new=$(cat "$dir/xray-pkg/xray.version")
            todo+=("Xray ${cur:-未知} -> $new")
            USE_XRAY=$dir/xray-pkg/xray USE_XRAY_ASSET=$dir/xray-pkg
        fi
    fi
    if needs_ss_rust; then
        cur=$(installed_version ss)
        want=$(st .core.ss)
        if [[ $want == latest ]]; then new=$(latest_tag shadowsocks/shadowsocks-rust)
        else new=''; notes+=("SS-Rust 已固定为 $want"); fi
        if [[ -n $new && $new != "$cur" ]] && ver_ge "$new" "${cur:-0}"; then
            download_ss "$new" "$dir/ss-pkg"
            todo+=("SS-Rust ${cur:-未知} -> $new")
            USE_SS=$dir/ss-pkg/ssserver
        fi
    fi
    if (( ${#todo[@]} == 0 )); then
        if (( ${#notes[@]} )); then ui_step_skip "${notes[0]}"; else ui_step_skip '已是最新'; fi
    else
        ui_step_done
        for t in "${todo[@]}"; do ui_line "  $t"; done
        replace_cores
    fi
    if [[ ${ZX_REEXEC:-0} == 1 ]]; then regenerate_from_state; fi
    return 0
}

replace_cores() {
    local s
    STEP_NO=0 STEP_TOTAL=1
    ui_blank
    if [[ -n $USE_XRAY ]]; then
        STEP_TOTAL=2
        ui_step '用新核心校验配置'
        validate_xray_config "$CONFIG_FILE"
        ui_step_done
    fi
    ui_step '替换核心并重启'
    : > "$STEP_LOG"
    tx_begin
    while read -r s; do [[ -z $s ]] || svc_do stop "$s" || true; done <<< "$(wanted_services)"
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
    ui_ok '核心已更新，节点不变。'
}

regenerate_from_state() {
    ui_blank
    ui_line '用新版脚本重新生成配置，节点不变...'
    load_state_draft
    MODE=modify
    PREVIEW_NOTES=()
    cp "$NODES_JSON" "$STAGE/nodes-before.json" 2>/dev/null || echo '[]' > "$STAGE/nodes-before.json"
    apply_draft
    show_modify_result
}

action_restart() {
    local s
    require_state
    (( STATE_READY )) || return 0
    ui_blank
    STEP_NO=0 STEP_TOTAL=2
    ui_step '重启服务'
    : > "$STEP_LOG"
    while read -r s; do
        [[ -n $s ]] || continue
        svc_do restart "$s" || svc_do start "$s" || true
    done <<< "$(wanted_services)"
    ui_step_done
    ui_step '检查运行状态'
    : > "$STEP_LOG"
    health_check
    ui_step_done
    ui_ok '服务已重启，运行正常。'
}

action_status() {
    local s v proto port label kind
    require_state
    (( STATE_READY )) || return 0
    ui_page '运行状态' "$(scheme_label "$(scheme)")"
    ui_group '服务'
    while read -r s; do
        [[ -n $s ]] || continue
        if svc_active "$s"; then v="${C_GREEN}运行中${C_RESET}"; else v="${C_RED}已停止${C_RESET}"; fi
        case $s in
            xray) ui_kv "$(svc_label "$s")" "$v" "$(installed_version xray)" ;;
            zxray-ss) ui_kv "$(svc_label "$s")" "$v" "$(installed_version ss)" ;;
            *) ui_kv "$(svc_label "$s")" "$v" ;;
        esac
    done <<< "$(wanted_services)"
    ui_blank
    ui_group '端口'
    kind=$(fw_kind)
    while read -r proto port label; do
        [[ -n $port ]] || continue
        if port_listening "$proto" "$port"; then v="${C_GREEN}监听中${C_RESET}"; else v="${C_RED}没有监听${C_RESET}"; fi
        if [[ -n $kind ]]; then
            if fw_has "$kind" "$port/$proto"; then v+="，$kind 已放行"; else v+="，${C_YELLOW}$kind 未放行${C_RESET}"; fi
        fi
        ui_kv "${proto^^} $port" "$v" "$label"
    done <<< "$(public_ports)"
    ui_blank
    ui_group '最近日志'
    while read -r s; do
        [[ -n $s ]] || continue
        printf '  %s%s%s\n' "$C_DIM" "$(svc_label "$s")" "$C_RESET" >&4
        {
            if [[ $INIT == systemd ]]; then
                journalctl -u "$s" -n 8 --no-pager -o cat 2>/dev/null || true
            elif [[ -f $DATA_DIR/log/$s.log ]]; then
                tail -n 8 "$DATA_DIR/log/$s.log" || true
            fi
        } | grep -v '^[[:space:]]*$' | cut -c1-$(( UI_W - 4 )) | sed 's/^/    /' >&4 || ui_line '  暂无日志'
    done <<< "$(wanted_services)"
    ui_rule
}

sni_pool_file() {
    if state_ok; then printf '%s' "$SNI_POOL_FILE"; else printf '%s' "$STAGE/sni-pool.txt"; fi
}

POOL=()

pool_build() {
    local i f
    f=$(sni_pool_file)
    mapfile -t POOL < <(sni_pool)
    if [[ -f $f ]]; then ui_page '候选站点' '自定义列表'; else ui_page '候选站点' '默认列表'; fi
    ui_hint $'自动挑选伪装站点时，会同时测速这些网站，\n选出可用且最快的一个。'
    ui_blank
    KEY_W=${#POOL[@]}
    KEY_W=${#KEY_W}
    for i in "${!POOL[@]}"; do tui_item $(( i + 1 )) "${POOL[$i]}" '' '' '回车可以把它从列表里删除。'; done
    ui_blank
    tui_item a '添加站点' '' '' '添加一个支持 TLS 1.3 和 HTTP/2 的网站域名。'
    if [[ -f $f ]]; then tui_item r '恢复默认' '' '' '删除自定义列表，改回脚本自带的列表。'; fi
    TUI_HELP_H=1
    TUI_FOOT='上下键 移动   回车 选择   Esc 返回'
    if [[ -f $f ]]; then TUI_FOOT_PLAIN='编号 删除   a 添加   r 恢复默认   回车 返回'
    else TUI_FOOT_PLAIN='编号 删除   a 添加   回车 返回'; fi
}

edit_sni_pool() {
    local d key f sel=0
    local -a rest=()
    f=$(sni_pool_file)
    while :; do
        tui_menu pool_build "$sel" ''
        sel=$TUI_CUR
        [[ $TUI_KEY == ENTER ]] || return 0
        key=${TUI_IKEYS[$TUI_CUR]}
        case $key in
            a)
                input_page '添加站点' '' '只填域名，例如 www.example.com。'
                read_line '域名（回车取消）：' d
                [[ -n $d ]] || continue
                d=${d,,}
                if ! valid_domain "$d"; then TUI_MSG='格式不对：只填域名，例如 www.example.com。'; (( TUI )) || ui_warn "$TUI_MSG"; continue; fi
                in_list "$d" "${POOL[@]}" && continue
                printf '%s\n' "${POOL[@]}" "$d" | atomic_write "$f" 600 ;;
            r)
                ask_no '删除自定义列表，恢复默认' && rm -f -- "$f" ;;
            *)
                if (( ${#POOL[@]} == 1 )); then TUI_MSG='列表里至少要留一个站点。'; (( TUI )) || ui_warn "$TUI_MSG"; continue; fi
                ask_no "从列表里删除 ${POOL[$((key - 1))]}" || continue
                rest=("${POOL[@]}")
                unset "rest[$(( key - 1 ))]"
                printf '%s\n' "${rest[@]}" | atomic_write "$f" 600
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


action_uninstall() {
    local own_user=0 p
    local -a progs=()
    ui_page '卸载'
    if ! state_ok; then
        if [[ -e $STATE || -e $CONFIG_FILE || -e $XRAY_BIN || -e $SS_BIN ]]; then
            ui_warn '找到了部署留下的文件，但状态记录无法识别（损坏，或是别的版本的脚本写的）。'
            ui_note '为避免只删一半，这里不做卸载。请用安装时那个版本的脚本卸载，或先恢复状态文件：'
            ui_code "  $STATE"
            return 1
        fi
        ui_line '没有检测到本脚本部署的服务。'
        if [[ -f $SELF_SCRIPT_PATH || -f $QUICK_BIN ]]; then
            ui_rule
            if ask_no '只删除脚本本身和 zxray 命令'; then
                remove_self_files
                ui_ok '已删除。'
                exit 20
            fi
            exit "$RC_QUIET"
        fi
        return 0
    fi
    DRAFT=$STATE
    cp -f "$DATA_DIR/sources.ndjson" "$STAGE/sources.ndjson" 2>/dev/null || : > "$STAGE/sources.ndjson"
    if [[ -n $SOURCE_PATH && -f $SOURCE_PATH && $SOURCE_PATH != "$SELF_DIR"/* && $SOURCE_PATH != /proc/* && $SOURCE_PATH != /dev/* ]] \
        && grep -q "$SCRIPT_MARKER" "$SOURCE_PATH" 2>/dev/null; then
        jq -cn --arg p "$SOURCE_PATH" --arg h "$(sha256_of "$SOURCE_PATH")" '{path:$p, sha256:$h}' >> "$STAGE/sources.ndjson"
    fi
    ui_hint '会删除下面这些内容，客户端将无法再连接：'
    ui_blank
    ui_kv '节点' "$(jq 'length' "$NODES_JSON" 2>/dev/null || echo 0) 条" '链接和配置全部删除'
    while read -r p; do [[ -z $p ]] || progs+=("$(svc_label "$p")"); done <<< "$(wanted_services)"
    ui_kv '程序' "$(join_by '、' "${progs[@]}")"
    ui_kv '系统改动' "$(uninstall_changes)"
    ui_kv '本脚本' 'zxray 命令和脚本文件'
    if [[ -s $STAGE/sources.ndjson ]]; then
        local lab='下载的脚本'
        while IFS= read -r p; do ui_kv "$lab" "$p"; lab=''; done < <(jq -r '.path' "$STAGE/sources.ndjson" 2>/dev/null | sort -u)
    fi
    ui_rule
    ask_no '确定完整卸载' || exit "$RC_QUIET"
    if [[ $(jq -r '.meta.created_user // 0' "$STATE" 2>/dev/null) == 1 ]]; then own_user=1; fi
    STEP_NO=0 STEP_TOTAL=3
    ui_blank
    ui_step '停止服务'
    : > "$STEP_LOG"
    stop_owned_services
    ui_step_done
    ui_step '清理系统改动'
    : > "$STEP_LOG"
    fw_remove_recorded "$STATE"
    state_update '.meta.fw_rules = []'
    release_nginx_packages || true
    release_extra_packages "$STATE"
    state_update '.meta.extra_packages = []'
    if is_managed_file "$SYSCTL_FILE"; then rm -f -- "$SYSCTL_FILE"; fi
    restore_bbr_original
    if (( own_user )); then remove_service_user; state_update '.meta.created_user = 0'; fi
    ui_step_done
    ui_step '删除文件和脚本'
    : > "$STEP_LOG"
    cp -f "$STATE" "$STAGE/state-old.json"
    tx_begin
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
    delete_recorded_sources
    remove_self_files
    jq -r '.meta.created_dirs // [] | .[]' "$STAGE/state-old.json" 2>/dev/null | remove_created_dirs
    ui_step_done
    ui_ok '卸载完成。curl、jq 等通用工具没有删除。'
    exit 20
}

state_update() {
    jq "$1" "$STATE" > "$STAGE/state-upd.json"
    atomic_install "$STAGE/state-upd.json" "$STATE" 600
}

uninstall_changes() {
    local -a o=()
    if is_managed_file "$SYSCTL_FILE"; then o+=('BBR 设置'); fi
    if [[ $(jq -r '.meta.fw_rules // [] | length' "$STATE") != 0 ]]; then o+=('防火墙规则'); fi
    if [[ $(jq -r '(.meta.nginx_packages // []) + (.meta.extra_packages // []) | length' "$STATE") != 0 ]]; then o+=('安装的软件包'); fi
    if [[ $(jq -r '.meta.created_user // 0' "$STATE") == 1 ]]; then o+=("用户 $SERVICE_USER"); fi
    (( ${#o[@]} )) || o=('无')
    join_by '、' "${o[@]}"
}

remove_self_files() {
    local d
    rm -rf -- "$SELF_DIR" "$DATA_DIR"
    if is_managed_file "$QUICK_BIN"; then rm -f -- "$QUICK_BIN"; fi
    for d in "$STAGE_BASE".*; do
        [[ -d $d && $d != "$STAGE" ]] && rm -rf -- "$d"
    done
    rm -f -- "$LOCK_FILE"
}

delete_recorded_sources() {
    local rec path sha
    [[ -f $STAGE/sources.ndjson ]] || return 0
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

不带选项时打开交互主页。

选项：
  --install            安装（加 --yes 时全部使用默认设置）
  --scheme 方案        指定方案，可选：
                       reality-raw  reality-xhttp  reality-split  ss
                       enc  dual  triple  enc-split
  --core-version 版本  安装时的 Xray 版本：compat（兼容版，默认）、
                       latest（最新版）或版本号，例如 v26.7.28
  --update             更新脚本和核心，节点不变
  --nodes              输出节点链接
  --uninstall          完整卸载
  --yes                跳过所有确认
  --force              同 --yes，并允许覆盖已有安装
  --version            显示脚本版本
  --help               显示本帮助
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
                if [[ $CLI_CORE_TAG != compat && $CLI_CORE_TAG != latest ]]; then
                    [[ $CLI_CORE_TAG =~ ^v?[0-9]+(\.[0-9]+){1,3}$ ]] || fatal "--core-version 格式不对：$CLI_CORE_TAG"
                    ver_ge "${CLI_CORE_TAG#v}" "$XRAY_MIN_VERSION" || fatal "--core-version 最低 v$XRAY_MIN_VERSION。"
                    CLI_CORE_TAG=$(normalize_tag "$CLI_CORE_TAG")
                fi
                shift ;;
            --version|-V) printf 'Xray Manager v%s\n' "$SCRIPT_VERSION"; exit 0 ;;
            *) fatal "未知参数：$1（--help 查看用法）" ;;
        esac
        shift
    done
    if [[ ( -n $CLI_SCHEME || -n $CLI_CORE_TAG ) && $ACTION == menu ]]; then ACTION=install; fi
    return 0
}

action_install_cli() {
    if foreign_install_present; then foreign_install_hint; return 1; fi
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
    if state_ok; then
        local s any=0
        DRAFT=$STATE
        while read -r s; do
            [[ -n $s ]] || continue
            any=1
            svc_active "$s" || return 1
        done <<< "$(wanted_services)"
        (( any ))
    else
        return 1
    fi
}

home_alerts() {
    local proto port label kind f rv xv
    local -a a=() ports=()
    if ! system_running; then
        a+=('服务没有在运行，可在「更新与维护」里重启')
    else
        while read -r proto port label; do
            [[ -n $port ]] || continue
            port_listening "$proto" "$port" || a+=("${proto^^} $port（$label）没有在监听")
        done <<< "$(public_ports)"
    fi
    kind=$(fw_kind)
    if [[ -n $kind ]]; then
        mapfile -t ports < <(fw_wanted)
        for f in "${ports[@]}"; do
            [[ -n $f ]] || continue
            fw_has "$kind" "$f" || { a+=("本机 $kind 还没放行 $f"); break; }
        done
    fi
    f=$DATA_DIR/update-check.json
    if [[ -f $f ]]; then
        rv=$(jq -r '.script // empty' "$f" 2>/dev/null || true)
        if [[ -n $rv ]] && ! ver_ge "$SCRIPT_VERSION" "$rv"; then a+=("有新版脚本 v$rv，可在「更新与维护」里更新"); fi
        xv=$(jq -r '.xray // empty' "$f" 2>/dev/null || true)
        if [[ -n $xv && $(st .core.xray) == latest && -n $(installed_version xray) ]] && ! ver_ge "$(installed_version xray)" "$xv"; then
            a+=("Xray 有新版本 $xv，可在「更新与维护」里更新")
        fi
    fi
    for f in "${a[@]}"; do ui_kv '' "$C_YELLOW! $f$C_RESET"; done
}

proc_pid() {
    local d
    [[ -e $1 ]] || return 1
    for d in /proc/[0-9]*; do
        if [[ $d/exe -ef $1 ]]; then printf '%s' "${d#/proc/}"; return 0; fi
    done
    return 1
}

proc_uptime() {
    local st up hz
    local -a fs=()
    read -r st 2>/dev/null < "/proc/$1/stat" || return 1
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
    done 2>/dev/null < "/proc/$1/status"
    return 1
}

tcp_conn_count() {
    local ports
    ports=$(public_ports | awk '$1 == "tcp" {printf " %s", $2}')
    [[ -n $ports ]] || { printf '0'; return 0; }
    ss -Htn state established 2>/dev/null | awk -v ps="$ports " '{n = split($3, a, ":"); if (index(ps, " " a[n] " ")) c++} END {print c + 0}'
}

home_status() {
    local host v4 v6 bin name ver pid up mem conn res=''
    host=$(st .net.host) v4=$(st .net.v4) v6=$(st .net.v6)
    ui_kv '方案' "$(scheme_label "$(scheme)")"
    if scheme_is_split "$(scheme)"; then
        ui_kv '节点' "$(node_name)"
        ui_cont_kv "IPv4 ${v4:-无}"
        ui_cont_kv "IPv6 ${v6:-无}"
    else
        ui_kv '节点' "$(node_name)" "$host"
        if [[ $host == "$v4" && -n $v6 ]]; then ui_cont_kv "$C_DIM$v6$C_RESET"
        elif [[ $host == "$v6" && -n $v4 ]]; then ui_cont_kv "$C_DIM$v4$C_RESET"
        elif [[ $host != "$v4" && $host != "$v6" ]]; then
            [[ -z $v4 ]] || ui_cont_kv "${C_DIM}IPv4 $v4$C_RESET"
            [[ -z $v6 ]] || ui_cont_kv "${C_DIM}IPv6 $v6$C_RESET"
        fi
    fi
    if needs_ss_rust; then bin=$SS_BIN name=SS-Rust ver=$(installed_version ss)
    else bin=$XRAY_BIN name=Xray ver=$(installed_version xray); fi
    pid=$(proc_pid "$bin" || true)
    if system_running; then
        up=''
        [[ -z $pid ]] || up=$(proc_uptime "$pid" || true)
        if [[ -n $up ]]; then ui_kv '状态' "${C_GREEN}运行中${C_RESET}" "已运行 $(human_uptime "$up")"
        else ui_kv '状态' "${C_GREEN}运行中${C_RESET}"; fi
    else
        ui_kv '状态' "${C_YELLOW}已停止${C_RESET}"
    fi
    res="$name ${ver:-未知}"
    if [[ -n $pid ]]; then
        mem=$(proc_rss_mb "$pid" || true)
        conn=$(tcp_conn_count || true)
        [[ -z $mem ]] || kv_append res "  ${C_DIM}内存$C_RESET $mem MB"
        [[ -z $conn ]] || kv_append res "  ${C_DIM}连接$C_RESET $conn"
    fi
    ui_kv '核心' "$res"
}

kv_append() {
    local __ka_w
    str_width "${!1}$2" __ka_w
    (( __ka_w > UI_W - 2 - LABEL_W )) || printf -v "$1" '%s%s' "${!1}" "$2"
}

ui_cont_kv() {
    local pad fitted
    printf -v pad '%*s' $(( LABEL_W + 2 )) ''
    fit_width "$1" $(( UI_W - 2 - LABEL_W )) fitted
    ui_emit "$pad$fitted"
}

home_build() {
    ui_banner
    ui_blank
    if state_ok; then
        DRAFT=$STATE
        home_status
        home_alerts
    else
        ui_kv '状态' '未安装'
    fi
    ui_rule
    if state_ok; then
        tui_item 1 '修改配置' '' '查看或调整当前节点的设置'
        tui_item 2 '节点链接' '' '查看链接、二维码，复制到剪贴板'
        tui_item 3 '更新与维护' '' '更新、重启、运行状态、回滚'
    else
        tui_item 1 '安装' '' '选择方案并部署节点'
        tui_item 2 '节点链接' '' '安装后可用'
        tui_item 3 '更新与维护' '' '安装后可用'
    fi
    tui_item 4 '卸载' '' '删除本脚本部署的全部内容'
    tui_item 0 '退出'
    TUI_FOOT='上下键 移动   回车 确认   q 退出'
    TUI_FOOT_PLAIN='1-4 选择   0 退出'
}

update_check_bg() {
    state_ok || return 0
    [[ -d $DATA_DIR ]] || return 0
    local f=$DATA_DIR/update-check.json age
    if [[ -f $f ]]; then
        age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
        (( age >= 86400 )) || return 0
    fi
    (
        trap - ERR INT TERM HUP EXIT
        set +e
        s='' x=''
        body=$(curl --proto '=https' -fsSL --connect-timeout 10 --max-time 30 "$SCRIPT_REMOTE_URL" 2>/dev/null)
        if grep -q "$SCRIPT_MARKER" <<< "$body"; then
            s=$(awk -F'"' '/^readonly SCRIPT_VERSION=/{print $2; exit}' <<< "$body")
        fi
        if [[ $(jq -r '.core.xray // empty' "$STATE" 2>/dev/null) == latest ]]; then x=$(STEP_LOG=/dev/null xray_newest_tag); fi
        [[ -n $s || -n $x ]] || exit 0
        [[ -d $DATA_DIR ]] || exit 0
        tmp=$(mktemp "$DATA_DIR/.update-check.XXXXXX") || exit 0
        jq -n --arg s "$s" --arg x "$x" '{script: $s, xray: $x}' > "$tmp" && chmod 600 "$tmp" && mv -f -- "$tmp" "$f"
        rm -f -- "$tmp"
    ) </dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 9>&- &
    disown 2>/dev/null || true
}

on_main_int() {
    (( CHILD_RUNNING )) && return 0
    printf '\n'
    exit 130
}

on_main_exit() {
    tui_cursor on
    tty_echo echo
}

run_top() {
    run_child "$@"
    TOP_RC=$CHILD_RC
    TOP_QUIET=0
    if (( TOP_RC == RC_QUIET )); then TOP_RC=0 TOP_QUIET=1; fi
}

after_action() {
    local rc=$1
    case $rc in
        20) exit 0 ;;
        21|23) ui_pause; on_main_exit; exec bash "$SELF_SCRIPT_PATH" ;;
    esac
    if [[ -e $TX ]]; then
        ui_err '有一次操作没能恢复完，重新运行脚本会继续恢复。'
        ui_note "快照目录：$TX"
        exit 1
    fi
    return 0
}

main() {
    parse_args "$@"
    (( EUID == 0 )) || fatal '请用 root 运行（例如 sudo sh xray-manager.sh）。'
    input_setup
    ui_setup
    detect_system || exit 1
    ensure_deps || exit 1
    if [[ ${ZX_REEXEC:-0} != 1 ]]; then acquire_lock; fi
    trap 'on_main_int' INT
    trap 'exit 143' TERM HUP
    trap 'on_main_exit' EXIT
    SOURCE_PATH=${BASH_SOURCE[0]}
    if [[ -f $SOURCE_PATH ]]; then SOURCE_PATH=$(readlink -f -- "$SOURCE_PATH"); fi
    tx_recover_if_needed
    migrate_state
    check_state_file
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

    local sel=0
    trap 'TUI_RESIZED=1' WINCH
    update_check_bg
    while :; do
        tui_menu home_build "$sel" q
        sel=$TUI_CUR
        case $TUI_KEY in
            q) ui_clear; exit 0 ;;
            ENTER) ;;
            *) continue ;;
        esac
        case ${TUI_IKEYS[$TUI_CUR]} in
            1) run_top action_install ;;
            2) run_top action_nodes; after_action "$TOP_RC"; continue ;;
            3) run_top action_maintain; after_action "$TOP_RC"; continue ;;
            4) run_top action_uninstall ;;
            0) ui_clear; exit 0 ;;
        esac
        after_action "$TOP_RC"
        if (( TOP_RC != 130 && ! TOP_QUIET )); then ui_pause; fi
    done
}

if [[ ${BASH_SOURCE[0]:-} == "$0" ]]; then main "$@"; fi
