import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Helpers to gate local persistence: Android 13+ uses [Permission.photos], older uses [Permission.storage].
class AppPermissionHandler {
  /// Prompts for the right media/storage capability and returns whether access was granted.
  /// If the user must fix things in Settings (e.g. permanently denied), shows an explanation dialog and returns false.
  static Future<bool> requestStoragePermission(BuildContext context) async {
    // First check if permission is already granted
    if (await _isAndroid13OrHigher()) {
      // Check photos permission for Android 13+
      final status = await Permission.photos.status;
      if (status.isGranted) {
        return true;
      }
      // Only request if not granted
      if (status.isDenied) {
        final result = await Permission.photos.request();
        return result.isGranted;
      }
    } else {
      // Check storage permission for older Android versions
      final status = await Permission.storage.status;
      if (status.isGranted) {
        return true;
      }
      // Only request if not granted
      if (status.isDenied) {
        final result = await Permission.storage.request();
        return result.isGranted;
      }
    }

    // If permission is permanently denied, show explanation dialog
    if (context.mounted) {
      await _showPermissionExplanationDialog(context);
    }
    return false;
  }

  /// Heuristic: use [Permission.photos] when the plugin reports any settled state for it
  /// (granted / denied / permanently denied); otherwise fall back to legacy [Permission.storage].
  static Future<bool> _isAndroid13OrHigher() async {
    // Check if photos permission is available (indicates Android 13+)
    return await Permission.photos.isPermanentlyDenied || 
           await Permission.photos.isGranted ||
           await Permission.photos.isDenied;
  }

  /// Tells the user why storage/media access matters and offers the system settings screen.
  static Future<void> _showPermissionExplanationDialog(BuildContext context) async {
    return showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(
            'Storage Permission Required',
            style: GoogleFonts.poppins(
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Text(
            'This app needs storage permission to save your training sessions and data. '
            'Without this permission, your training history will not be saved. '
            'Please grant the permission in your device settings.',
            style: GoogleFonts.poppins(
              fontSize: 14,
              color: Colors.grey[700],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'Cancel',
                style: GoogleFonts.poppins(
                  fontSize: 14,
                  color: Colors.grey[600],
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await openAppSettings();
              },
              child: Text(
                'Open Settings',
                style: GoogleFonts.poppins(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Fast path if photos or storage is already granted; otherwise delegates to [requestStoragePermission].
  static Future<bool> checkAndRequestPermissions(BuildContext context) async {
    // First check if permissions are already granted
    bool hasPermission = false;
    
    if (await _isAndroid13OrHigher()) {
      hasPermission = await Permission.photos.status.isGranted;
    } else {
      hasPermission = await Permission.storage.status.isGranted;
    }

    // If already granted, return true immediately
    if (hasPermission) {
      return true;
    }

    // If not granted, request permission
    return await requestStoragePermission(context);
  }
} 