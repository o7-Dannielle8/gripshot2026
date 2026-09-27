# user_profile.dart

## Purpose
This file defines an immutable user profile model.

## What it stores
- name
- sex
- age
- onboarding flag

## What it provides
- `copyWith()` for updating fields
- `toMap()` for serialization
- `fromMap()` for deserialization

## Why it matters
This helps keep the app profile state simple and reusable, especially when saving or loading profile data from local storage.
