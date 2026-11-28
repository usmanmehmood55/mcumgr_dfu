# MCUmgr DFU

`mcumgr_dfu` lets a Dart or Flutter app update the firmware on a microcontroller,
over Bluetooth LE. This is device firmware update (DFU): the app sends a new
signed image to a device that is already deployed, and the device switches to
it after a reboot.

The package targets devices built on [Zephyr](https://zephyrproject.org), an
open-source real-time operating system for microcontrollers, with the
[MCUboot](https://docs.mcuboot.com) bootloader. MCUboot keeps the running image
and the new one in separate flash slots. It boots the new image as a test and
goes back to the old one on the next reboot unless the app confirms it.

Zephyr's device-management subsystem is
[MCUmgr](https://docs.zephyrproject.org/latest/services/device_mgmt/mcumgr.html).
It accepts commands such as uploading an image, listing the images in each
slot, marking one for test or as confirmed, and resetting the device. These
commands use SMP, the Simple Management Protocol: each message is an 8-byte
header followed by a CBOR payload, and it can travel over Bluetooth LE, a
serial port or UDP.

`mcumgr_dfu` is a pure-dart SMP client for those commands. It frames requests in
CBOR, splits them into ordered writes, reassembles notifications into responses,
and runs the image-state commands. Upload progress only moves when the device
acknowledges bytes.

## Use with a BLE connection

Implement `SmpTransport` for your BLE stack. The SMP service is
`8d53dc1d-1db7-4cd3-868b-8a527460aa84`, and its characteristic
`da2e7828-fbce-4e01-ae9e-261174997c48` takes writes and sends notifications.
Your transport reports how many bytes one write can carry, and changes the
connection generation whenever a new physical connection replaces the old one.
The [Zephyr SMP transport specification](https://docs.zephyrproject.org/latest/services/device_mgmt/smp_transport.html)
has the details.

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

Only set `allowFragmentation` if the target can reassemble SMP requests that
arrive over several writes. If the link's write size is too small for the first
upload packet, the target needs reassembly anyway. Uploads send one SMP request
at a time. When the device rejects a command, the client throws
`SmpCommandError` with the SMP `code` and `group`.

After uploading, check the candidate with `images()`, then call `test()` with
its MCUboot image hash before `reset()`. Once you reconnect, check the device
identity and the active image's hash and version, and only then call
`confirm()`. Your app decides which device to update, how to reconnect, whether
the package is valid, and when to activate or confirm the new image.

## Hardware-in-the-loop testing

The package works with any `SmpTransport`. Its hardware tests use
[universal_ble](https://pub.dev/packages/universal_ble) and run on nRF52840
development kits. They grew out of the
[universal_ble HIL/FIT setup](https://github.com/usmanmehmood55/universal_ble/tree/main/hil)
and check fragmented SMP requests, recovery from failed writes, interrupted
uploads, rejection of corrupt images, MCUboot rollback, and a confirmed image
surviving a reboot. [hil/README.md](hil/README.md) explains how to run them.

## Maintainer

Usman Mehmood

[usman-embedded.com](https://usman-embedded.com) ·
[usmanmehmood55@gmail.com](mailto:usmanmehmood55@gmail.com)
