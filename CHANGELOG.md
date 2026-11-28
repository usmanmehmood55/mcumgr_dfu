## 0.1.0-dev.3

- Limit upload request fragmentation on small-write transports to reduce SMP
  command timeouts on slower links.
- **Breaking:** `upload()` now defaults `allowFragmentation` to `false`, as the
  README describes. Pass `true` for targets that support SMP reassembly.
- **Breaking:** device rejections throw the public `SmpCommandError` (with
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
