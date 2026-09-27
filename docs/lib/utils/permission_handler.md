# permission_handler.dart

## Purpose
This file manages app permission flow for storage/media access.

## What it does
- checks whether the device is Android 13+
- chooses the correct permission type for the OS version
- requests permission when needed
- explains why permission is necessary
- opens system settings when the user needs to grant it manually

## Important behavior
This support file is not the main BLE permission code. It is specifically focused on local storage access and saving session data.

## Related files
- [../widgets/initial_permission_handler.dart](../widgets/initial_permission_handler.dart)
- [../main.md](../main.md)
