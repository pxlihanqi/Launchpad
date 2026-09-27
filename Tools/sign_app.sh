#!/bin/bash
# 用固定证书签名（没有证书时退回 ad-hoc）。
# 固定证书让"指定要求"变成 证书指纹 + bundle id，重新编译后系统仍把它当作
# 同一个应用（ad-hoc 的 cdhash 每次都变，会被当成新应用）。
#
# 注意：签名钥匙串闲置会自动上锁，上锁后 codesign 会弹一个图形密码框
# （"codesign 想使用 launchpad-signing 钥匙串"），无人值守打包就会卡在那里。
# 所以下面先静默解锁再签名；密码不对就干净地退回 ad-hoc，绝不弹窗。
#
#   Tools/sign_app.sh <App.app>
set -euo pipefail

APP="${1:?用法: sign_app.sh <App.app>}"
CERT_CN="Launchpad Local Signing"
KEYCHAIN="${HOME}/Library/Keychains/launchpad-signing.keychain-db"
# 专用签名钥匙串的密码（Tools/setup_signing.sh 里创建时写入的固定值，
# 只用于本机这把自签名证书，不是任何账号密码）。可以用环境变量覆盖。
KEYCHAIN_PASSWORD="${LAUNCHPAD_KEYCHAIN_PASSWORD:-launchpad}"

if [ "$APP" = "--describe" ]; then
  echo "$CERT_CN"
  exit 0
fi

# 先把钥匙串解锁 + 修好分区列表。
#
# 这一步很关键：钥匙串按空闲时间自动上锁后，codesign 取私钥会被系统弹一个
# 图形密码框（"codesign 想使用 launchpad-signing 钥匙串"），自动打包就卡死
# 在那里等人输入。这里用脚本内的密码静默解锁，用不了就走 ad-hoc 签名，
# 绝不弹窗。
use_cert=0
if [ -f "$KEYCHAIN" ]; then
  if security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 \
     && security find-certificate -c "$CERT_CN" "$KEYCHAIN" >/dev/null 2>&1; then
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
      -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
    # 6 小时空闲才上锁，减少下次又要解锁的概率。
    security set-keychain-settings -lut 21600 "$KEYCHAIN" >/dev/null 2>&1 || true
    use_cert=1
  else
    echo "提示: 无法解锁签名钥匙串（密码变了？），这次退回到 ad-hoc 签名" >&2
  fi
fi

signed=0
for attempt in 1 2 3 4 5; do
  xattr -cr "$APP" 2>/dev/null || true
  if [ "$use_cert" = "1" ]; then
    sign_args=(--keychain "$KEYCHAIN" --sign "$CERT_CN")
  else
    sign_args=(--sign -)
  fi
  if ! codesign --force --deep --timestamp=none "${sign_args[@]}" "$APP" 2>/dev/null; then
    sleep 0.4
    continue
  fi
  xattr -cr "$APP" 2>/dev/null || true
  if codesign --verify --deep "$APP" 2>/dev/null; then
    signed=1
    break
  fi
  sleep 0.4
done

if [ "$signed" != "1" ]; then
  echo "error: 签名失败: $APP"
  exit 1
fi

requirement=$(codesign -d --requirements - "$APP" 2>&1 | grep designated | head -1 | sed 's/^ *//')
echo "已签名: $APP"
echo "   $requirement"
