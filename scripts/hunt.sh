#!/usr/bin/env bash
# Hunt for free-tier Ampere A1 capacity.
#
# Deliberately not `set -e`: a failed launch is the expected case, not an
# error, and the classifier below decides what each failure means.
set -uo pipefail

: "${OCI_COMPARTMENT_OCID:?OCI_COMPARTMENT_OCID is required}"
: "${OCI_SUBNET_OCID:?OCI_SUBNET_OCID is required}"

SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
OCPU_LADDER="${OCPU_LADDER:-4 2 1}"     # tried largest-first at each placement
TARGET_OCPUS="${TARGET_OCPUS:-4}"        # free-tier A1 allowance
GB_PER_OCPU="${GB_PER_OCPU:-6}"          # free tier is fixed at 6 GB per OCPU
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-50}"
DISPLAY_NAME="${DISPLAY_NAME:-ObliskIQ-lite}"
OS_NAME="${OS_NAME:-Canonical Ubuntu}"
OS_VERSION="${OS_VERSION:-24.04}"
SSH_KEY_FILE="${SSH_KEY_FILE:-ssh_key.pub}"
HUNT_SECONDS="${HUNT_SECONDS:-240}"
INTERVAL="${INTERVAL:-20}"               # base seconds between launch attempts
JITTER="${JITTER:-5}"                    # random 0..JITTER-1s added to each wait
MAX_UNKNOWN="${MAX_UNKNOWN:-5}"

OCI="${OCI_BIN:-oci}"
COMPARTMENT=$(printf '%s' "$OCI_COMPARTMENT_OCID" | tr -d ' \r\n\t"')
SUBNET=$(printf '%s' "$OCI_SUBNET_OCID" | tr -d ' \r\n\t"')

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
fail() { echo "::error::$*" >&2; exit 1; }

summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; return 0; }
emit()    { [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s\n' "$*" >> "$GITHUB_OUTPUT"; return 0; }

# The CLI writes a key-file label warning to stderr on every call; without this
# every JSON read would have to strip it.
export SUPPRESS_LABEL_WARNING=True

ocic() { "$OCI" --no-retry "$@"; }

# Run an oci command keeping the streams apart, because stdout is parsed as
# JSON and stderr carries warnings that would corrupt it. Sets OCI_OUT/OCI_ERR.
OCI_OUT=""; OCI_ERR=""
ocic_capture() {
  local err_file rc
  err_file=$(mktemp)
  OCI_OUT=$("$OCI" --no-retry "$@" 2>"$err_file")
  rc=$?
  OCI_ERR=$(cat "$err_file")
  rm -f "$err_file"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Classify an OCI error. Order matters: "Out of host capacity" is delivered as
# an HTTP 500 InternalError, so it has to be matched before the generic 5xx
# rule, or every capacity miss would look like a transient server fault.
# ---------------------------------------------------------------------------
classify() {
  local msg
  msg=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$msg" in
    *"out of host capacity"*|*"out of capacity"*|*"insufficient capacity"*|*"capacity is not available"*)
      echo capacity ;;
    *"too many requests"*|*toomanyrequests*|*"rate limit"*|*"429"*)
      echo throttled ;;
    *limitexceeded*|*"limit exceeded"*|*"quota"*|*"service limit"*|*"exceeded the limit"*)
      echo quota ;;
    *notauthenticated*|*notauthorized*|*"not authorized"*|*"authorization failed"*|*"invalid signature"*|*"401"*|*"403"*)
      echo auth ;;
    *invalidparameter*|*"cannot be null"*|*"is not valid"*|*notfound*|*"not found"*|*"404"*)
      echo badrequest ;;
    *internalerror*|*"500"*|*"502"*|*"503"*|*"504"*|*timeout*|*"timed out"*|*"connection"*)
      echo transient ;;
    *) echo unknown ;;
  esac
}

# ---------------------------------------------------------------------------
# Pre-flight: never launch past the free-tier allowance.
# The original workflow had no such guard, so once a run succeeded the cron
# kept launching more instances -- straight past the free tier into billing.
# ---------------------------------------------------------------------------
log "Checking what this compartment already holds..."
if ! ocic_capture compute instance list \
  --compartment-id "$COMPARTMENT" --all \
  --query "data[?\"shape\"=='$SHAPE' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'].{n:\"display-name\",s:\"lifecycle-state\",o:\"shape-config\".ocpus}" \
  --output json; then
  echo "$OCI_ERR" >&2
  fail "Could not list existing instances; refusing to launch blind."
fi
EXISTING=$OCI_OUT

