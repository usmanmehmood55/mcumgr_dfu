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
