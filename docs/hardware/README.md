# hardware folder documentation

## Purpose
This folder keeps all hardware-specific code and firmware documentation together.

## Main file
- `gripshot_gun.ino` — Arduino firmware for the Gripshot dry-fire gun

## What the firmware does
- powers the trigger, solenoid, buzzer, and laser outputs
- listens for trigger press events
- sends BLE notifications to the mobile app
- communicates training signals expected by the Flutter app

## Integration note
This file must match the app’s expected BLE UUIDs and string payloads, especially in the parser used by the training logic.
