# connected_device_page.dart

## Purpose
This is the main logic file for the dry-fire training system.

## What it does
- connects to the Gripshot gun and optional target
- reads live BLE sensor data
- parses trigger and laser events
- calculates the target hit score
- tracks bullet count and training completion
- saves session summary information locally
- renders the live training UI and analytics

## Key features
- 4x4 scoring grid
- trigger + laser hit coordination
- grip/pitch/touch live reading support
- training vs practice mode
- session persistence in SharedPreferences

## Important note
This is the most important file in the app if you want to change scoring, hit logic, or the training flow.

## Related files
- [training_page.dart](training_page.dart)
- [history_page.dart](history_page.dart)
- [profile_page.dart](profile_page.dart)
- [../../data/local/database/database_helper.dart](../../data/local/database/database_helper.dart)
