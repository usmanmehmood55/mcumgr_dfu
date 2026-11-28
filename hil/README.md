# MCUmgr DFU hardware tests

The macOS Flutter runner exercises the public `mcumgr_dfu` API through
`universal_ble` and a production-configured WellSole nRF52840 DK. It is an
opt-in bench tool. The DFU package itself stays pure Dart.

## Setup

Prepare one correctly provisioned DK per side with the confirmed baseline.
Build a signed, patch-bumped candidate with the WellSole
`tests/hil/fixtures/build_ota_candidate.py` tool. Capture the baseline MCUboot
image hash with the firmware repository's `tests/hil/support/ota_image.py`
helper or a trusted image-state read. Close any other BLE and UART clients.

Use macOS with Xcode, Flutter, Bluetooth permission for the runner, and
Python with `pyserial`. The workspace dependency override uses the sibling
`universal_ble` checkout. Run one side at a time.

```sh
./run_macos.sh left FACTORY_ID /path/to/candidate.json BASELINE_HASH \
  /dev/cu.usbmodemSERIAL /path/to/left-report
```

Set `HIL_PYTHON` to a Python binary that has `pyserial` if needed. Grant
Bluetooth access when macOS prompts. The optional final argument selects
`corrupt`, `interrupted`, `fragmented_echo`, `fragment_failure`, `rollback`, or
`success`. Use `transport` to run both fragmentation cases together.
A full run keeps the candidate installed and confirmed on success, so restore
the baseline before repeating it.

The rollback and success scenarios can reconnect during the first 15 minutes
of an upload. Recovery stops after three consecutive link losses without new
acknowledged bytes. Each reconnect verifies the DUT identity and confirmed
baseline and retries the same signed image. The first acknowledgement shows
whether the DUT retained the upload or restarted it.

Keep the logs and `result.json`. The runner correlates each requested reset
with a remote BLE disconnect and a boot epoch from the independent UART log.
The event log contains image hashes, versions, confirmation flags, and acknowledged offsets. A transport timeout
during corruption does not prove image rejection.

## DK relay comparison

If the host BLE link fails, use the WellSole OTA peer firmware on one DK and
run the Dart client against the other. The peer exchanges raw SMP frames over
its own BLE link. A passing relay run verifies the Dart update lifecycle and
the DUT's boot behavior while keeping the macOS transport result independent.

```sh
./run_relay.sh WELLSOLE_ROOT PEER_UART DUT_SIDE DUT_ID PEER_ID \
  CANDIDATE_JSON BASELINE_HASH DUT_UART REPORT_DIR
```

The relay runner checks corrupt-image refusal, interrupted upload recovery,
test activation, rollback, probation, confirmation, and persistence using
single-write-sized SMP requests. Set `HIL_RELAY_CASE=corrupt` to run just the
corruption case, or `HIL_RELAY_CASE=valid` for interruption, rollback, and confirmation.

## Chrome Web Bluetooth

`chrome/` is a Flutter web harness that runs the same lifecycle over Web
Bluetooth. Build it, then serve it with the candidate:

```sh
(cd chrome && flutter build web --release --no-web-resources-cdn)
python3 tool/serve_harness.py 8767 /path/to/report/events.jsonl /path/to/candidate.json
```

Open `http://127.0.0.1:8767/?case=CASE&side=left&factory=FACTORY_ID` in Google
Chrome and click **Start / pick device**. Each evidence line is appended to the
events file in the same schema as the macOS runner. `case` is `success`,
`rollback`, `upload` or `probe`. `probe` uploads 32 KB per combination of
`write` sizes and `pipeline` depths (comma lists) and cancels, which leaves the
active image unchanged. Writes default to 180 bytes. Chrome rejects overlapping
GATT writes, so keep `pipeline=1` outside probes. When Chrome cannot reconnect
after a reboot or link loss, the page logs `pick_required`; click the button
again to re-select the DK.
