#!/usr/bin/env bash
# ==========================================================================
#  Gemtek W1700K（Airoha AN7581 / OpenWrt U-Boot + UBI 布局）固件一键编译
#
#  用法：
#    ./scripts/build.sh                      # 默认配置，包含全部插件
#    ENABLE_OPENCLASH=0 ./scripts/build.sh   # 关掉某个插件
#    OPENWRT_REF=<commit> ./scripts/build.sh # 固定上游 commit
#
#  环境变量：
#    OPENWRT_REPO   源码仓库，默认 https://github.com/openwrt/openwrt.git
#    OPENWRT_REF    分支或 commit，默认 main（本机型只存在于 main）
#    SRC_DIR        源码目录，默认 <工程目录>/openwrt
#    ARTIFACT_DIR   产物目录，默认 <工程目录>/artifacts
#    JOBS           并行度，默认 nproc
#    MAX_RETRY      第三方插件编译失败时的重试次数，默认 4
# ==========================================================================
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/openwrt/openwrt.git}"
OPENWRT_REF="${OPENWRT_REF:-main}"
SRC_DIR="${SRC_DIR:-$PROJECT_DIR/openwrt}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$PROJECT_DIR/artifacts}"
LOG_DIR="$PROJECT_DIR/logs"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
MAX_RETRY="${MAX_RETRY:-4}"
DISABLED_FILE="$PROJECT_DIR/configs/disabled.auto"
REPORT="$ARTIFACT_DIR/BUILD-REPORT.md"

# 允许在编译失败后自动跳过的第三方包（其他任何包失败都会直接终止，避免生成残废固件）
DROPPABLE_FEEDS="turboacc openclash luci-theme-argon luci-app-argon-config luci-app-airoha-npu luci-app-wifi7"
DROPPABLE_PKGS="luci-app-turboacc luci-theme-argon luci-app-argon-config luci-app-openclash luci-app-airoha-npu luci-app-wifi7 luci-app-wifimgr"

# 需要出现在最终 .config 里的关键项（缺失只警告，不会中断）
KEY_SYMBOLS="
CONFIG_TARGET_airoha_an7581_DEVICE_gemtek_w1700k-ubi
CONFIG_PACKAGE_luci-app-turboacc
CONFIG_PACKAGE_luci-theme-argon
CONFIG_PACKAGE_luci-app-argon-config
CONFIG_PACKAGE_luci-app-upnp
CONFIG_PACKAGE_luci-app-sqm
CONFIG_PACKAGE_luci-app-airoha-npu
CONFIG_PACKAGE_luci-app-openclash
CONFIG_PACKAGE_luci-app-wifi7
"

mkdir -p "$LOG_DIR" "$ARTIFACT_DIR"

info()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn()  { printf '\033[1;33m[警告]\033[0m %s\n' "$*"; }
step()  { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }
die()   { printf '\033[1;31m[失败]\033[0m %s\n' "$*"; exit 1; }

command -v make    >/dev/null || die "没找到 make，请先安装编译依赖（见 README 第 2 节）"
command -v gcc     >/dev/null || die "没找到 gcc，请先安装编译依赖（见 README 第 2 节）"
case "$(uname -s)" in
	Linux) ;;
	*) die "OpenWrt 只支持在 Linux（或 WSL2）上编译，当前系统：$(uname -s)" ;;
esac

# --------------------------------------------------------------------------

prepare_src() {
	mkdir -p "$SRC_DIR"
	if [ -d "$SRC_DIR/.git" ]; then
		info "已存在源码目录，更新到 $OPENWRT_REF"
		git -C "$SRC_DIR" fetch --depth 1 origin "$OPENWRT_REF" >/dev/null 2>&1 \
			|| die "git fetch $OPENWRT_REF 失败（检查网络或参考名）"
		git -C "$SRC_DIR" checkout -f FETCH_HEAD >/dev/null 2>&1 || die "git checkout 失败"
	else
		info "浅克隆 openwrt（$OPENWRT_REF，约 1～2 GB）"
		if ! git clone --depth 1 --branch "$OPENWRT_REF" "$OPENWRT_REPO" "$SRC_DIR" >/dev/null 2>&1; then
			warn "按分支克隆失败，尝试按 commit 抓取"
			rm -rf "$SRC_DIR"
			mkdir -p "$SRC_DIR"
			git -C "$SRC_DIR" init -q
			git -C "$SRC_DIR" remote add origin "$OPENWRT_REPO"
			git -C "$SRC_DIR" fetch --depth 1 origin "$OPENWRT_REF" >/dev/null 2>&1 \
				|| die "无法获取 $OPENWRT_REF"
			git -C "$SRC_DIR" checkout -f FETCH_HEAD >/dev/null 2>&1 || die "git checkout 失败"
		fi
	fi
	info "源码版本：$(git -C "$SRC_DIR" log -1 --format='%h %ad %s' --date=short)"
	printf '%s\n' "$OPENWRT_REF" > "$ARTIFACT_DIR/.openwrt-ref"
}

