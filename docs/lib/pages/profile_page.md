# profile_page.dart

## Purpose
This screen manages the user profile and displays progress analytics.

## What it does
- loads user profile information from preferences
- supports editing name, age, sex, and profile image
- tracks the first-run welcome flow
- calculates training metrics over time windows
- shows aggregate charts and summaries for recent sessions

## Key user data
- `profile_name`
- `profile_age`
- `profile_sex`
- `profile_image_path`
- `training_sessions`

## Why it matters
This is how the app personalizes the user experience and shows improvement trends over specific periods.

## Related files
- [history_page.dart](history_page.dart)
- [connected_device_page.dart](connected_device_page.dart)
