import 'dart:convert';
import 'package:attendance_app/global_variable/base_url.dart';
import 'package:attendance_app/global_variable/student_profile.dart';
import 'package:attendance_app/global_variable/token_handles.dart';
import 'package:attendance_app/permissions.dart';
import 'package:attendance_app/student_app/attendance_session/add_to_exception_list.dart';
import 'package:attendance_app/student_app/attendance_session/new_token_passing.dart/fallback_version/fallback_token_transfer.dart';
import 'package:attendance_app/student_app/attendance_session/new_token_passing.dart/secure_version/secure_token_transfer.dart';
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:attendance_app/global_variable/session_data_manager.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:http/http.dart' as http;

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

  // Toggle state
  bool _isSecureMode = true;
  bool _bluetoothOn = false;
  StreamSubscription<BluetoothAdapterState>? _btStateSubscription;

  // Hidden Trigger Logic (Developer Options Style)
  int _tapCount = 0;
  DateTime? _lastTapTime;
  final int _totalSteps = 8;
  final int _showAtStep = 5; // Starts showing toast at "3 steps away"

  @override
  void initState() {
    super.initState();
    _btStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (mounted) {
        setState(() {
          _bluetoothOn = state == BluetoothAdapterState.on;
        });
      }
    });
    _initializeSession();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPermissionsAndBluetooth();
    });
  }

  @override
  void dispose() {
    _btStateSubscription?.cancel();
    super.dispose();
  }

  void _handleSecretTap() {
    final now = DateTime.now();

    // Reset if taps are too slow (1.5s gap)
    if (_lastTapTime != null &&
        now.difference(_lastTapTime!).inMilliseconds > 1500) {
      _tapCount = 0;
    }

    _lastTapTime = now;
    _tapCount++;

    if (_tapCount >= _showAtStep && _tapCount < _totalSteps) {
      int stepsAway = _totalSteps - _tapCount;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("You are $stepsAway steps away from Fallback Mode"),
          duration: const Duration(milliseconds: 600),
          // 👇 CHANGED: Removed width and set behavior to fixed for full-width
          behavior: SnackBarBehavior.fixed,
        ),
      );
    } else if (_tapCount == _totalSteps) {
      setState(() {
        _isSecureMode = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Fallback Mode Unlocked ⚠️"),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.fixed, // Consistent full-width look
        ),
      );
    }
  }

  Future<void> _checkPermissionsAndBluetooth() async {
    bool granted = await AppPermissions.requestAllPermissions(context);
    if (!granted) return;

    var state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on && Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (e) {
        debugPrint("Could not prompt to turn on Bluetooth: $e");
      }
    }
  }

  Future<void> _initializeSession() async {
    await _fetchSessionCredentials();
  }

  Future<void> _fetchSessionCredentials() async {
    String classIdStr = widget.classroomId.toString();
    if (SessionDataManager.instance.hasCredentials(classIdStr)) {
      setState(() => _loading = false);
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
        SessionDataManager.instance.saveCredentials(
          classroomId: classIdStr,
          kClass: data['k_class'],
          sessionSeed: data['session_seed'],
          nodeId: data['node_id'].toString(),
        );
        setState(() => _loading = false);
      } else {
        setState(() {
          _errorMessage = "Failed to get session keys: ${response.body}";
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = "Network Error: $e";
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));

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
                style: const TextStyle(color: Colors.red),
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
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        title: Text(widget.classroomName),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.black,
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // ==========================================
            // SECRET SECURITY STATUS CHIP
            // ==========================================
            GestureDetector(
              onTap: _handleSecretTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 20,
                ),
                decoration: BoxDecoration(
                  color: _isSecureMode ? Colors.white : Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(
                    color: _isSecureMode
                        ? Colors.blue.shade100
                        : Colors.orange.shade200,
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isSecureMode
                          ? Icons.shield_outlined
                          : Icons.history_edu_rounded,
                      color: _isSecureMode ? Colors.blue : Colors.orange,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _isSecureMode
                          ? "SECURE MODE ACTIVE"
                          : "FALLBACK MODE ACTIVE",
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                        color: _isSecureMode
                            ? Colors.blue.shade700
                            : Colors.orange.shade900,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 50),

            // ==========================================
            // PASS TOKEN ACTION CARD
            // ==========================================
            _buildActionCard(
              title: _isSecureMode
                  ? "Pass Token (Secure)"
                  : "Pass Token (Fallback)",
              subtitle: _isSecureMode
                  ? (_bluetoothOn
                        ? "Ready for BLE proximity check"
                        : "Turn on Bluetooth to continue")
                  : "Basic manual verification mode",
              color: _isSecureMode
                  ? (_bluetoothOn ? Colors.blue : Colors.red)
                  : Colors.orange,
              icon: _isSecureMode
                  ? Icons.bolt_rounded
                  : Icons.qr_code_2_rounded,
              onPressed: () {
                if (_isSecureMode) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => SecurePeerGatewayPage(
                        classroomId: widget.classroomId,
                      ),
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
            ),

            const SizedBox(height: 20),

            // ==========================================
            // EXCEPTION LIST CARD
            // ==========================================
            _buildActionCard(
              title: "Add to Exception List",
              subtitle: "Hardware issues? Notify your teacher",
              color: Colors.grey.shade700,
              icon: Icons.error_outline_rounded,
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        AddExceptionPage(classroomId: widget.classroomId),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionCard({
    required String title,
    required String subtitle,
    required Color color,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.08),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(icon, color: color, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: Colors.grey.shade300,
                  size: 14,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
