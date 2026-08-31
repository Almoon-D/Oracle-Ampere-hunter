#!/usr/bin/env bash
# Offline tests for scripts/hunt.sh, driven by tests/mock_oci.sh.
# Run with: bash tests/test_hunt.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A real (throwaway) ed25519 public key: hunt.sh validates the key with
# ssh-keygen when it is available, so a hand-written placeholder would not get
# past the pre-flight checks.
cat > "$TMP/id.pub" <<'KEY'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDVkBeC4Ug0FzT64FHm6MqQMt5s/8zcwqPmvZyDUXcU7 test@hunter
KEY

PASS=0; FAIL=0
ok()   { echo "  ok  - $1"; PASS=$(( PASS + 1 )); }
bad()  { echo "  FAIL- $1"; printf '        %s\n' "$2"; FAIL=$(( FAIL + 1 )); }

# Runs hunt.sh against the mock. Extra args are VAR=VALUE overrides.
run_hunt() {
  local name="$1"; shift
  RUN_DIR="$TMP/$name"; mkdir -p "$RUN_DIR"
  cp "$TMP/id.pub" "$RUN_DIR/ssh_key.pub"
  ( cd "$RUN_DIR" && env -i \
      PATH="$PATH" HOME="$HOME" RANDOM_SEED=1 \
      OCI_BIN="$ROOT/tests/mock_oci.sh" \
      MOCK_STATE_DIR="$RUN_DIR/state" \
      OCI_COMPARTMENT_OCID=ocid1.compartment.oc1..test \
      OCI_SUBNET_OCID=ocid1.subnet.oc1..test \
      GITHUB_OUTPUT="$RUN_DIR/out" \
      GITHUB_STEP_SUMMARY="$RUN_DIR/summary" \
      HUNT_SECONDS=3 INTERVAL=1 JITTER=0 \
      "$@" \
      bash "$ROOT/scripts/hunt.sh" ) > "$RUN_DIR/log" 2>&1
  RC=$?
  OUT=$(cat "$RUN_DIR/out" 2>/dev/null)
  LOG=$(cat "$RUN_DIR/log")
}

echo "hunt.sh"

# --- 1. Free-tier allowance already spent -> stop, do not launch -----------
run_hunt already-full MOCK_EXISTING='[{"n":"a","s":"RUNNING","o":4.0}]'
if [ "$RC" -eq 0 ] && grep -q 'result=already-satisfied' <<< "$OUT" \
   && [ ! -f "$TMP/already-full/state/launches" ]; then
  ok "stops without launching when all 4 free OCPUs are already used"
else
  bad "stops without launching when all 4 free OCPUs are already used" "$LOG"
fi

# --- 2. Partial usage narrows the ladder to what still fits ---------------
run_hunt partial MOCK_EXISTING='[{"n":"a","s":"RUNNING","o":2.0}]' MOCK_SUCCEED_ON=999
if grep -q 'remaining: 2' <<< "$LOG" && grep -q 'Sizes to try: 2 1 OCPU' <<< "$LOG" \
   && [ -s "$TMP/partial/state/launches" ] \
   && ! grep -q '"ocpus": 4' "$TMP/partial/state/launches"; then
  ok "with 2 of 4 OCPUs used, never asks for more than the remaining 2"
else
  bad "with 2 of 4 OCPUs used, never asks for more than the remaining 2" "$LOG"
fi

# --- 3. STOPPED instances still count against the allowance ---------------
run_hunt stopped MOCK_EXISTING='[{"n":"a","s":"STOPPED","o":4.0}]'
if grep -q 'result=already-satisfied' <<< "$OUT"; then
  ok "counts STOPPED instances against the free-tier allowance"
else
  bad "counts STOPPED instances against the free-tier allowance" "$LOG"
fi

# --- 4. Out of host capacity is a normal miss, not a failure --------------
run_hunt capacity MOCK_SUCCEED_ON=999
if [ "$RC" -eq 0 ] && grep -q 'result=no-capacity' <<< "$OUT" \
   && grep -q 'No capacity here' <<< "$LOG"; then
  ok "treats 'Out of host capacity' (HTTP 500) as a miss and exits green"
else
  bad "treats 'Out of host capacity' (HTTP 500) as a miss and exits green" "$LOG"
fi

