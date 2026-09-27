#!/bin/bash
# 打包 Launchpad：生成 .pkg 安装器与 .dmg 磁盘映像
#
#   Tools/make_package.sh              # 版本号读 Support/Info.plist
#   VERSION=1.1 Tools/make_package.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK="${WORK:-/tmp/launchpad-package}"
DERIVED="${WORK}/DerivedData"
PKG_ROOT="${WORK}/pkgroot"
DMG_STAGE="${WORK}/dmg"
OUT="${OUT:-${ROOT}/dist}"
PROJECT="Launchpad.xcodeproj"
APP_NAME="Launchpad"

VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist 2>/dev/null || echo 1.0)}"

echo "==> 清理工作目录"
rm -rf "$WORK"
mkdir -p "$WORK" "$PKG_ROOT/Applications" "$DMG_STAGE" "$OUT"

echo "==> 生成工程并编译 Release (v${VERSION})"
if command -v xcodegen >/dev/null 2>&1; then xcodegen generate >/dev/null; fi
if ! xcodebuild -project "$PROJECT" -scheme "$APP_NAME" -configuration Release \
     -derivedDataPath "$DERIVED" build > "${WORK}/build.log" 2>&1; then
  echo "编译失败，日志：${WORK}/build.log"
  tail -20 "${WORK}/build.log"
  exit 1
fi

APP="${DERIVED}/Build/Products/Release/${APP_NAME}.app"
if [ ! -d "$APP" ]; then echo "没找到构建产物：$APP"; exit 1; fi

echo "==> 签名（有固定证书则用证书）"
"${ROOT}/Tools/sign_app.sh" "$APP"

echo "==> 组装安装包内容"
# 关键：用 ditto --norsrc 复制，避免把扩展属性/资源分叉带进包内
# （否则包里会出现 ._* 文件，安装后 app 的签名会被破坏）
export COPYFILE_DISABLE=1
for target in "$PKG_ROOT/Applications/Launchpad.app" "$DMG_STAGE/Launchpad.app"; do
  ditto --norsrc --noextattr --noacl "$APP" "$target"
  # 先签名（签名过程本身会写入/更新包内文件），最后再清扩展属性：
  # pkgbuild 会把残留的扩展属性变成 ._* 分叉文件，那会破坏安装后的签名。
  "${ROOT}/Tools/sign_app.sh" "$target" >/dev/null
  xattr -cr "$target" 2>/dev/null || true
done
codesign --verify --deep "$PKG_ROOT/Applications/Launchpad.app" && echo "    去属性后签名仍然有效 ✓"
cp "$DMG_STAGE/Launchpad.app/Contents/Info.plist" "$DMG_STAGE/Launchpad.app/Contents/Info.plist" 2>/dev/null || true
if [ -f "Packaging/安装说明.txt" ]; then cp "Packaging/安装说明.txt" "$DMG_STAGE/安装说明.txt"; fi
ln -s /Applications "$DMG_STAGE/Applications"
chmod +x "Packaging/scripts/postinstall"

echo "==> 生成 .pkg"
pkgbuild --root "$PKG_ROOT" \
         --identifier "com.launchpad.app" \
         --version "$VERSION" \
         --install-location "/" \
         --scripts "Packaging/scripts" \
         "${WORK}/component.pkg" >"${WORK}/pkgbuild.log" 2>&1
productbuild --distribution "Packaging/distribution.xml" \
             --package-path "$WORK" \
             "${OUT}/启动台 Launchpad ${VERSION}.pkg" >"${WORK}/productbuild.log" 2>&1
if [ ! -f "${OUT}/启动台 Launchpad ${VERSION}.pkg" ]; then
  echo "打包失败，日志：${WORK}/pkgbuild.log ${WORK}/productbuild.log"
  tail -10 "${WORK}/pkgbuild.log" "${WORK}/productbuild.log"
  exit 1
fi

# 自检：解开 payload 校验签名
# （payload 里的 ._* 条目只是 com.apple.provenance 这类系统保护属性的载体，
#   安装/解包时会还原成扩展属性，不会落地成文件）
VERIFY_DIR="${WORK}/verify"
rm -rf "$VERIFY_DIR"
pkgutil --expand-full "${OUT}/启动台 Launchpad ${VERSION}.pkg" "$VERIFY_DIR" >/dev/null 2>&1 || true
APP_IN_PKG=$(find "$VERIFY_DIR" -maxdepth 5 -name "Launchpad.app" -type d 2>/dev/null | head -1)
if [ -n "$APP_IN_PKG" ] && codesign --verify --deep "$APP_IN_PKG" 2>/dev/null; then
  echo "    包内 app 签名校验通过 ✓"
else
  echo "    警告：包内 app 签名校验失败，请检查"
fi

echo "==> 生成 .dmg"
hdiutil create -volname "启动台 Launchpad ${VERSION}" \
               -srcfolder "$DMG_STAGE" \
               -ov -format UDZO \
               "${OUT}/启动台 Launchpad ${VERSION}.dmg" >/dev/null

echo
echo "==> 完成，产物在 ${OUT}"
shopt -s nullglob
for file in "${OUT}"/*"${VERSION}".*; do
  size=$(du -h "$file" | cut -f1)
  hash=$(shasum -a 256 "$file" | cut -c1-16)
  echo "  $(basename "$file")  ${size}  sha256:${hash}…"
done

echo
echo "提示：本包用本机自签名证书 $("${ROOT}/Tools/sign_app.sh" --describe 2>/dev/null || echo 'Launchpad Local Signing') 签名（未公证）。"
echo "      好处：隐私授权（屏幕录制等）绑定证书指纹，重新编译/重装都不会失效。"
echo "      首次打开若被 Gatekeeper 拦下：右键 → 打开，或到 系统设置 → 隐私与安全性 允许。"
