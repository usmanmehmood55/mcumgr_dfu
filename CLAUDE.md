# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Hardware findings not recorded elsewhere

- Uploads from macOS (native or Chrome) are limited by the BLE link, not by this client: ~80 ms per write on the nRF52840 DKs. Client-side tweaks and write pipelining won't speed them up.
- macOS only accepts connection intervals ≥ 15 ms, with max ≥ min + 15 ms and a 2–6 s supervision timeout. Firmware that requests faster intervals gets a much slower link on macOS than on Android.
- Chrome on macOS can only reconnect to a device it has recently seen advertise. Reconnecting without re-picking the device needs `chrome://flags/#enable-experimental-web-platform-features`.
