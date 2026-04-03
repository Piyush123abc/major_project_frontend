import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class AppPermissions {
  // ✅ Notification FIRST — before Firebase tries to grab it automatically
  static final List<Permission> _permissions = [
    Permission.notification,
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.bluetoothAdvertise,
    Permission.location,
    Permission.camera,
  ];

  static Future<bool> requestAllPermissions(BuildContext context) async {
    // ✅ Bump to 4s — Firebase background engine takes time to fully start
    await Future.delayed(const Duration(milliseconds: 1000));

    for (final permission in _permissions) {
      await Future.delayed(const Duration(milliseconds: 200)); // bigger gap

      final status = await permission.request();

      if (status.isPermanentlyDenied) {
        await _showPermanentDeniedDialog(context, permission);
        return false;
      }
      // Only hard-fail on non-notification denials
      if (status.isDenied && permission != Permission.notification) {
        return false;
      }
    }

    await Future.delayed(const Duration(milliseconds: 500));

    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      await Permission.ignoreBatteryOptimizations.request();
    }

    return true;
  }

  static Future<void> _showPermanentDeniedDialog(
    BuildContext context,
    Permission perm,
  ) async {
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Permission Required"),
        content: Text(
          "${perm.toString().replaceAll("Permission.", "")} is permanently denied. Please enable it in settings.",
        ),
        actions: [
          TextButton(
            onPressed: () {
              openAppSettings();
              Navigator.pop(context);
            },
            child: const Text("Open Settings"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
        ],
      ),
    );
  }
}
