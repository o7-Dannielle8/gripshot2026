# pages folder documentation

## Purpose
This folder contains the main app screens and the device interaction flow for the Gripshot training system.

## Main screens
- `home_page.dart` — top-level tab navigation
- `training_page.dart` — BLE scan and gun connection
- `connected_page.dart` — live BLE connection monitoring
- `connected_device_page.dart` — training session logic and hit scoring
- `history_page.dart` — saved session analytics
- `profile_page.dart` — user profile and progress metrics

## How to use it
Browse the screens in order of app flow:
1. `home_page.dart`
2. `training_page.dart`
3. `connected_device_page.dart`
4. `history_page.dart`
5. `profile_page.dart`

## Important behavior
The app is designed around a Bluetooth dry-fire training device. Most of the actual logic for scoring and session tracking lives in the connected-device page.
