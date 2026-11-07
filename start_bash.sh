#!/system/bin/sh
# /data/adb/launch.sh —— Magisk root 下按包名一键启动应用
#
# 用法:
#   su -c "/data/adb/launch.sh <包名>"            # 解析 launcher 并拉起
#   su -c "/data/adb/launch.sh --list"            # 全量 pm list packages
#   su -c "/data/adb/launch.sh --list <包名关键词>" # pm list | grep 关键词
#   su -c "TOUT=15 /data/adb/launch.sh <包名>"    # 自定义超时(秒)
#
# 不做开机自启，不碰 service.d，不 read、不等待 tty 输入。
#
# 安全约束：
#   1. 零输入：stdin 全程重定向 /dev/null
#   2. 无 tty 安全：不假定 fd 可读，所有输出可丢弃
#   3. 每个可能阻塞的 android 命令都走 wt() 限时强杀，默认 8s
#   4. 已运行只切前台，不重建实例

# ---- 临时目录：真机 /data/local/tmp，沙盒/Recovery 自动降级 ----
_mktmp() {
    local d="${TMPDIR:-/data/local/tmp}"
    if [[ -d "$d" && -w "$d" ]]; then echo "$d"; return; fi
    d="$(mktemp -d 2>/dev/null)"
    if [[ -n "$d" && -d "$d" ]]; then echo "$d"; return; fi
    mkdir -p /tmp 2>/dev/null && echo /tmp
}

# ---- 限时执行器：后台跑 + 秒级收割，超时连进程一起杀 ----
# 用法: wt <秒> <cmd> [args...]
#   返回命令自身退出码；超时返回 124（并强杀进程）。
#   注意：<cmd> 里不要带管道，否则 $? 取的是管道尾的码。
wt() {
    local t=$1; shift
    local p c=0
    "$@" </dev/null &>/dev/null &
    p=$!
    while (( c < t )) && kill -0 "$p" 2>/dev/null; do
        sleep 1; (( c++ ))
    done
    if kill -0 "$p" 2>/dev/null; then
        kill -9 "$p" 2>/dev/null; sleep 1
        return 124
    fi
    wait "$p" 2>/dev/null
    return "${?:-124}"
}

# ---- 把 pm list 结果落到文件：规避“命令+管道”的 wt 取码问题 ----
_pmlist() {
    local out="$1"
    # 先试 cmd package（Android 8+），失败降级 pm
    # 用 exec 3 落地，规避“命令输出被吞/管道丢行”的 toybox 差异
    exec 3>"$out"
    if ! cmd package list packages >&3 2>/dev/null; then
        pm list packages >&3 2>/dev/null
    fi
    exec 3>&-
}

set -u
export TMPDIR="$(_mktmp)"
# 故意不 set -e：单步失败不能让调用方拿到非零

ACTION="launch"
PKG=""
TOUT="${TOUT:-8}"

# ---- 工具链自检：am / cmd / monkey 任一缺失 -> exit 127 ----
# 127 = command not found，上层(按键映射/Tasker/联动脚本)可据此判断环境异常
_missing=0
for _t in am cmd monkey; do
    if ! command -v "$_t" >/dev/null 2>&1; then
        echo "✗ 找不到命令: $_t（PATH=$(echo "$PATH" | cut -c1-80)）" >&2
        _missing=1
    fi
done
if [[ "$_missing" -eq 1 ]]; then
    echo "abort: 缺少 android 工具链(am/cmd/monkey)，请在 Android 中以 root 运行" >&2
    exit 127
fi

while (( $# )); do
    case "$1" in
        --list)
            ACTION="list"
            shift
            # 只跟一个非选项参数当作 grep 关键词
            if (( $# )) && [[ "$1" != -* ]]; then
                PKG="$1"; shift
            fi
            ;;
        --timeout=*) TOUT="${1##*=}"; shift ;;
        --) shift; if (( ! $# )); then :; else PKG="${PKG:-$1}"; shift; fi ;;
        -*)
            echo "未知选项: $1" >&2; exit 2 ;;
        *)
            PKG="${PKG:-$1}"; shift ;;
    esac
done

# ==================== --list 分支：查完即退出 ====================
if [[ "$ACTION" == "list" ]]; then
    _pmlist "$TMPDIR/.pl.$$"
    if [[ ! -s "$TMPDIR/.pl.$$" ]]; then
        rm -f "$TMPDIR/.pl.$$"
        echo "✗ pm list 无输出（可能 pm/cmd 未就绪，或不在 Android 环境）" >&2
        exit 2
    fi
    if [[ -n "$PKG" ]]; then
        # grep 同样限时；无命中时返回 1，但不视为脚本失败
        grep -i -- "$PKG" "$TMPDIR/.pl.$$" > "$TMPDIR/.plg.$$" 2>/dev/null
        if [[ -s "$TMPDIR/.plg.$$" ]]; then
            cat "$TMPDIR/.plg.$$"
            rm -f "$TMPDIR/.pl.$$" "$TMPDIR/.plg.$$"
            exit 0
        else
            echo "✗ 没有匹配 \"$PKG\" 的包（已列出全部供对照）:" >&2
            cat "$TMPDIR/.pl.$$" >&2
            rm -f "$TMPDIR/.pl.$$" "$TMPDIR/.plg.$$"
            exit 1
        fi
    else
        cat "$TMPDIR/.pl.$$"
        rm -f "$TMPDIR/.pl.$$"
    fi
    exit 0
fi

# ==================== 启动分支 ====================
if [[ -z "$PKG" ]]; then
    echo "launch.sh: 缺包名，用法: su -c '/data/adb/launch.sh <包名>'" >&2
    echo "           su -c '/data/adb/launch.sh --list [关键词]'" >&2
    exit 1
fi

# ---- 已运行：只切前台，不重启 ----
if pid="$(pidof "$PKG" 2>/dev/null)" && [[ -n "$pid" ]]; then
    if wt "$TOUT" am set-focused-task "$pid"; then
        echo "→ 已切前台: $PKG (pid $pid)"
        exit 0
    fi
    # set-focused-task 在老版本 am 上不存在，降级走 clear-top
    wt "$TOUT" cmd package resolve-activity --brief "$PKG" > "$TMPDIR/.la2.$$" 2>/dev/null
    act="$(tail -1 "$TMPDIR/.la2.$$" 2>/dev/null; rm -f "$TMPDIR/.la2.$$")"
    wt "$TOUT" am start -n "$act" --activity-clear-top --activity-new-task
    echo "→ 已切前台(降级): $PKG"
    exit 0
fi

# ---- 冷启动：解析 launcher，失败走 monkey 兜底 ----
wt "$TOUT" cmd package resolve-activity --brief "$PKG" > "$TMPDIR/.la.$$" 2>/dev/null
act="$(tail -1 "$TMPDIR/.la.$$" 2>/dev/null; rm -f "$TMPDIR/.la.$$")"

case "$act" in
    "no activity found"|"null"|"")
        if wt "$TOUT" monkey -p "$PKG" -c android.intent.category.LAUNCHER 1; then
            echo "→ monkey 兜底启动: $PKG"
            exit 0
        fi
        echo "✗ 解析不到启动页，monkey 也失败: $PKG" >&2
        exit 2
        ;;
    *)
        if wt "$TOUT" am start -n "$act" --activity-clear-top --activity-new-task; then
            echo "→ 启动 $act"
            exit 0
        fi
        echo "✗ am start 超时/失败: $act" >&2
        exit 3
        ;;
esac
