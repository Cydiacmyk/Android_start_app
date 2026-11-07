#!/system/bin/sh
# launch.sh —— root 下按包名一键启动 Android 应用 (POSIX sh, 无 bash 依赖)
# 用法: su -c "/path/to/launch.sh <包名>"          启动/切前台
#       su -c "TOUT=15 launch.sh <包名>"           自定义超时(默认8s)
#       su -c "launch.sh --list"                   全量包名(去 package: 前缀)
#       su -c "launch.sh --list <关键词>"          忽略大小写模糊匹配
#       su -c "launch.sh --list --raw"             保留 package: 前缀
# 退出码: 0 成功 | 1 参数/无命中 | 2 pm未就绪 | 3 am失败 | 4 超时 | 127 缺工具
# 铁律: 零输入(< /dev/null)、无 tty 安全、每个 android 命令都限时强杀，绝不卡调用方。
# 不提供 --boot，不写 service.d；开机自启请你的模块自己包一层。

set -u

# ---------- 环境 ----------
_mktmp() {
	_d="${TMPDIR:-/data/local/tmp}"
	[ -d "$_d" ] && [ -w "$_d" ] && echo "$_d" && return
	_d="$(mktemp -d 2>/dev/null)"
	[ -n "$_d" ] && [ -d "$_d" ] && echo "$_d" && return
	mkdir -p /tmp 2>/dev/null && echo /tmp
}

_have() { command -v "$1" >/dev/null 2>&1; }

# 工具只探一次，缺就 127。cmd 是 Android 8+ 的，没有直接判死刑。
_probe() {
	[ -n "${_ok+x}" ] && return "$_rc"
	if _have pm && _have cmd && _have am && _have monkey && _have grep && _have sed && _have mktemp; then
		_rc=0
	else
		_rc=127
	fi
	_ok=x; return "$_rc"
}

die127() {
	echo "✗ 缺 Android 运行时工具，PATH=$PATH" >&2
	_have pm     || echo "    缺失: pm"     >&2
	_have cmd    || echo "    缺失: cmd"    >&2
	_have am     || echo "    缺失: am"     >&2
	_have monkey || echo "    缺失: monkey" >&2
	exit 127
}

# ---------- 限时执行器 ----------
# wt <秒> <cmd> [args...]  超时返回 124；别传管道，管道会吞 $?
# 轮询用短 sleep（默认 0.3s），设 SHORT=1 则完全不 sleep，供无 sleep 环境/CI 使用
wt() {
	_t="$1"; shift
	"$@" </dev/null >/dev/null 2>&1 &
	_p=$!; _c=0; _iv=${SHORT:+0}; _iv=${_iv:-3}
	while [ "$_c" -lt "$_t" ] && kill -0 "$_p" 2>/dev/null; do
		[ "$_iv" -gt 0 ] 2>/dev/null && sleep 0.$_iv
		_c=$((_c+1))
	done
	if kill -0 "$_p" 2>/dev/null; then
		kill -9 "$_p" 2>/dev/null; return 124
	fi
	wait "$_p" 2>/dev/null; return ${?:-124}
}

# ---------- --list ----------
_pmlist() {
	wt "$TOUT" pm list packages > "$1" 2>/dev/null || return 2
	[ -s "$1" ] && return 0
	return 2
}

do_list() {
	_raw=0; _kw=""
	for _a in "$@"; do
		case "$_a" in --raw) _raw=1 ;; -*) ;; *) _kw="$_a" ;; esac
	done
	_f="$_TMP/pm.$$"
	_pmlist "$_f" || { echo "✗ pm list 失败，可能 pm 未就绪(Recovery?)" >&2; rm -f "$_f"; exit 2; }

	if [ -z "$_kw" ]; then
		[ "$_raw" = 1 ] && cat "$_f" || sed 's/^package://' "$_f"
		rm -f "$_f"; exit 0
	fi

	_hit=0
	if [ "$_raw" = 1 ]; then
		grep -i -- "$_kw" "$_f" && _hit=1
	else
		sed 's/^package://' "$_f" | grep -i -- "$_kw" && _hit=1
	fi
	if [ "$_hit" = 1 ]; then rm -f "$_f"; exit 0; fi

	echo "✗ 无匹配 '$_kw'，已安装如下:" >&2
	sed 's/^package://' "$_f" | head -30 >&2
	rm -f "$_f"; exit 1
}

# ---------- 启动 ----------
resolve() { wt "$TOUT" cmd package resolve-activity --brief "$PKG" > "$1" 2>/dev/null; return $?; }

do_launch() {
	_pid="$(pidof "$PKG" 2>/dev/null)"
	if [ -n "$_pid" ]; then
		wt "$TOUT" am set-focused-task "$_pid" && { echo "→ 切前台: $PKG (pid $_pid)"; exit 0; }
		_f="$_TMP/act.$$"; resolve "$_f"; _act="$(tail -1 "$_f"; rm -f "$_f")"
		wt "$TOUT" am start -n "$_act" --activity-clear-top --activity-new-task && \
			{ echo "→ 切前台(降级): $PKG"; exit 0; }
		echo "✗ 进程在($_pid)但切前台失败" >&2; exit 3
	fi

	_f="$_TMP/act.$$"; resolve "$_f"; _rc=$?; _act="$(tail -1 "$_f"; rm -f "$_f")"
	case "$_act" in
	"no activity found"|"null"|"")
		[ "$_rc" = 124 ] && { echo "✗ 解析启动页超时" >&2; exit 4; }
		wt "$TOUT" monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 && \
			{ echo "→ monkey 兜底启动: $PKG"; exit 0; }
		echo "✗ 无启动页且 monkey 失败，先用 --list 确认包名" >&2; exit 2 ;;
	*)
		wt "$TOUT" am start -n "$_act" --activity-clear-top --activity-new-task && \
			{ echo "→ 启动 $_act"; exit 0; }
		[ "${STRICT:-0}" = 1 ] && { echo "✗ am 超时(STRICT=1)" >&2; exit 4; }
		echo "✗ am start 失败(活动未导出?): $_act" >&2; exit 3 ;;
	esac
}

# ---------- main ----------
TOUT="${TOUT:-8}"; _TMP="$(_mktmp)"
trap 'rm -f "$_TMP"/act.$$ "$_TMP"/pm.$$' EXIT
_probe || die127

case "${1:-}" in
--list|list) shift; do_list "$@" ;;
-h|--help|"")
	cat >&2 <<'EOF'
launch.sh —— root 下一键启动 Android 应用 (POSIX sh)

  launch.sh <包名>            启动 / 切前台
  launch.sh --list            全量包名
  launch.sh --list <关键词>    忽略大小写匹配
  launch.sh --list --raw       保留 package: 前缀
  TOUT=8 超时秒数 | STRICT=1 超时也返回 4
退出码: 0 成功 | 1 参数/无命中 | 2 pm未就绪 | 3 am失败 | 4 超时 | 127 缺工具
EOF
	[ -n "${1:-}" ]; exit $? ;;  # --help 0, 空参数 1
*) PKG="$1"; shift; do_launch "$@" ;;
esac
