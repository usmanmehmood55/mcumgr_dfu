#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 6 || $# -gt 7 ]]; then
  echo "Usage: $0 SIDE FACTORY_ID CANDIDATE_JSON BASELINE_HASH DUT_UART REPORT_DIR [OTA_CASE]" >&2
  exit 2
fi
side=$1
factory=$2
manifest=$(cd -- "$(dirname -- "$3")" && pwd)/$(basename -- "$3")
baseline=$4
uart=$5
mkdir -p -- "$6"
report=$(cd -- "$6" && pwd)
scenario=${7:-suite}
[[ -f "$manifest" && -c "$uart" ]]
if [[ -e "$report/flutter.log" || -e "$report/uart.log" ]]; then
  echo "Report directory already contains a run" >&2
  exit 2
fi

cd -- "$(dirname -- "$0")"
"${HIL_PYTHON:-python3}" -u tool/capture_uart.py "$uart" >"$report/uart.log" 2>&1 &
capture=$!
trap 'kill "$capture" 2>/dev/null || true' EXIT
sleep 1
kill -0 "$capture"
set +e
flutter test -d macos --reporter expanded integration_test/ota_test.dart \
  --dart-define="EVENT_LOG=$report/events.jsonl" \
  --dart-define="DUT_SIDE=$side" \
  --dart-define="DUT_FACTORY_ID=$factory" \
  --dart-define="CANDIDATE_MANIFEST=$manifest" \
  --dart-define="BASELINE_HASH=$baseline" \
  --dart-define="OTA_CASE=$scenario" 2>&1 | tee "$report/flutter.log"
flutter_status=${PIPESTATUS[0]}
set -e
"${HIL_PYTHON:-python3}" collect_evidence.py "$report" "$side" "$flutter_status"