setup_feeds() {
	cp -f "$PROJECT_DIR/feeds.conf.default" "$SRC_DIR/feeds.conf.default"
	info "更新 feeds（官方 4 个 + 第三方 5 个）"
	( cd "$SRC_DIR" && ./scripts/feeds update -a ) >"$LOG_DIR/feeds-update.log" 2>&1 \
		|| { tail -30 "$LOG_DIR/feeds-update.log"; die "feeds update 失败"; }
	( cd "$SRC_DIR" && ./scripts/feeds install -a ) >"$LOG_DIR/feeds-install.log" 2>&1 \
		|| warn "feeds install 有报错（见 logs/feeds-install.log，继续执行）"

	# 修正第三方单包仓库里的相对 include，例如 rchen14b/luci-app-airoha-npu 的
	#   include ../../luci.mk
	# 当它作为独立 feed 时该相对路径会指到源码根目录，必须改成绝对引用。
	local f
	while IFS= read -r f; do
		case "$f" in
			"$SRC_DIR/feeds/luci/"*|"$SRC_DIR/feeds/packages/"*|"$SRC_DIR/feeds/routing/"*|"$SRC_DIR/feeds/telephony/"*) continue ;;
		esac
		sed -i 's#^include[[:space:]]*\.\./\.\./luci\.mk#include $(TOPDIR)/feeds/luci/luci.mk#' "$f"
		info "已修正 include 路径：${f#$SRC_DIR/}"
	done < <(grep -rl --include=Makefile '^include[[:space:]]*\.\./\.\./luci\.mk' "$SRC_DIR/feeds" 2>/dev/null)
}

gen_config() {
	mkdir -p "$SRC_DIR/files"
	if [ -d "$PROJECT_DIR/files" ]; then
		cp -a "$PROJECT_DIR/files/." "$SRC_DIR/files/"
	fi
	bash "$PROJECT_DIR/scripts/make-config.sh" "$SRC_DIR/.config" || die "生成 .config 失败"
}

make_defconfig() {
	if ! ( cd "$SRC_DIR" && make defconfig ) >"$LOG_DIR/defconfig.log" 2>&1; then
		tail -40 "$LOG_DIR/defconfig.log"
		die "make defconfig 失败，日志：logs/defconfig.log"
	fi
}

audit_config() {
	local sym missing=0
	echo ""
	echo "关键配置自检："
	for sym in $KEY_SYMBOLS; do
		if grep -q "^${sym}=y" "$SRC_DIR/.config"; then
			printf '  \033[1;32m✓\033[0m %s\n' "$sym"
		else
			printf '  \033[1;33m✗\033[0m %s  （未生效：feed 没拉到 / 包名变化 / 平台不匹配）\n' "$sym"
			missing=$((missing + 1))
		fi
	done
	if ! grep -q '^CONFIG_TARGET_airoha_an7581_DEVICE_gemtek_w1700k-ubi=y' "$SRC_DIR/.config"; then
		die "设备 profile 未生效（gemtek_w1700k-ubi），请检查 OPENWRT_REF 是否为 main"
	fi
	[ "$missing" -gt 0 ] && warn "有 $missing 个关键插件没进配置，编译仍会继续，最终报告里会再列一次"
	return 0
}

download_sources() {
	info "预下载源码包（可能几分钟）"
	if ! ( cd "$SRC_DIR" && make -j"$JOBS" download ) >"$LOG_DIR/download.log" 2>&1; then
		warn "部分源码包下载失败，继续尝试编译（见 logs/download.log）"
	fi
}

