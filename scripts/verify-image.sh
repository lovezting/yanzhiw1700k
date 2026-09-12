#!/usr/bin/env bash
# ==========================================================================
#  校验编译产物：文件是否齐全、SHA256、插件是否真的在固件清单里
#  用法：bash scripts/verify-image.sh [artifacts 目录]
# ==========================================================================
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${1:-$PROJECT_DIR/artifacts}"
FW_DIR="$ARTIFACT_DIR/firmware"
PKG_DIR="$ARTIFACT_DIR/packages"

CHAINLOAD="openwrt-airoha-an7581-gemtek_w1700k-ubi-chainload-uboot.itb"
RECOVERY="openwrt-airoha-an7581-gemtek_w1700k-ubi-initramfs-recovery.itb"
SYSUPGRADE="openwrt-airoha-an7581-gemtek_w1700k-ubi-squashfs-sysupgrade.itb"

EXPECT_PKGS="luci-app-turboacc luci-theme-argon luci-app-argon-config luci-app-wifi7 \
luci-app-airoha-npu luci-app-openclash luci-app-upnp luci-app-sqm sqm-scripts miniupnpd-nftables dnsmasq-full"

ok=0
bad=0
mark() { # $1=0/1 $2=文本
	if [ "$1" = "1" ]; then printf '  \033[1;32m✓\033[0m %s\n' "$2"; ok=$((ok + 1));
	else printf '  \033[1;31m✗\033[0m %s\n' "$2"; bad=$((bad + 1)); fi
}

echo "校验目录：$ARTIFACT_DIR"
echo
echo "固件文件："
for f in "$CHAINLOAD" "$RECOVERY" "$SYSUPGRADE"; do
	if [ -f "$FW_DIR/$f" ]; then mark 1 "$f ($(du -h "$FW_DIR/$f" | cut -f1))"; else mark 0 "$f 缺失"; fi
done

if compgen -G "$FW_DIR/*.itb" >/dev/null; then
	echo
	echo "SHA256："
	( cd "$FW_DIR" && sha256sum openwrt-*.itb )
fi

echo
echo "插件包（单独输出的 .apk，可选）："
for p in luci-app-turboacc luci-theme-argon luci-app-argon-config luci-app-wifi7 luci-app-airoha-npu luci-app-openclash; do
	if compgen -G "$PKG_DIR/${p}-*.apk" >/dev/null; then mark 1 "$p"; else mark 0 "$p（没找到 .apk，可能被跳过或未编译）"; fi
done

manifest="$(ls -1 "$FW_DIR"/*.manifest 2>/dev/null | head -n1)"
echo
if [ -n "$manifest" ]; then
	echo "固件内已安装包清单（$manifest）："
	for p in $EXPECT_PKGS; do
		if grep -qE "(^|[[:space:]])${p}(-|$|[[:space:]])" "$manifest"; then mark 1 "$p"; else mark 0 "$p 不在清单里"; fi
	done
else
	echo "没有找到 *.manifest，跳过“固件内清单”校验。"
	echo "可刷机后执行：apk list --installed | grep -E 'openclash|turboacc|argon|airoha-npu|wifi7' 复核。"
fi

echo
echo "通过 $ok 项，未通过 $bad 项。"
[ "$bad" -eq 0 ]
