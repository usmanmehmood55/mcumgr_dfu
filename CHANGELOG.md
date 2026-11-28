## 0.1.0-dev.4

- Every failure other than a device rejection throws
  `McuMgrError`, and its `kind` names that one failure: for example
  `disconnected`, `responseTimeout`, `uploadHashMismatch`, `uploadStalled` or
  `testNotApplied`. Each kind has a `description`, and
  `retryAfterReconnect` says whether reconnecting and repeating may succeed.
  `detail` adds what varies (such as the stalled offset) and `cause` carries the
  transport's own error. They replace the `StateError`, `TimeoutException`,
  `FormatException` and `UnsupportedError` thrown before. A transport write
  error becomes `writeFailed`, or `disconnected` when the link dropped. Misuse
  (opening twice, overlapping requests) still throws `StateError`, and
  `SmpCbor` still throws `FormatException`.
- `test()` verifies the device reports the image as pending, and
  `confirm()` that it reports it as confirmed. They throw `testNotApplied` and
  `confirmNotApplied` otherwise. They use the image list MCUboot returns, or
  read it back when a peer omits it.
- `SmpCommandError.code` is an `int` (-1 when the device sent no
  number) and `group` an `int?`. `v1Result` decodes SMP v1 codes into the new
  `SmpV1Result` enum, and `retryable` is true for `busy` and `timeout`.
- Add `webBluetoothWriteSize` (180), the write size measured to work over Web
  Bluetooth, which cannot report the MTU.

## 0.1.0-dev.3

- Limit upload request fragmentation on small-write transports to reduce SMP
  command timeouts on slower links.
- `upload()` now defaults `allowFragmentation` to `false`, as the
  README describes. Pass `true` for targets that support SMP reassembly.
- Device rejections throw the public `SmpCommandError` (with
  `code` and `group`) instead of a `StateError`.
- `reset()` no longer reports success when the link drops before the whole
  reset command was written.
- `SmpCbor.encode` encodes integers of 2^32 and above instead of corrupting them.
- Malformed image-state and response maps raise `FormatException`.
- Images shorter than 32 bytes can be uploaded.
- Use `package:lints` instead of `flutter_lints`.
- `upload()` accepts `requestTimeout` (default 15 s) and `firstRequestTimeout`
  (default 60 s). A request at offset 0 can wait for the device to erase the
  secondary slot; a WellSole nRF52840 took about 10 s.

## 0.1.0-dev.2

- Add maintainer contact details to the README.

## 0.1.0-dev.1

- Add a transport-independent Dart SMP client.
- Support image-state commands, signed image uploads with acknowledged progress,
  test boot, reset, and confirmation.