# --- 5. Placements and sizes are actually rotated -------------------------
run_hunt rotate MOCK_SUCCEED_ON=999 MOCK_ADS='["AD-1","AD-2"]' HUNT_SECONDS=6 INTERVAL=1 JITTER=0
COMBOS=$(grep -oE '\-\-availability-domain [A-Za-z0-9:-]+ .*--fault-domain [A-Z0-9-]+' \
          "$TMP/rotate/state/launches" 2>/dev/null | sort -u | wc -l)
SIZES=$(grep -oE '"ocpus": [0-9]+' "$TMP/rotate/state/launches" | sort -u | wc -l)
if [ "$COMBOS" -ge 2 ] && [ "$SIZES" -ge 2 ]; then
  ok "rotates through multiple availability/fault domains and sizes ($COMBOS placements, $SIZES sizes)"
else
  bad "rotates through multiple availability/fault domains and sizes" "combos=$COMBOS sizes=$SIZES
$LOG"
fi

# --- 6. A win is reported with its details --------------------------------
run_hunt win MOCK_SUCCEED_ON=2
if [ "$RC" -eq 0 ] && grep -q 'result=launched' <<< "$OUT" \
   && grep -q 'instance_id=ocid1.instance.oc1.eu-madrid-1.WON' <<< "$OUT" \
   && grep -q 'public_ip=203.0.113.42' <<< "$OUT"; then
  ok "reports instance id and public IP on a successful launch"
else
  bad "reports instance id and public IP on a successful launch" "$OUT
$LOG"
fi

# --- 7. Auth errors stop immediately instead of burning the window --------
run_hunt auth MOCK_SUCCEED_ON=999 \
  MOCK_LAUNCH_ERROR='ServiceError: {"code": "NotAuthenticated", "message": "The required information to complete authentication was not provided.", "status": 401}'
if [ "$RC" -ne 0 ] && grep -q 'Configuration error' <<< "$LOG" \
   && [ "$(wc -l < "$TMP/auth/state/launches")" -eq 1 ]; then
  ok "fails fast on NotAuthenticated instead of retrying for the whole window"
else
  bad "fails fast on NotAuthenticated instead of retrying for the whole window" "$LOG"
fi

# --- 8. Service limits stop immediately ------------------------------------
run_hunt quota MOCK_SUCCEED_ON=999 \
  MOCK_LAUNCH_ERROR='ServiceError: {"code": "LimitExceeded", "message": "The following service limits were exceeded: standard-a1-core-count", "status": 400}'
if [ "$RC" -ne 0 ] && grep -q 'limit/quota problem' <<< "$LOG"; then
  ok "fails fast on LimitExceeded"
else
  bad "fails fast on LimitExceeded" "$LOG"
fi

# --- 9. Throttling backs off instead of hammering -------------------------
run_hunt throttle MOCK_SUCCEED_ON=999 HUNT_SECONDS=10 INTERVAL=1 JITTER=0 \
  MOCK_LAUNCH_ERROR='ServiceError: {"code": "TooManyRequests", "message": "Too many requests for the user", "status": 429}'
if [ "$RC" -eq 0 ] && grep -q 'Rate-limited by OCI. Backing off 2s' <<< "$LOG" \
   && grep -q 'Backing off 4s' <<< "$LOG"; then
  ok "backs off exponentially when OCI returns 429"
else
  bad "backs off exponentially when OCI returns 429" "$LOG"
fi

# --- 10. A missing image is caught before the loop ------------------------
run_hunt noimage MOCK_IMAGE_ID=''
if [ "$RC" -ne 0 ] && grep -q 'No Canonical Ubuntu 24.04 aarch64 image found' <<< "$LOG" \
   && [ ! -f "$TMP/noimage/state/launches" ]; then
  ok "refuses to launch when no aarch64 image was resolved"
else
  bad "refuses to launch when no aarch64 image was resolved" "$LOG"
fi

# --- 11. An unreadable SSH key is caught before the loop ------------------
run_hunt badkey MOCK_SUCCEED_ON=999 SSH_KEY_FILE=/nonexistent.pub
if [ "$RC" -ne 0 ] && grep -q 'is missing' <<< "$LOG"; then
  ok "refuses to launch when the SSH public key is missing"
else
  bad "refuses to launch when the SSH public key is missing" "$LOG"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
