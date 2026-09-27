# gripshot_gun.ino

## Purpose
This is the Arduino firmware for the physical Gripshot dry-fire gun.

## What it does
- initializes the button, solenoid, buzzer, and laser pins
- checks for trigger presses
- activates the hardware response when the user presses the trigger
- sends BLE notification strings to the connected phone

## Important message formats
The mobile app expects messages like:
- `button_pressed`
- `BUTTON PRESSED`
- `LASER DETECTED ...`

If the firmware sends different text, the app may not register hits correctly.

## Integration requirement
The BLE UUIDs and payload strings must align with the app code in:
- [../lib/pages/training_page.md](../lib/pages/training_page.md)
- [../lib/pages/connected_device_page.md](../lib/pages/connected_device_page.md)

## Typical hardware use
This code sits on the gun controller and is responsible for turning a trigger action into a live training event that the app can understand.
