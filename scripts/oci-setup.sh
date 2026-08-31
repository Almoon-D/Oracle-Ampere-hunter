#!/usr/bin/env bash
# Build ~/.oci/config from secrets and fail loudly (and early) on anything
# that would otherwise show up hours later as a cryptic NotAuthenticated.
set -uo pipefail

OCI_DIR="${OCI_DIR:-$HOME/.oci}"
KEY_FILE="$OCI_DIR/oci_api_key.pem"
CFG_FILE="$OCI_DIR/config"

die() { echo "::error::$*" >&2; exit 1; }
log() { echo "[setup] $*"; }

# --- 1. Every secret must be present ------------------------------------
missing=()
for v in OCI_USER_OCID OCI_FINGERPRINT OCI_TENANCY_OCID OCI_REGION OCI_API_KEY; do
  [ -n "${!v:-}" ] || missing+=("$v")
done
if [ ${#missing[@]} -gt 0 ]; then
  die "Missing repository secrets: ${missing[*]}. See README.md for the full list."
fi

mkdir -p "$OCI_DIR"
chmod 700 "$OCI_DIR"

# --- 2. Normalise the private key ---------------------------------------
# Copy/paste through Windows or a web form mangles PEMs in three usual ways:
# CRLF line endings, literal backslash-n instead of real newlines, or the whole
# key base64-wrapped. Recover from all three rather than failing.
printf '%s\n' "$OCI_API_KEY" | tr -d '\r' > "$KEY_FILE"

if ! grep -q -- '-----BEGIN' "$KEY_FILE"; then
  log "Key has no PEM header; trying base64 decode."
  if base64 -d < "$KEY_FILE" > "$KEY_FILE.dec" 2>/dev/null && grep -q -- '-----BEGIN' "$KEY_FILE.dec"; then
    mv "$KEY_FILE.dec" "$KEY_FILE"
    log "Decoded a base64-wrapped key."
  else
    rm -f "$KEY_FILE.dec"
    die "OCI_API_KEY is neither a PEM nor base64-encoded PEM. Paste the whole private key file, including the BEGIN/END lines."
  fi
fi

# Literal "\n" instead of real newlines.
if [ "$(wc -l < "$KEY_FILE")" -lt 3 ]; then
  log "Key looks like a single line; expanding literal \\n sequences."
  printf '%b\n' "$(cat "$KEY_FILE")" > "$KEY_FILE.tmp" && mv "$KEY_FILE.tmp" "$KEY_FILE"
fi
chmod 600 "$KEY_FILE"

openssl pkey -in "$KEY_FILE" -noout 2>/dev/null \
  || die "The private key in OCI_API_KEY is not a readable/unencrypted key. OCI API keys must not have a passphrase."

# --- 3. Fingerprint must match the key ----------------------------------
# Nearly every "NotAuthenticated" report is a fingerprint that belongs to a
# different key. Catch it here instead of in the hunt loop.
FP_CLEAN=$(printf '%s' "$OCI_FINGERPRINT" | tr -d ' \r\n\t"')
DERIVED_FP=$(openssl pkey -in "$KEY_FILE" -pubout -outform DER 2>/dev/null \
  | openssl md5 -c 2>/dev/null | sed 's/^.*= //')

if [ -n "$DERIVED_FP" ] && [ "$DERIVED_FP" != "$FP_CLEAN" ]; then
  die "OCI_FINGERPRINT ($FP_CLEAN) does not match OCI_API_KEY (whose fingerprint is $DERIVED_FP). Fix one of the two secrets."
fi
log "Fingerprint matches the private key."

# --- 4. Sanity-check the OCIDs ------------------------------------------
USER_CLEAN=$(printf '%s' "$OCI_USER_OCID" | tr -d ' \r\n\t"')
TENANCY_CLEAN=$(printf '%s' "$OCI_TENANCY_OCID" | tr -d ' \r\n\t"')
REGION_CLEAN=$(printf '%s' "$OCI_REGION" | tr -d ' \r\n\t"')

case "$USER_CLEAN" in ocid1.user.*) ;; *) die "OCI_USER_OCID must start with 'ocid1.user.' (got '${USER_CLEAN:0:24}...')." ;; esac
case "$TENANCY_CLEAN" in ocid1.tenancy.*) ;; *) die "OCI_TENANCY_OCID must start with 'ocid1.tenancy.' (got '${TENANCY_CLEAN:0:24}...')." ;; esac
[ -n "$REGION_CLEAN" ] || die "OCI_REGION is empty (e.g. eu-madrid-1)."

# --- 5. Write the config -------------------------------------------------
cat > "$CFG_FILE" <<EOF
[DEFAULT]
user=$USER_CLEAN
fingerprint=$FP_CLEAN
tenancy=$TENANCY_CLEAN
region=$REGION_CLEAN
key_file=$KEY_FILE
EOF
chmod 600 "$CFG_FILE"
log "Wrote $CFG_FILE for region $REGION_CLEAN."

# --- 6. Prove the credentials actually work ------------------------------
if ! OUT=$(oci iam region-subscription list --config-file "$CFG_FILE" --no-retry 2>&1); then
  echo "$OUT" >&2
  die "OCI rejected these credentials. Check the API key is still active on this user in the OCI console."
fi
log "Authenticated against OCI successfully."
