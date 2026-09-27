# lib folder documentation

This folder contains the Flutter application source code for the Gripshot dry-fire training system.

## Overview

The app is organized into functional areas:
- app entry points and global configuration
- page-level screens for the user flow
- reusable widgets and permission handling
- data models and local persistence helpers

## Main structure

- `main.dart` — app bootstrap and startup permissions
- `pages/` — screens for training, history, profile, and connection management
- `widgets/` — permission startup gate and UI wrappers
- `utils/` — permission helper utilities
- `models/` — lightweight data models
- `data/` — persistence and local data access layers

## How to use this folder

Use this folder as the code map for the app itself. If you want to change the app behavior, start here before editing lower-level files.

## Important files in this folder

- [main.dart](../main.dart)
- [pages/](../pages)
- [widgets/](../widgets)
- [utils/](../utils)
- [models/](../models)
- [data/](../data)
