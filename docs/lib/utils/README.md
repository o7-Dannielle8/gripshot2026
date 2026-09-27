# utils folder documentation

## Purpose
This folder contains small utility helpers that support app permissions and platform behavior.

## Main file
- `permission_handler.dart` — handles storage permission requests and settings navigation

## Why it matters
This code keeps the app from failing during setup when a user blocks permissions or uses an Android version with stricter access rules.
