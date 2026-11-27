# MCUmgr DFU

`mcumgr_dfu` is a pure-Dart MCUmgr SMP client for MCUboot devices. It handles
CBOR framing, ordered write fragmentation, notification reassembly, image-state
commands, and upload progress based on device acknowledgements.

## Use with a BLE connection

Implement `SmpTransport` for your BLE stack. Discover SMP service
`8d53dc1d-1db7-4cd3-868b-8a527460aa84` and use characteristic
`da2e7828-fbce-4e01-ae9e-261174997c48` for writes and notifications.
Expose the usable write length and update the connection generation on every
new physical connection. See the [Zephyr SMP transport specification](https://docs.zephyrproject.org/latest/services/device_mgmt/smp_transport.html).

```dart
import 'dart:typed_data';

import 'package:mcumgr_dfu/mcumgr_dfu.dart';

Future<void> stageFirmware(
  SmpTransport connectedTransport,
  Uint8List signedImage,
  void Function(double) onProgress, {
  bool allowFragmentation = false,
}) async {
  final client = McuMgrClient(connectedTransport);
  await client.open();
  try {
    await client.upload(
      signedImage,
      onProgress: onProgress,
      cancelled: () => false,
      allowFragmentation: allowFragmentation,
    );
  } finally {
    await client.close();
  }
}
```

Set `allowFragmentation` for targets known to support SMP receive reassembly.
A link whose write size cannot fit the first upload packet always requires
reassembly. Upload sends one SMP request at a time.

Use `images()` to verify the uploaded candidate and `test()` with the MCUboot
image hash before requesting `reset()`. After reconnecting, verify the device
identity and the active image hash and version before calling `confirm()`.
The application owns package validation, device selection, reconnect policy,
and the decision to activate or confirm a candidate.

## Hardware-in-the-loop testing

The Flutter HIL harness uses `universal_ble` as its BLE transport. The Dart
package accepts any implementation of `SmpTransport`.
[universal_ble on pub.dev](https://pub.dev/packages/universal_ble)

We extended the `universal_ble` HIL/FIT setup to exercise `mcumgr_dfu` on
nRF52840 development kits. The harness covers SMP fragmentation, failed-write
recovery, interrupted uploads, corrupt-image rejection, MCUboot rollback, and
confirmation that persists across reboot.
[Original HIL/FIT setup](https://github.com/usmanmehmood55/universal_ble/tree/main/hil) ·
[Run the DFU hardware tests](hil/README.md)
