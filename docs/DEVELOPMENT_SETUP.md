# Gripshot Development Setup (Windows)

This guide gets the Flutter app running from VS Code on a physical Android phone. BLE training requires a powered Gripshot ESP32 and, for target scoring, compatible target hardware.

## 1. Install the tools

1. Install [Visual Studio Code](https://code.visualstudio.com/).
2. Install the [Flutter SDK](https://docs.flutter.dev/get-started/install/windows) using the official Windows instructions. Add the Flutter SDK's `bin` folder to your Windows `PATH`.
3. Install [Android Studio](https://developer.android.com/studio). In Android Studio's SDK Manager, install the Android SDK platform and Android SDK Build-Tools recommended by the current Flutter setup guide. Install the Android SDK Command-line Tools as well.
4. Open VS Code and install the **Flutter** extension. The Dart extension is installed with it or will be recommended automatically.
5. Open a new PowerShell terminal and check the toolchain:

```powershell
flutter --version
flutter doctor -v
```

Address any Android toolchain issues reported by `flutter doctor`. Accept Android SDK licenses when prompted:

```powershell
flutter doctor --android-licenses
```

Run `flutter doctor -v` again and confirm the Flutter and Android toolchain checks pass. A Windows desktop or iOS toolchain is not needed to run this project on Android.

## 2. Get the project and packages

If you do not already have the repository locally, clone it:

```powershell
git clone https://github.com/o7-Dannielle8/gripshot2026.git
cd gripshot2026
```

If you already have the repository, open its project root in VS Code. It is the folder containing `pubspec.yaml` and `lib/`.

Fetch dependencies:

```powershell
flutter pub get
```

In VS Code, open `lib/main.dart`. The Flutter extension should recognize the project and show Flutter run/debug actions.

## 3. Prepare an Android phone

1. On the phone, enable Developer options and USB debugging.
2. Connect it to the PC with a data-capable USB cable and approve the debugging prompt shown on the phone.
3. On Windows, install the phone manufacturer's USB driver if the device is not detected.
4. Check that Flutter sees the phone:

```powershell
flutter devices
```

If more than one device is listed, note the phone's device ID for the run command.

## 4. Run the app

From the project root:

```powershell
flutter run
```

To select a specific device:

```powershell
flutter run -d <device-id>
```

The app requests Bluetooth and location permissions during startup. Grant them to test BLE discovery. The Android permissions are declared in `android/app/src/main/AndroidManifest.xml`; runtime requests are handled in `lib/main.dart` and `lib/widgets/initial_permission_handler.dart`.

## 5. Connect Gripshot hardware

1. Power on the ESP32 and ensure its firmware is advertising over BLE.
2. For the current app's gun list, the advertised device name must contain `Gripshot Gun`. The current scan list filters on the name; although a service UUID constant exists in the app, scanning is not currently filtered by that UUID.
3. Open the app's Training tab, start scanning, and select the gun.
4. To test scoring, also power on the compatible target and connect it from the training screen.
5. Confirm the firmware's BLE service/characteristic UUIDs and notification text match the contracts documented in [GRIPSHOT_DOCUMENTATION.md](GRIPSHOT_DOCUMENTATION.md).

The Flutter app does not upload firmware to the ESP32. Compile and upload the firmware separately with Arduino IDE or the toolchain used for the board.

## 6. Run checks

From the project root:

```powershell
flutter analyze
flutter test
```

To build an Android debug APK:

```powershell
flutter build apk --debug
```

The APK is written under `build/app/outputs/flutter-apk/`. For BLE testing, prefer `flutter run` on a physical phone because most emulators do not provide the Bluetooth behavior needed to test the real hardware workflow.

## Troubleshooting

- **`flutter` is not recognized:** add the Flutter SDK `bin` directory to `PATH`, open a new terminal, and retry.
- **Android licenses or SDK errors:** install the missing SDK components in Android Studio SDK Manager, run `flutter doctor --android-licenses`, then rerun `flutter doctor -v`.
- **Phone is not listed:** approve the USB debugging prompt, use a data cable, install the phone USB driver, then retry `flutter devices`.
- **No gun appears:** check that Bluetooth is on, permissions are granted, the ESP32 is advertising, and its device name contains `Gripshot Gun`.
- **The device appears but connection setup fails:** verify the gun service and notification characteristic UUIDs against `connected_device_page.dart` and the firmware.
- **No sensor values or hits arrive:** check the BLE notification characteristic and exact payload format. Use the function map and payload examples in [GRIPSHOT_DOCUMENTATION.md](GRIPSHOT_DOCUMENTATION.md).
