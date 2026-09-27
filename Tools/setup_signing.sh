#!/bin/bash
# 创建一个稳定的自签名代码签名证书（只需运行一次）。
#
# 为什么需要：ad-hoc 签名的"指定要求"是 cdhash，每次重新编译都会变，
# 于是系统隐私授权（屏幕录制等）会失效、每次启动都重新弹窗。
# 用固定证书签名后，指定要求变成"证书指纹 + bundle id"，重编译也不再失效。
#
#   Tools/setup_signing.sh          # 创建（已存在则跳过）
#   Tools/setup_signing.sh --reset  # 删掉重建
set -euo pipefail

CERT_CN="Launchpad Local Signing"
KEYCHAIN="${HOME}/Library/Keychains/launchpad-signing.keychain-db"
KEYCHAIN_PASSWORD="launchpad"
P12_PASSWORD="launchpad"

if [ "${1:-}" = "--reset" ]; then
  echo "==> 删除已有签名钥匙串"
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
fi

if security find-certificate -c "$CERT_CN" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "证书已存在：$CERT_CN（$KEYCHAIN）"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 生成自签名证书"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=${CERT_CN}/OU=Launchpad/C=CN" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

openssl pkcs12 -export -out "$WORK/cert.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$CERT_CN" -passout "pass:${P12_PASSWORD}" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 >/dev/null 2>&1
# 注意：OpenSSL 3 默认用 AES-256/PBES2 加密 p12，macOS 的 security import 不认，
# 必须指定 3DES + SHA1（上面的 -certpbe/-keypbe/-macalg）。

echo "==> 建独立钥匙串（避免动到登录钥匙串，也避免每次签名弹密码）"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true

# 把签名钥匙串加入搜索列表（保留原有列表）
CURRENT=$(security list-keychains -d user | sed 's/^[[:space:]]*//; s/"//g' | tr '\n' ' ')
security list-keychains -d user -s $CURRENT "$KEYCHAIN" >/dev/null

echo "==> 完成"
security find-certificate -c "$CERT_CN" "$KEYCHAIN" | sed -n '1,4p'
echo
echo "以后打包/编译会自动用它签名；验证指定要求是否稳定："
echo "  codesign -d --requirements - /Applications/Launchpad.app"
