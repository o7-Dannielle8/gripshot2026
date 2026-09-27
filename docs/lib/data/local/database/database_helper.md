# database_helper.dart

## Purpose
This file creates and manages the app’s local SQLite database for saved training sessions.

## What it does
- opens a SQLite database named `gripshot.db`
- creates the `training_sessions` table
- inserts a training session record
- loads saved sessions ordered by timestamp
- deletes a session by ID

## Main table
`training_sessions` stores:
- `id`
- `timestamp`
- `total_score`
- `hit_history`
- `grip_history`
- `pitch_history`

## Why it matters
This is the direct storage layer for history and analytics. Sessions saved here are later read by the History/Profile views.

## Related files
- [../../../pages/connected_device_page.md](../../../pages/connected_device_page.md)
- [../../../pages/history_page.md](../../../pages/history_page.md)
