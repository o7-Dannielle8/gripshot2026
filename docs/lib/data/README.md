# data folder documentation

## Purpose
This folder contains the persistence layer used by the app.

## Main files
- `local/database/database_helper.dart` — SQLite helper for recording training sessions
- `local/database/app_database.dart` — broader app database wrapper

## What it is used for
- saving session summaries
- keeping user/profile-related storage consistent
- supporting a local database layer behind the app

## Related files
- [../pages/connected_device_page.md](../pages/connected_device_page.md)
- [../pages/profile_page.md](../pages/profile_page.md)
