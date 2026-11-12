#!/usr/bin/env bash
# Creates and trusts a local self-signed Code Signing certificate ("DeskSide Local Signer")
# on this Mac so local builds (./build.sh) and GitHub Release updates (AppUpdater / update_local.sh)
# keep a stable code-signing identity across upgrades without Apple Developer notarization.
#
# Private keys never leave your Mac's login keychain; temporary files are wiped on exit.
set -euo pipefail

CERT_NAME="${DESKSIDE_CERT_NAME:-DeskSide Local Signer}"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"

EXISTING_HASH="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/awk -v name="\"$CERT_NAME\"" '$0 ~ name && $0 !~ /CSSMERR_/ { print $2; exit }')"
if [[ -n "$EXISTING_HASH" ]]; then
    echo "✅ 本机代码签名证书已就绪且受信任: \"$CERT_NAME\" ($EXISTING_HASH)"
    exit 0
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deskside-cert-setup.XXXXXX")"
chmod 700 "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

if /usr/bin/security find-identity -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null | grep -Fq "\"$CERT_NAME\""; then
    echo "==> [1/2] 检测到登录钥匙串中已有证书 \"$CERT_NAME\"，正在导出公钥证书以补充信任配置..."
    /usr/bin/security find-certificate -c "$CERT_NAME" -p "$LOGIN_KEYCHAIN" > "$WORK_DIR/cert.pem"
else
    echo "==> [1/3] 正在生成本机 10 年期代码签名证书: \"$CERT_NAME\"..."
    cat > "$WORK_DIR/cert.cnf" <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_dn
x509_extensions    = codesign_ext
prompt             = no

[ req_dn ]
CN = $CERT_NAME
O  = DeskSide Local Signing

[ codesign_ext ]
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
EOF

    P12_PASS="$(/usr/bin/openssl rand -hex 24)"

    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$WORK_DIR/key.pem" \
        -out "$WORK_DIR/cert.pem" \
        -days 3650 \
        -config "$WORK_DIR/cert.cnf" >/dev/null 2>&1

    PKCS12_FLAGS=()
    if /usr/bin/openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
        PKCS12_FLAGS=(-legacy)
    fi

    /usr/bin/openssl pkcs12 -export ${PKCS12_FLAGS[@]+"${PKCS12_FLAGS[@]}"} \
        -inkey "$WORK_DIR/key.pem" \
        -in "$WORK_DIR/cert.pem" \
        -name "$CERT_NAME" \
        -passout "pass:$P12_PASS" \
        -out "$WORK_DIR/cert.p12"

    echo "==> [2/3] 正在将私钥与证书导入登录钥匙串 ($LOGIN_KEYCHAIN)..."
    /usr/bin/security import "$WORK_DIR/cert.p12" \
        -k "$LOGIN_KEYCHAIN" \
        -P "$P12_PASS" \
        -T /usr/bin/codesign \
        -T /usr/bin/security >/dev/null
fi

echo "==> 正在写入系统级代码签名信任（请在弹出的 macOS 认证窗口通过 Touch ID 或密码确认）..."
TRUST_CMD="/usr/bin/security add-trusted-cert -d -r trustRoot -p codeSign -k '$SYSTEM_KEYCHAIN' '$WORK_DIR/cert.pem'"
if sudo -n true 2>/dev/null; then
    sudo /usr/bin/security add-trusted-cert -d -r trustRoot -p codeSign -k "$SYSTEM_KEYCHAIN" "$WORK_DIR/cert.pem"
elif [[ -t 0 ]]; then
    sudo /usr/bin/security add-trusted-cert -d -r trustRoot -p codeSign -k "$SYSTEM_KEYCHAIN" "$WORK_DIR/cert.pem"
else
    /usr/bin/osascript -e "do shell script \"$TRUST_CMD\" with administrator privileges"
fi

VALID_HASH="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/awk -v name="\"$CERT_NAME\"" '$0 ~ name && $0 !~ /CSSMERR_/ { print $2; exit }')"
if [[ -z "$VALID_HASH" ]]; then
    echo "❌ 证书导入完成但尚未处于受信任状态，请在「钥匙串访问」中将 \"$CERT_NAME\" 的「代码签名」设为「始终信任」。" >&2
    exit 1
fi

echo ""
echo "✅ 本机自签名证书配置成功: \"$CERT_NAME\" ($VALID_HASH)"
echo "   后续执行 ./build.sh、./scripts/update_local.sh 或应用内自动更新时，均会自动使用该证书重签名。"
echo "   提示：首次切换到该证书签名后，仅需在「辅助功能」中重新授权一次，此后升级将永久免重授。"
