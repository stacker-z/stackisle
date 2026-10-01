#!/bin/bash
# ─────────────────────────────────────────────────────────────
# 03-create-cert.sh
# Generate ${CERTS_DIR}/${CERT_NAME}.crt + .key (default INSTALL_DIR/certs/server.crt)
# SANs = every domain in CUSTOM_DOMAINS + LOCAL_HOSTNAME + HOSTS_IP (all from .env)
#   - mkcert available → locally-trusted cert (no browser warning)
#   - otherwise        → openssl self-signed (browser warning)
# Idempotent: regenerates only when CUSTOM_DOMAINS changes or FORCE=1.
# ─────────────────────────────────────────────────────────────

set -e
source "$(dirname "$0")/lib/common.sh"

step "Generating SSL certificate"

SANS="$(echo "$CUSTOM_DOMAINS $LOCAL_HOSTNAME $HOSTS_IP" | tr -s ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
SANS="${SANS% }"
STAMP="${CERTS_DIR}/.${CERT_NAME}.sans"

info "Cert : ${CYAN}$(rel "$CERT_FILE")${RESET}"
info "Key  : ${CYAN}$(rel "$KEY_FILE")${RESET}"
info "SANs : ${CYAN}${SANS}${RESET}"
echo ""

if [[ -f "$CERT_FILE" && -f "$KEY_FILE" && "${FORCE:-0}" != "1" \
      && -f "$STAMP" && "$(cat "$STAMP")" == "$SANS" ]]; then
  ok "Certificate already covers all domains — skipping (FORCE=1 to regenerate)."
  exit 0
fi

mkdir -p "$CERTS_DIR"

if command -v mkcert &>/dev/null; then
  mkcert -install >/dev/null 2>&1 || warn "mkcert -install failed — cert may not be trusted."
  # shellcheck disable=SC2086
  mkcert -cert-file "$CERT_FILE" -key-file "$KEY_FILE" $SANS
  ok "mkcert certificate generated (trusted by local CA)."
else
  ALT=""; i=1; j=1
  for s in $SANS; do
    if [[ "$s" =~ ^[0-9.]+$ ]]; then ALT+="IP.${j} = ${s}"$'\n'; j=$((j+1))
    else                              ALT+="DNS.${i} = ${s}"$'\n'; i=$((i+1)); fi
  done
  CNF="$(mktemp)"
  cat > "$CNF" <<EOF
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[dn]
CN = ${SANS%% *}
O  = stackisle local dev
[ext]
subjectAltName   = @alt
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
basicConstraints = critical, CA:FALSE
[alt]
${ALT}
EOF
  # 825 days = max validity accepted by Apple/Chrome for leaf certs
  openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 825 \
    -keyout "$KEY_FILE" -out "$CERT_FILE" -config "$CNF" 2>/dev/null
  rm -f "$CNF"
  ok "Self-signed certificate generated (openssl)."
  warn "Browsers will warn. Install mkcert and run: FORCE=1 make certs"
fi

chmod 644 "$CERT_FILE"; chmod 600 "$KEY_FILE"
# nginx in the container runs as root for reading certs, 600 is fine.
echo "$SANS" > "$STAMP"

echo ""
info "SANs in cert:"
# `-text` works with both OpenSSL (Linux) and LibreSSL (macOS); `-ext` is OpenSSL-only
openssl x509 -in "$CERT_FILE" -noout -text 2>/dev/null \
  | grep -A1 "Subject Alternative Name" | tail -n 1 | sed 's/^ */      /'
echo ""
