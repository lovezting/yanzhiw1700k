#!/usr/bin/env bash
# ==========================================================================
#  生成 .config：base.seed + 选中的 features/*.conf + 追加包 + 自动跳过列表
#
#  可用环境变量控制（默认全开，设为 0 关闭）：
#    ENABLE_UPNP  ENABLE_SQM  ENABLE_TURBOACC  ENABLE_ARGON
#    ENABLE_OPENCLASH  ENABLE_AIROHA_NPU  ENABLE_WIFI7  ENABLE_EXTRAS
#    EXTRA_PACKAGES="luci-app-xxx htop"   # 追加任意官方包
# ==========================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$PROJECT_DIR/openwrt/.config}"

enabled() {
	case "${!1:-1}" in
		1|y|Y|yes|true) return 0 ;;
		*) return 1 ;;
	esac
}

mkdir -p "$(dirname "$OUT")"

{
	cat "$PROJECT_DIR/configs/base.seed"

	enabled ENABLE_UPNP       && cat "$PROJECT_DIR/configs/features/upnp.conf"
	enabled ENABLE_SQM        && cat "$PROJECT_DIR/configs/features/sqm.conf"
	enabled ENABLE_TURBOACC   && cat "$PROJECT_DIR/configs/features/turboacc.conf"
	enabled ENABLE_ARGON      && cat "$PROJECT_DIR/configs/features/argon.conf"
	enabled ENABLE_OPENCLASH  && cat "$PROJECT_DIR/configs/features/openclash.conf"
	enabled ENABLE_AIROHA_NPU && cat "$PROJECT_DIR/configs/features/airoha-npu.conf"
	enabled ENABLE_WIFI7      && cat "$PROJECT_DIR/configs/features/wifi7.conf"
	enabled ENABLE_EXTRAS     && cat "$PROJECT_DIR/configs/features/extras.conf"

	# 用户自己的补充片段（configs/extra/*.conf，可选）
	for f in "$PROJECT_DIR"/configs/extra/*.conf; do
		[ -f "$f" ] && cat "$f"
	done

	if [ -n "${EXTRA_PACKAGES:-}" ]; then
		echo ""
		echo "# ---- EXTRA_PACKAGES ----"
		for pkg in $EXTRA_PACKAGES; do
			echo "CONFIG_PACKAGE_${pkg}=y"
		done
	fi

	# 编译失败被自动跳过的插件（由 build.sh 维护），放最后保证优先级最高
	if [ -s "$PROJECT_DIR/configs/disabled.auto" ]; then
		echo ""
		echo "# ---- 自动跳过（编译失败）----"
		cat "$PROJECT_DIR/configs/disabled.auto"
	fi
} > "$OUT"

echo "[config] 已生成 $(basename "$OUT")（$(grep -c '^CONFIG_PACKAGE_.*=y' "$OUT") 个显式启用的软件包）"
