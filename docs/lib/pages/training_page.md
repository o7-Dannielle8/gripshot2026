# training_page.dart

## Purpose
This screen is responsible for discovering and connecting to Gripshot hardware.

## What it does
- checks if Bluetooth is available and enabled
- verifies location permission is granted
- scans for nearby devices with names matching the Gripshot gun
- lists the available results
- starts the connection flow for the chosen device

## Key concepts
- uses `flutter_blue_plus` to scan for BLE devices
- listens for scan results and scanning state
- uses a service UUID for the Gripshot gun service
- is the entry point before a live dry-fire session starts

## Typical flow
1. User opens the Training tab.
2. App checks Bluetooth and Android permissions.
3. App starts scanning.
4. Nearby Gripshot gun devices appear.
5. User selects a device to connect.

## Related files
- [connected_device_page.dart](connected_device_page.dart)
- [connected_page.dart](connected_page.dart)
- [../../widgets/initial_permission_handler.dart](../../widgets/initial_permission_handler.dart)
