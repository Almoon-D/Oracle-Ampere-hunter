#!/usr/bin/env bash
# Stand-in for the `oci` CLI so hunt.sh can be exercised without a tenancy.
# Behaviour is driven by MOCK_* environment variables; see test_hunt.sh.
set -uo pipefail

ARGS="$*"
STATE="${MOCK_STATE_DIR:?}"
mkdir -p "$STATE"

case "$ARGS" in
  *"compute instance list-vnics"*)
    echo '203.0.113.42'; exit 0 ;;

  *"compute instance list"*)
    printf '%s' "${MOCK_EXISTING:-[]}"; exit 0 ;;

  *"compute image list"*)
    echo "${MOCK_IMAGE_ID-ocid1.image.oc1.eu-madrid-1.aaaa}"; exit 0 ;;

  *"iam availability-domain list"*)
    echo "${MOCK_ADS:-[\"kIdk:EU-MADRID-1-AD-1\"]}"; exit 0 ;;

  *"iam fault-domain list"*)
    echo "${MOCK_FDS:-[\"FAULT-DOMAIN-1\",\"FAULT-DOMAIN-2\"]}"; exit 0 ;;

  *"compute instance launch"*)
    n=$(( $(cat "$STATE/n" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$STATE/n"
    printf '%s\n' "$ARGS" >> "$STATE/launches"
    if [ -n "${MOCK_SUCCEED_ON:-}" ] && [ "$n" -ge "$MOCK_SUCCEED_ON" ]; then
      echo '{"data": {"id": "ocid1.instance.oc1.eu-madrid-1.WON", "lifecycle-state": "PROVISIONING"}}'
      exit 0
    fi
    printf '%s\n' "${MOCK_LAUNCH_ERROR:-ServiceError: {\"code\": \"InternalError\", \"message\": \"Out of host capacity.\", \"status\": 500}}" >&2
    exit 1 ;;
esac

echo "mock_oci: unhandled command: $ARGS" >&2
exit 127
