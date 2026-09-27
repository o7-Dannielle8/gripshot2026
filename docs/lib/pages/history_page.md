# history_page.dart

## Purpose
This screen displays previous training sessions and their analytics.

## What it does
- loads training session data from shared preferences
- sorts the sessions newest-first
- shows summary metrics per session
- displays sensor charts for grip, pitch, and touch
- opens a details dialog for a selected session

## Key data handled
- date
- total score
- accuracy
- shots fired
- average score
- device name
- grip/pitch/touch history arrays

## Why it matters
This file is the analytics layer that gives the user feedback on improvement over time.

## Related files
- [profile_page.dart](profile_page.dart)
- [connected_device_page.dart](connected_device_page.dart)
