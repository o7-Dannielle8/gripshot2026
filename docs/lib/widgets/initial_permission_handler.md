# initial_permission_handler.dart

## Purpose
This widget ensures the app only starts after all required runtime permissions are approved.

## What it does
- checks storage/media permissions
- checks location permission for BLE scanning
- checks Bluetooth, Bluetooth Scan, and Bluetooth Connect permissions
- shows blocking dialogs if a permission is denied
- keeps the user on a loading screen until access is granted

## Why it matters
Android BLE scanning requires location access, and the app needs Bluetooth permissions to talk to the gun.

## Related files
- [../../main.dart](../../main.dart)
- [../../pages/training_page.dart](../../pages/training_page.dart)