USED=$(printf '%s' "$EXISTING" | python3 -c '
import sys, json
try:
    rows = json.loads(sys.stdin.read().strip() or "[]") or []
except Exception:
    sys.exit(9)
print(int(sum(float(r.get("o") or 0) for r in rows)))
' 2>/dev/null) || fail "Unexpected response while counting existing $SHAPE instances."

printf '%s' "$EXISTING" | python3 -c '
import sys, json
for r in json.loads(sys.stdin.read().strip() or "[]") or []:
    print(f"  - {r.get(\"n\")}: {r.get(\"s\")} ({r.get(\"o\")} OCPU)")
' 2>/dev/null

REMAINING=$(( TARGET_OCPUS - USED ))
log "$SHAPE OCPUs already allocated: $USED of $TARGET_OCPUS (remaining: $REMAINING)."

if [ "$REMAINING" -le 0 ]; then
  log "Free-tier A1 allowance is already fully used. Nothing to hunt."
  summary "### Ampere A1 hunt — nothing to do"
  summary "All $TARGET_OCPUS free-tier OCPUs are already allocated. Launching more would be billable, so this run stopped."
  emit "result=already-satisfied"
  exit 0
fi

# Service limits. Asking for more than the tenancy is allowed comes back as
# LimitExceeded, so read the limits and shrink the request to fit rather than
# spending attempts discovering it. Limits live on the tenancy (root
# compartment), which may not be the compartment we launch into.
TENANCY=$(printf '%s' "${OCI_TENANCY_OCID:-}" | tr -d ' \r\n\t"')
if [ -z "$TENANCY" ]; then
  TENANCY=$(awk -F= '/^[[:space:]]*tenancy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2}' \
    "${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}" 2>/dev/null)
fi

read_limit() {
  ocic_capture limits value list -c "$1" --service-name compute --name "$2" --all \
    --query 'max(data[].value)' --raw-output || return 1
  printf '%s' "$OCI_OUT" | tr -cd '0-9'
}

if [ -n "$TENANCY" ]; then
  CORE_LIMIT=$(read_limit "$TENANCY" standard-a1-core-count)
  MEM_LIMIT=$(read_limit "$TENANCY" standard-a1-memory-count)
else
  CORE_LIMIT=""; MEM_LIMIT=""
fi

if [ -n "$CORE_LIMIT" ] && [ -n "$MEM_LIMIT" ]; then
  log "Tenancy A1 service limits: ${CORE_LIMIT} OCPU / ${MEM_LIMIT} GB."
  if [ "$CORE_LIMIT" -eq 0 ] || [ "$MEM_LIMIT" -eq 0 ]; then
    summary "### Ampere A1 hunt stopped — no A1 quota"
    summary "This tenancy's A1 service limit is ${CORE_LIMIT} OCPU / ${MEM_LIMIT} GB, so no A1 instance of any size can be launched."
    summary "Raise it under Governance & Administration -> Limits, Quotas and Usage -> Compute -> standard-a1-core-count (Request a service limit increase)."
    fail "This tenancy is allowed 0 A1 capacity (limits: ${CORE_LIMIT} OCPU / ${MEM_LIMIT} GB). Request a service limit increase before hunting."
  fi
  MEM_CAP=$(( MEM_LIMIT / GB_PER_OCPU ))
  [ "$CORE_LIMIT" -lt "$REMAINING" ] && REMAINING=$CORE_LIMIT
  [ "$MEM_CAP" -lt "$REMAINING" ] && REMAINING=$MEM_CAP
  log "Largest size the limits and free allowance permit: ${REMAINING} OCPU."
else
  log "Could not read the A1 service limits; keeping the full ladder."
fi

# Only ladder rungs that still fit in the remaining free allowance.
LADDER=()
for n in $OCPU_LADDER; do
  [ "$n" -le "$REMAINING" ] && LADDER+=("$n")
done
[ ${#LADDER[@]} -gt 0 ] || fail "No ladder entry in '$OCPU_LADDER' fits the remaining $REMAINING OCPU(s)."
log "Sizes to try: ${LADDER[*]} OCPU."

# ---------------------------------------------------------------------------
# Resources: image, every availability domain, every fault domain.
# The original only ever tried availability domain [0] and one fault domain,
# throwing away most of the placements capacity can free up in.
# ---------------------------------------------------------------------------
ocic_capture compute image list \
  --compartment-id "$COMPARTMENT" \
  --operating-system "$OS_NAME" \
  --operating-system-version "$OS_VERSION" \
  --shape "$SHAPE" \
  --sort-by TIMECREATED --sort-order DESC \
  --query "data[?contains(\"display-name\", 'aarch64') && !contains(\"display-name\", 'Minimal')].id | [0]" \
  --raw-output
IMAGE_ID=$(printf '%s' "$OCI_OUT" | tr -d '[:space:]')

case "$IMAGE_ID" in
  ocid1.image.*) ;;
  *) fail "No $OS_NAME $OS_VERSION aarch64 image found for $SHAPE. Response: ${OCI_ERR:-${OCI_OUT:-<empty>}}" ;;
esac
log "Image: $IMAGE_ID"

mapfile -t ADS < <(ocic iam availability-domain list \
  --compartment-id "$COMPARTMENT" --query 'data[].name' --output json 2>/dev/null \
  | python3 -c 'import sys,json; [print(x) for x in json.loads(sys.stdin.read() or "[]") or []]' 2>/dev/null)
[ ${#ADS[@]} -gt 0 ] || fail "Could not list availability domains for this compartment."
log "Availability domains: ${ADS[*]}"

# Placements, in round-robin order across ADs and fault domains.
PLACEMENTS=()
for ad in "${ADS[@]}"; do
  mapfile -t FDS < <(ocic iam fault-domain list \
    --compartment-id "$COMPARTMENT" --availability-domain "$ad" \
    --query 'data[].name' --output json 2>/dev/null \
    | python3 -c 'import sys,json; [print(x) for x in json.loads(sys.stdin.read() or "[]") or []]' 2>/dev/null)
  # An empty fault-domain list is fine: "" means "let OCI choose".
  [ ${#FDS[@]} -gt 0 ] || FDS=("")
  for fd in "${FDS[@]}"; do
    PLACEMENTS+=("$ad|$fd")
  done
done
log "Placements to rotate through: ${#PLACEMENTS[@]}"

# Flat attempt list: every placement, largest size first at each one.
ATTEMPTS=()
build_attempts() {
  ATTEMPTS=()
  local p n
  for p in "${PLACEMENTS[@]}"; do
    for n in "${LADDER[@]}"; do
      ATTEMPTS+=("$n|$p")
    done
  done
}
build_attempts

[ -r "$SSH_KEY_FILE" ] || fail "SSH public key file '$SSH_KEY_FILE' is missing."
if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -l -f "$SSH_KEY_FILE" >/dev/null 2>&1 || SSH_BAD=1
elif ! grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9]+) [A-Za-z0-9+/=]+' "$SSH_KEY_FILE"; then
  SSH_BAD=1
fi
[ -z "${SSH_BAD:-}" ] \
  || fail "SSH_PUBLIC_KEY is not a valid OpenSSH public key. It must be the one-line .pub file (starting with ssh-ed25519 or ssh-rsa), not the private key."

# ---------------------------------------------------------------------------
# The hunt.
# ---------------------------------------------------------------------------
DEADLINE=$(( SECONDS + HUNT_SECONDS ))
ATTEMPT=0
UNKNOWN_STREAK=0
BACKOFF="$INTERVAL"
declare -A SEEN_ERRORS=()

log "Hunting for ${HUNT_SECONDS}s, one attempt every ~${INTERVAL}s."

while [ "$SECONDS" -lt "$DEADLINE" ]; do
  IFS='|' read -r ocpus ad fd <<< "${ATTEMPTS[$(( ATTEMPT % ${#ATTEMPTS[@]} ))]}"
  ATTEMPT=$(( ATTEMPT + 1 ))
  mem=$(( ocpus * GB_PER_OCPU ))

  args=(
    compute instance launch
    --availability-domain "$ad"
    --compartment-id "$COMPARTMENT"
    --shape "$SHAPE"
    --shape-config "{\"ocpus\": $ocpus, \"memoryInGBs\": $mem}"
    --image-id "$IMAGE_ID"
    --subnet-id "$SUBNET"
    --display-name "$DISPLAY_NAME"
    --assign-public-ip true
    --boot-volume-size-in-gbs "$BOOT_VOLUME_GB"
    --ssh-authorized-keys-file "$SSH_KEY_FILE"
    --freeform-tags '{"created-by":"oracle-ampere-hunter"}'
  )
  [ -n "$fd" ] && args+=(--fault-domain "$fd")

  log "Attempt #$ATTEMPT: ${ocpus} OCPU / ${mem} GB in $ad${fd:+ / $fd}"
  ocic_capture "${args[@]}"
  RC=$?
  RESPONSE=${OCI_ERR:-$OCI_OUT}

  if [ "$RC" -eq 0 ]; then
    INSTANCE_ID=$(printf '%s' "$OCI_OUT" | python3 -c \
      'import sys,json; print((json.load(sys.stdin).get("data") or {}).get("id",""))' 2>/dev/null)
    if [ -n "$INSTANCE_ID" ]; then
      log "GOT ONE. Instance $INSTANCE_ID (${ocpus} OCPU / ${mem} GB, $ad${fd:+ / $fd})"
      emit "result=launched"
      emit "instance_id=$INSTANCE_ID"
      emit "ocpus=$ocpus"
      emit "memory=$mem"
      emit "placement=$ad${fd:+ / $fd}"

      IP=""
      for _ in $(seq 1 20); do
        IP=$(ocic compute instance list-vnics --instance-id "$INSTANCE_ID" \
              --query 'data[0]."public-ip"' --raw-output 2>/dev/null | tr -d '[:space:]')
        [ -n "$IP" ] && [ "$IP" != "null" ] && break
        IP=""
        sleep 6
      done
      emit "public_ip=$IP"

      summary "### 🎉 Ampere A1 captured"
      summary ""
      summary "| | |"
      summary "|---|---|"
      summary "| Instance | \`$INSTANCE_ID\` |"
      summary "| Shape | $SHAPE — ${ocpus} OCPU / ${mem} GB |"
      summary "| Placement | $ad${fd:+ / $fd} |"
      summary "| Public IP | ${IP:-pending} |"
      summary "| Attempts this run | $ATTEMPT |"
      exit 0
    fi
    log "Launch returned success but no instance id; treating as a failure."
    RESPONSE="empty response body"
  fi

  KIND=$(classify "$RESPONSE")
  FIRST_LINE=$(printf '%s' "$RESPONSE" | tr '\n' ' ' | tr -s ' ' | cut -c1-500)

  case "$KIND" in
    capacity)
      log "No capacity here. Rotating placement."
      BACKOFF="$INTERVAL"
      ;;
    throttled)
      BACKOFF=$(( BACKOFF * 2 )); [ "$BACKOFF" -gt 300 ] && BACKOFF=300
      log "Rate-limited by OCI. Backing off ${BACKOFF}s."
      ;;
    transient)
      BACKOFF=$(( INTERVAL * 2 ))
      log "Transient OCI error, retrying: $FIRST_LINE"
      ;;
    quota)
      # This size is over the tenancy's limit, but a smaller rung may still
      # fit, so drop this size and anything larger and keep hunting. Only when
      # nothing is left is the limit genuinely the end of the road.
      NEW_LADDER=()
      for n in "${LADDER[@]}"; do
        [ "$n" -lt "$ocpus" ] && NEW_LADDER+=("$n")
      done
      if [ ${#NEW_LADDER[@]} -eq 0 ]; then
        summary "### Ampere A1 hunt stopped — service limit"
        summary "Even ${ocpus} OCPU / ${mem} GB exceeds this tenancy's A1 limit."
        summary "\`\`\`"
        summary "$FIRST_LINE"
        summary "\`\`\`"
        summary "Raise it under Governance & Administration -> Limits, Quotas and Usage -> Compute."
        fail "Even the smallest size (${ocpus} OCPU / ${mem} GB) exceeds this tenancy's A1 service limit: $FIRST_LINE"
      fi
      LADDER=("${NEW_LADDER[@]}")
      log "${ocpus} OCPU exceeds the A1 service limit. Dropping to sizes ${LADDER[*]} OCPU."
      build_attempts
      BACKOFF=5
      ;;
    auth|badrequest)
      summary "### Ampere A1 hunt stopped — configuration error"
      summary "\`\`\`"
      summary "$FIRST_LINE"
      summary "\`\`\`"
      fail "Configuration error, which retrying cannot fix: $FIRST_LINE"
      ;;
    unknown)
      UNKNOWN_STREAK=$(( UNKNOWN_STREAK + 1 ))
      if [ -z "${SEEN_ERRORS[$FIRST_LINE]:-}" ]; then
        SEEN_ERRORS[$FIRST_LINE]=1
        log "Unrecognised OCI error (#$UNKNOWN_STREAK): $FIRST_LINE"
      fi
      if [ "$UNKNOWN_STREAK" -ge "$MAX_UNKNOWN" ]; then
        fail "$MAX_UNKNOWN consecutive unrecognised errors, last: $FIRST_LINE"
      fi
      BACKOFF=$(( INTERVAL * 2 ))
      ;;
  esac
  [ "$KIND" = unknown ] || UNKNOWN_STREAK=0

  # Jitter, so a fleet of these does not hammer OCI on the same second.
  SLEEP=$(( BACKOFF + (JITTER > 0 ? RANDOM % JITTER : 0) ))
  [ $(( SECONDS + SLEEP )) -lt "$DEADLINE" ] || break
  sleep "$SLEEP"
done

log "Window closed after $ATTEMPT attempts without capacity. This is normal."
summary "### Ampere A1 hunt — no capacity this run"
summary "$ATTEMPT attempts across ${#PLACEMENTS[@]} placement(s) and sizes ${LADDER[*]} OCPU. Will try again on the next run."
emit "result=no-capacity"
exit 0
