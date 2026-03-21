import 'dart:convert';
import 'package:attendance_app/global_variable/base_url.dart';
import 'package:attendance_app/global_variable/student_profile.dart';
import 'package:attendance_app/global_variable/token_handles.dart';
import 'package:attendance_app/permissions.dart';
import 'package:attendance_app/student_app/attendance_session/add_to_exception_list.dart';
import 'package:attendance_app/student_app/attendance_session/new_token_passing.dart/fallback_version/fallback_token_transfer.dart';
import 'package:attendance_app/student_app/attendance_session/new_token_passing.dart/secure_version/secure_qr_server.dart';
import 'package:attendance_app/student_app/attendance_session/new_token_passing.dart/secure_version/secure_token_transfer.dart';
import 'package:attendance_app/student_app/attendance_session/token_passing.dart';
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// Import the Session Data Manager
import 'package:attendance_app/global_variable/session_data_manager.dart';

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:http/http.dart' as http;

/// Attendance Session Page
class AttendanceSessionPage extends StatefulWidget {
  final int classroomId;
  final String classroomName;
  final String classroomCode;

  const AttendanceSessionPage({
    super.key,
    required this.classroomId,
    required this.classroomName,
    required this.classroomCode,
  });

  @override
  State<AttendanceSessionPage> createState() => _AttendanceSessionPageState();
}

class _AttendanceSessionPageState extends State<AttendanceSessionPage> {
  final LocalAuthentication auth = LocalAuthentication();
  bool _loading = true;
  String? _errorMessage;

  // Toggle state for Secure BLE Mode vs Fallback Mode
  bool _isSecureMode = true;
  bool _bluetoothOn = false;
  StreamSubscription<BluetoothAdapterState>? _btStateSubscription;

