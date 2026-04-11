import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_fonts/google_fonts.dart';
import '../utils/permission_handler.dart' as app_permissions;

/// Wraps the real app [child]: on first frame it runs a permission pass (storage,
/// then location for BLE scan, then Bluetooth / scan / connect). Shows a loading
/// scaffold until checks finish; on denial may show a blocking dialog + snackbar.
class InitialPermissionHandler extends StatefulWidget {
  /// Main app tree (e.g. [HomePage]) after the handler’s loading pass finishes.
  final Widget child;

  const InitialPermissionHandler({
    Key? key,
    required this.child,
  }) : super(key: key);

  @override
  State<InitialPermissionHandler> createState() => _InitialPermissionHandlerState();
}

class _InitialPermissionHandlerState extends State<InitialPermissionHandler> {
  /// While true, [build] shows a minimal loading [MaterialApp] instead of [widget.child].
  bool _isCheckingPermissions = true;

  /// Set when every requested capability is granted (not currently read in [build]).
  bool _hasAllPermissions = false;

  /// Defers [_checkAllPermissions] slightly so the widget has a stable [mounted] context.
  @override
  void initState() {
    super.initState();
    // Add a small delay to ensure the widget is properly mounted
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        _checkAllPermissions();
      }
    });
  }

  /// Requests storage (session data), then location, then Bluetooth + scan + connect in order.
  /// Stops on first denial with a snackbar or settings dialog; on success clears the loading state.
  Future<void> _checkAllPermissions() async {
    try {
      // Check storage permission
      bool hasStoragePermission = await app_permissions.AppPermissionHandler.checkAndRequestPermissions(context);
      if (!hasStoragePermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Storage permission is required to save training sessions',
                style: GoogleFonts.poppins(),
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // Check location permission (required for Bluetooth scanning on Android)
      var locationStatus = await Permission.location.status;
      if (!locationStatus.isGranted) {
        locationStatus = await Permission.location.request();
        if (!locationStatus.isGranted) {
          if (mounted) {
            _showLocationPermissionDialog();
          }
          return;
        }
      }

      // Check Bluetooth permissions
      var bluetoothStatus = await Permission.bluetooth.status;
      if (!bluetoothStatus.isGranted) {
        bluetoothStatus = await Permission.bluetooth.request();
        if (!bluetoothStatus.isGranted) {
          if (mounted) {
            _showPermissionDialog();
          }
          return;
        }
      }
      
      var bluetoothScanStatus = await Permission.bluetoothScan.status;
      if (!bluetoothScanStatus.isGranted) {
        bluetoothScanStatus = await Permission.bluetoothScan.request();
        if (!bluetoothScanStatus.isGranted) {
          if (mounted) {
            _showPermissionDialog();
          }
          return;
        }
      }

      var bluetoothConnectStatus = await Permission.bluetoothConnect.status;
      if (!bluetoothConnectStatus.isGranted) {
        bluetoothConnectStatus = await Permission.bluetoothConnect.request();
        if (!bluetoothConnectStatus.isGranted) {
          if (mounted) {
            _showPermissionDialog();
          }
          return;
        }
      }

      setState(() {
        _hasAllPermissions = true;
        _isCheckingPermissions = false;
      });
    } catch (e) {
      print('Error checking permissions: $e');
      if (mounted) {
        setState(() {
          _isCheckingPermissions = false;
        });
      }
    }
  }

  /// Non-dismissible prompt to open system settings, then re-run [_checkAllPermissions].
  void _showPermissionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(
            'Bluetooth Permissions Required',
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            'Gripshot needs Bluetooth permissions to connect to your training device. '
            'These permissions are required for the app to function properly.',
            style: GoogleFonts.poppins(),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await openAppSettings();
                _checkAllPermissions();
              },
              child: Text(
                'Open Settings',
                style: GoogleFonts.poppins(
                  color: Theme.of(context).colorScheme.secondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Same pattern as [_showPermissionDialog] but copy explains Android BLE scan requirement.
  void _showLocationPermissionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(
            'Location Permission Required',
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            'Android requires location permission for Bluetooth scanning. '
            'This is a system requirement, and we do not use your location data. '
            'The permission is only used for Bluetooth device discovery.',
            style: GoogleFonts.poppins(),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await openAppSettings();
                _checkAllPermissions();
              },
              child: Text(
                'Open Settings',
                style: GoogleFonts.poppins(
                  color: Theme.of(context).colorScheme.secondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Spinner-only app until checks complete; then returns [widget.child] inside the parent tree.
  @override
  Widget build(BuildContext context) {
    if (_isCheckingPermissions) {
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  'Checking permissions...',
                  style: GoogleFonts.poppins(
                    fontSize: 16,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return widget.child;
  }
} 