# 从 OpenWrt 的 logs/ 目录解析出本轮实际失败的包
# 输出：每行 "feed|pkg"（核心/未知包 feed 为 __CORE__）
collect_failures() {
	local stamp="$1" rel feed rest pkg
	while IFS= read -r f; do
		rel="${f#$SRC_DIR/logs/}"
		case "$rel" in
			package/feeds/*)
				rel="${rel#package/feeds/}"
				feed="${rel%%/*}"
				rest="${rel#*/}"
				case "$rest" in
					*/*)
						# <feed>/<pkgdir>/<file>：取包目录名
						pkg="${rest%%/*}"
						;;
					*)
						# <feed>/<file>：单包 feed，目录名即包名（如 luci-theme-argon）
						pkg="$feed"
						;;
				esac
				echo "$feed|$pkg"
				;;
			package/*)
				rel="${rel#package/}"
				echo "__CORE__|${rel%%/*}"
				;;
			*)
				echo "__CORE__|${rel%%/*}"
				;;
		esac
	done < <(find "$SRC_DIR/logs" -type f -name '*.txt' -newer "$stamp" 2>/dev/null | sort -u)
}

is_droppable() {
	local feed="$1" pkg="$2" p
	for p in $DROPPABLE_FEEDS; do [ "$feed" = "$p" ] && return 0; done
	for p in $DROPPABLE_PKGS;  do [ "$pkg"  = "$p" ] && return 0; done
	return 1
}

drop_package() {
	local pkg="$1"
	grep -q "^# CONFIG_PACKAGE_${pkg} is not set$" "$DISABLED_FILE" 2>/dev/null && return 0
	{
		echo "# $(date '+%F %T') 自动跳过：编译失败"
		echo "# CONFIG_PACKAGE_${pkg} is not set"
	} >> "$DISABLED_FILE"
	warn "已把 $pkg 加入跳过列表（configs/disabled.auto）"
}

build_loop() {
	local attempt rc stamp failures dropped feed pkg core_failed
	for attempt in $(seq 1 "$MAX_RETRY"); do
		step "编译（第 $attempt/$MAX_RETRY 轮，-j$JOBS）"
		stamp="$LOG_DIR/.stamp.$attempt"
		touch "$stamp"
		( cd "$SRC_DIR" && make -j"$JOBS" ) >"$LOG_DIR/build-$attempt.log" 2>&1
		rc=$?
		if [ "$rc" -eq 0 ]; then
			info "编译成功"
			BUILD_OK=1
			return 0
		fi
		warn "第 $attempt 轮失败（exit $rc），日志：logs/build-$attempt.log"

		failures="$(collect_failures "$stamp" | sort -u)"
		if [ -z "$failures" ]; then
			warn "logs/ 里没有新的失败记录，按核心失败处理"
			tail -40 "$LOG_DIR/build-$attempt.log"
			die "编译失败且无法定位到可跳过的第三方包"
		fi

		dropped=""
		core_failed=""
		while IFS='|' read -r feed pkg; do
			[ -z "$pkg" ] && continue
			if is_droppable "$feed" "$pkg"; then
				drop_package "$pkg"
				dropped="$dropped $pkg"
			else
				core_failed="$core_failed $pkg"
			fi
		done <<< "$failures"

		if [ -n "$dropped" ]; then
			info "本轮跳过的第三方包：$dropped"
			gen_config
			make_defconfig || die "重新生成配置失败"
			continue
		fi

		printf '\n' >&2
		warn "失败的是核心/非第三方包：$core_failed"
		grep -nE 'Error [0-9]+$|\*\*\* \[' "$LOG_DIR/build-$attempt.log" | tail -20
		die "请把上面的报错贴给上游或调整配置（可以尝试 OPENWRT_REF 换一个 commit）"
	done
	die "重试 $MAX_RETRY 轮后仍然失败，见 logs/build-*.log"
}

collect_artifacts() {
	step "收集产物"
	local target_dir="$SRC_DIR/bin/targets/airoha/an7581"
	local pkg_dir="$SRC_DIR/bin/packages"
	rm -rf "$ARTIFACT_DIR/firmware" "$ARTIFACT_DIR/packages"
	mkdir -p "$ARTIFACT_DIR/firmware" "$ARTIFACT_DIR/packages"

	if [ -d "$target_dir" ]; then
		find "$target_dir" -maxdepth 1 -type f \
			\( -name 'openwrt-*gemtek_w1700k-ubi*' -o -name 'sha256sums' -o -name '*.manifest' -o -name 'profiles.json' \) \
			-exec cp -f {} "$ARTIFACT_DIR/firmware/" \;
	fi

	# 本工程集成的第三方插件包（以后想单独 apk add 也能用）
	local pkgs="luci-app-turboacc luci-theme-argon luci-app-argon-config luci-app-openclash \
luci-app-airoha-npu luci-app-wifi7 luci-app-wifimgr luci-i18n-turboacc-zh-cn luci-i18n-argon-config-zh-cn"
	local p found=""
	for p in $pkgs; do
		while IFS= read -r f; do
			if [ -n "$f" ]; then
				cp -f "$f" "$ARTIFACT_DIR/packages/"
				found="$found $(basename "$f")"
			fi
		done < <(find "$pkg_dir" -type f -name "${p}-*.apk" 2>/dev/null)
	done
	[ -n "$found" ] && info "已单独打包插件：$found"

	( cd "$SRC_DIR" && ./scripts/diffconfig.sh ) >"$ARTIFACT_DIR/config.diff" 2>/dev/null \
		|| cp -f "$SRC_DIR/.config" "$ARTIFACT_DIR/config.diff"

	write_report
	info "产物目录：$ARTIFACT_DIR"
}

write_report() {
	local sym
	{
		echo "# Gemtek W1700K 编译报告"
		echo
		echo "- 生成时间：$(date '+%F %T %Z')"
		echo "- OpenWrt 源码：${OPENWRT_REPO} @ ${OPENWRT_REF}"
		echo "- 源码版本：$(git -C "$SRC_DIR" log -1 --format='%h %ad %s' --date=short 2>/dev/null)"
		echo "- 产物内核：$(grep -m1 '^CONFIG_LINUX_' "$SRC_DIR/.config" 2>/dev/null || echo '见 config.diff')"
		echo
		echo "## 插件集成情况"
		echo
		echo '| 插件/功能 | 状态 |'
		echo '| --- | --- |'
		for sym in $KEY_SYMBOLS; do
			[ "$sym" = "CONFIG_TARGET_airoha_an7581_DEVICE_gemtek_w1700k-ubi" ] && continue
			if grep -q "^${sym}=y" "$SRC_DIR/.config"; then
				echo "| ${sym#CONFIG_PACKAGE_} | ✅ 已集成 |"
			else
				echo "| ${sym#CONFIG_PACKAGE_} | ⚠️ 未生效（见下方说明） |"
			fi
		done
		echo
		if [ -s "$DISABLED_FILE" ]; then
			echo "## 因编译失败被自动跳过的包"
			echo
			grep 'is not set' "$DISABLED_FILE" | sed 's/^# CONFIG_PACKAGE_/ - /; s/ is not set$//'
			echo
		fi
		echo "## 固件文件"
		echo
		echo '```'
		( cd "$ARTIFACT_DIR/firmware" 2>/dev/null && ls -lh | tail -n +2 ) || echo "(无)"
		echo '```'
		echo
		if [ -f "$ARTIFACT_DIR/firmware/sha256sums" ] || compgen -G "$ARTIFACT_DIR/firmware/*.itb" >/dev/null; then
			echo "SHA256："
			echo
			echo '```'
			( cd "$ARTIFACT_DIR/firmware" && sha256sum openwrt-*.itb 2>/dev/null )
			echo '```'
			echo
		fi
		if compgen -G "$ARTIFACT_DIR/packages/*.apk" >/dev/null; then
			echo "## 单独打包出来的插件（.apk）"
			echo
			echo '```'
			( cd "$ARTIFACT_DIR/packages" && ls -1 *.apk | sed "s/^/ - /" )
			echo '```'
			echo
		fi
		echo "刷机步骤见工程 README 第 5 节。"
	} > "$REPORT"
	echo "报告：$REPORT"
}

# --------------------------------------------------------------------------

step "1/8 准备 OpenWrt 源码"; prepare_src
step "2/8 更新 feeds";        setup_feeds
step "3/8 生成 .config";      gen_config
step "4/8 make defconfig";    make_defconfig
step "5/8 配置自检";          audit_config
step "6/8 预下载";            download_sources
BUILD_OK=0
step "7/8 编译固件";          build_loop
step "8/8 收集产物";          collect_artifacts

echo
if [ "$BUILD_OK" = "1" ]; then
	info "全部完成 🎉  固件在 $ARTIFACT_DIR/firmware/"
	ls -1 "$ARTIFACT_DIR/firmware" 2>/dev/null | sed 's/^/   /'
else
	warn "构建未成功完成，请看 $REPORT 与 logs/"
	exit 1
fi
