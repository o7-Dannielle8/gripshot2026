# main.dart

## Purpose
This is the app entry point for the Gripshot Flutter app.

## What it does
- Initializes Flutter bindings
- Requests Bluetooth and location permissions before the app loads
- Builds the root MaterialApp
- Registers the `HomePage` and history route
- Sets the initial screen to the profile-oriented tab layout

## Why it matters
This file controls the app startup flow and all early platform setup. If Bluetooth or permission behavior changes, this is the first place to check.

## Key functions
- `main()` — app startup and permission request flow
- `MyApp` — root app widget and theme configuration

## Related files
- [home_page.dart](pages/home_page.dart)
- [initial_permission_handler.dart](widgets/initial_permission_handler.dart)
- [training_page.dart](pages/training_page.dart)