  @override
  void initState() {
    super.initState();

    // Listen for Bluetooth changes constantly
    _btStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (mounted) {
        setState(() {
          _bluetoothOn = state == BluetoothAdapterState.on;
        });
      }
    });

    _initializeSession();

    // Request permissions after the first frame renders
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPermissionsAndBluetooth();
    });
  }

  Future<void> _checkPermissionsAndBluetooth() async {
    // 1. Request all permissions using your class
    bool granted = await AppPermissions.requestAllPermissions(context);
    if (!granted) return; // User denied something

    // 2. Check current BT state
    var state = await FlutterBluePlus.adapterState.first;

    // 3. Auto-turn on (Android Only)
    if (state != BluetoothAdapterState.on && Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (e) {
        debugPrint("Could not prompt to turn on Bluetooth: $e");
      }
    }
  }

  /// Master function to handle auth and fetching keys
  Future<void> _initializeSession() async {
    // 1. (Optional) Verify Student Biometrics
    // await _verifyStudent();

    // 2. Fetch the session keys before showing the UI
    await _fetchSessionCredentials();
  }

  // ==========================================
  // FETCH SESSION CREDENTIALS FROM DJANGO
  // ==========================================
  Future<void> _fetchSessionCredentials() async {
    String classIdStr = widget.classroomId.toString();

    // Check if we already fetched them to avoid redundant API calls
    if (SessionDataManager.instance.hasCredentials(classIdStr)) {
      setState(() {
        _loading = false;
      });
      return;
    }

    try {
      final headers = await TokenHandles.getAuthHeaders();
      final response = await http.get(
        Uri.parse(
          "${BaseUrl.value}/session/classroom/${widget.classroomId}/credentials/",
        ),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        // Save the keys to global memory
        SessionDataManager.instance.saveCredentials(
          classroomId: classIdStr,
          kClass: data['k_class'],
          sessionSeed: data['session_seed'],
          // FIX: Explicitly convert the integer node_id to a string to prevent type errors
          nodeId: data['node_id'].toString(),
        );

        setState(() {
          _loading = false;
        });
      } else {
        setState(() {
          _errorMessage = "Failed to get session keys: ${response.body}";
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = "Network Error fetching keys: $e";
        _loading = false;
      });
    }
  }

  // ==========================================
  // OLD: BIOMETRIC VERIFICATION (Kept intact)
  // ==========================================
  Future<void> _verifyStudent() async {
    try {
      bool canCheckBiometrics = await auth.canCheckBiometrics;
      if (!canCheckBiometrics) {
        setState(() => _errorMessage = "Device has no fingerprint sensor.");
        return;
      }

      bool didAuthenticate = await auth.authenticate(
        localizedReason: "Authenticate to join attendance session",
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );

      if (!didAuthenticate) {
        setState(() => _errorMessage = "Fingerprint authentication failed.");
        return;
      }

      final headers = await TokenHandles.getAuthHeaders();
      final profileRes = await http.get(
        Uri.parse("${BaseUrl.value}/user/profile/"),
        headers: headers,
      );

      if (profileRes.statusCode != 200) {
        setState(
          () => _errorMessage =
              "Failed to fetch profile: ${profileRes.statusCode}",
        );
        return;
      }

      final profileData = jsonDecode(profileRes.body);
      final authKeyBackend = profileData['auth_key'];
      final fingerprintKey = await _generateFingerprintKey();

      if (authKeyBackend != fingerprintKey) {
        setState(
          () => _errorMessage =
              "Fingerprint/password changed or mismatch detected.",
        );
        return;
      }
    } catch (e) {
      setState(() => _errorMessage = "Error: $e");
    }
  }

  Future<String> _generateFingerprintKey() async {
    return "dummy_fingerprint_key";
  }

  // ==========================================
  // TOGGLE CONFIRMATION DIALOG
  // ==========================================
  Future<void> _handleToggleChange(bool newValue) async {
    // If turning ON secure mode, just do it.
    if (newValue == true) {
      setState(() {
        _isSecureMode = true;
      });
      return;
    }

    // If turning OFF secure mode, ask for confirmation to prevent accidents
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Disable Secure Mode?"),
        content: const Text(
          "Are you sure you want to use the fallback attendance method? "
          "This should only be used if your Bluetooth or Camera is failing.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false), // Cancel
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true), // Confirm
            child: const Text(
              "Use Fallback",
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() {
        _isSecureMode = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_errorMessage != null) {
      return Scaffold(
        appBar: AppBar(title: const Text("Attendance Session")),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red, fontSize: 16),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("OK"),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.classroomName)),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ==========================================
            // SECURE MODE TOGGLE UI
            // ==========================================
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: SwitchListTile(
                title: const Text("Secure BLE Verification"),
                subtitle: Text(
                  _isSecureMode
                      ? (_bluetoothOn
                            ? "Ready: High Security Mode"
                            : "Bluetooth is OFF. Please enable.")
                      : "Fallback Mode (Basic Token Passing)",
                  style: TextStyle(
                    color: _isSecureMode
                        ? (_bluetoothOn ? Colors.green : Colors.red)
                        : Colors.orange,
                  ),
                ),
                value: _isSecureMode,
                activeColor: Colors.green,
                onChanged: _handleToggleChange,
              ),
            ),
            const SizedBox(height: 40),

            // ==========================================
            // PASS TOKEN ROUTING
            // ==========================================
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: _isSecureMode ? Colors.blue : Colors.orange,
              ),
              onPressed: () {
                if (_isSecureMode) {
                  // Route to your new Secure BLE Page
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => SecurePeerGatewayPage(),
                    ),
                  );
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => FallbackTokenTransferPage(
                        ownUid: GlobalStudentProfile.currentStudent?.uid ?? "",
                        classroomId: widget.classroomId,
                      ),
                    ),
                  );
                }
              },
              child: Text(
                _isSecureMode ? "Pass Token (Secure)" : "Pass Token (Fallback)",
                style: const TextStyle(fontSize: 18),
              ),
            ),

            const SizedBox(height: 20),

            ElevatedButton(
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        AddExceptionPage(classroomId: widget.classroomId),
                  ),
                );
              },
              child: const Text(
                "Add to Exception List",
                style: TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
