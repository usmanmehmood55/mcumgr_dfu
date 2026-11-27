#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 9 ]]; then
  echo "Usage: $0 WELLSOLE_ROOT PEER_UART DUT_SIDE DUT_ID PEER_ID CANDIDATE_JSON BASELINE_HASH DUT_UART REPORT_DIR" >&2
  exit 2
fi
root=$(cd -- "$1" && pwd)
manifest=$(cd -- "$(dirname -- "$6")" && pwd)/$(basename -- "$6")
mkdir -p -- "$9"
report=$(cd -- "$9" && pwd)
python=${HIL_PYTHON:-python3}
[[ -c "$2" && -c "$8" && "$2" != "$8" && -f "$manifest" ]]
if [[ -e "$report/flutter.log" || -e "$report/uart.log" ]]; then
  echo "Report directory already contains a run" >&2
  exit 2
fi

cd -- "$(dirname -- "$0")"
"$python" -u tool/capture_uart.py "$8" >"$report/uart.log" 2>&1 &
capture=$!
trap 'kill "$capture" 2>/dev/null || true' EXIT
sleep 1
kill -0 "$capture"
set +e
dart run tool/relay_smoke.dart "$python" "$root" "$2" "$3" "$4" "$5" "$manifest" "$7" 2>&1 | tee "$report/flutter.log"
status=${PIPESTATUS[0]}
set -e
"$python" collect_evidence.py "$report" "$3" "$status"
