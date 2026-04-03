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
import 'package:firebase_messaging/firebase_messaging.dart';

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

class _AttendanceSessionPageState extends State<AttendanceSessionPage>
    with TickerProviderStateMixin {
  final LocalAuthentication auth = LocalAuthentication();
  bool _loading = true;
  String? _errorMessage;

  bool _isSecureMode = true;
  bool _bluetoothOn = false;
  StreamSubscription<BluetoothAdapterState>? _btStateSubscription;

  bool _isConnectedToMasterNode = false;
  StreamSubscription<RemoteMessage>? _fcmSubscription;

  int _tapCount = 0;
  DateTime? _lastTapTime;
  final int _totalSteps = 8;
  final int _showAtStep = 5;

  // Animation controllers — initialized in initState, never late to avoid
  // LateInitializationError on hot-reload / early rebuild
  AnimationController? _pulseController;
  AnimationController? _fadeInController;
  Animation<double>? _pulseAnimation;
  Animation<double>? _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _fadeInController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );

    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController!, curve: Curves.easeInOut),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fadeInController!, curve: Curves.easeOut),
    );

    _btStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (mounted) {
        setState(() {
          _bluetoothOn = state == BluetoothAdapterState.on;
        });
      }
    });

    _initializeSession();
    _listenForConnectionVerification();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPermissionsAndBluetooth();
    });
  }

  void _listenForConnectionVerification() {
    _fcmSubscription = FirebaseMessaging.onMessage.listen((
      RemoteMessage message,
    ) {
      if (message.data['type'] == 'connection_verified' &&
          message.data['classroom_id'] == widget.classroomId.toString()) {
        if (mounted) {
          setState(() {
            _isConnectedToMasterNode = true;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _btStateSubscription?.cancel();
    _fcmSubscription?.cancel();
    _pulseController?.dispose();
    _fadeInController?.dispose();
    super.dispose();
  }

  void _handleSecretTap() {
    final now = DateTime.now();
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
          behavior: SnackBarBehavior.fixed,
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
      _fadeInController?.forward();
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
        _fadeInController?.forward();
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

  // ─────────────────────────── COLOR PALETTE ────────────────────────────
  static const _bg = Color(0xFF0D0F14);
  static const _surface = Color(0xFF161921);
  static const _surfaceAlt = Color(0xFF1E2029);
  static const _accent = Color(0xFF4F8EF7);
  static const _accentGlow = Color(0x334F8EF7);
  static const _success = Color(0xFF34D399);
  static const _successGlow = Color(0x2234D399);
  static const _warning = Color(0xFFFBBF24);
  static const _warningGlow = Color(0x33FBBF24);
  static const _danger = Color(0xFFEF4444);
  static const _textPrimary = Color(0xFFEEF2FF);
  static const _textSecondary = Color(0xFF8B92A9);
  static const _divider = Color(0xFF252830);

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: _bg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(_accent),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                "Securing session...",
                style: TextStyle(
                  color: _textSecondary,
                  fontSize: 14,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        backgroundColor: _bg,
        appBar: _buildAppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: _danger.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.wifi_off_rounded,
                    color: _danger,
                    size: 40,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  "Session Error",
                  style: TextStyle(
                    color: _textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _textSecondary, fontSize: 13),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text(
                      "Go Back",
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _bg,
      appBar: _buildAppBar(),
      body: FadeTransition(
        opacity: _fadeAnimation ?? const AlwaysStoppedAnimation(1.0),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Session Header ──
              _buildSessionHeader(),
              const SizedBox(height: 28),

              // ── Mode Badge (secret tap) ──
              _buildModeBadge(),
              const SizedBox(height: 28),

              // ── Master Node Banner ──
              if (_isConnectedToMasterNode) ...[
                _buildMasterNodeBanner(),
                const SizedBox(height: 24),
              ],

              // ── Section Label ──
              _sectionLabel("Actions"),
              const SizedBox(height: 14),

              // ── Pass Token Card ──
              _buildPrimaryActionCard(),
              const SizedBox(height: 14),

              // ── Exception Card ──
              _buildExceptionCard(),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _bg,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
        color: _textSecondary,
        onPressed: () => Navigator.pop(context),
      ),
      title: Text(
        widget.classroomName,
        style: const TextStyle(
          color: _textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      centerTitle: true,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: _divider),
      ),
    );
  }

  Widget _buildSessionHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _divider),
      ),
      child: Row(
        children: [
          // Live pulse indicator
          AnimatedBuilder(
            animation: _pulseAnimation ?? const AlwaysStoppedAnimation(1.0),
            builder: (_, __) => Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _accentGlow,
              ),
              child: Center(
                child: Transform.scale(
                  scale: _pulseAnimation?.value ?? 1.0,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: _accent,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: _accentGlow,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        "LIVE",
                        style: TextStyle(
                          color: _accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.classroomCode,
                      style: TextStyle(
                        color: _textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  "Session in progress",
                  style: TextStyle(
                    color: _textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          // Bluetooth status dot
          Column(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _bluetoothOn ? _success : _danger,
                  boxShadow: [
                    BoxShadow(
                      color: (_bluetoothOn ? _success : _danger).withOpacity(
                        0.5,
                      ),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                "BLE",
                style: TextStyle(
                  color: _textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildModeBadge() {
    final isSecure = _isSecureMode;
    final color = isSecure ? _accent : _warning;
    final glowColor = isSecure ? _accentGlow : _warningGlow;

    return GestureDetector(
      onTap: _handleSecretTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
        decoration: BoxDecoration(
          color: glowColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.4), width: 1.5),
        ),
        child: Row(
          children: [
            Icon(
              isSecure
                  ? Icons.verified_user_rounded
                  : Icons.history_edu_rounded,
              color: color,
              size: 22,
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isSecure ? "SECURE MODE ACTIVE" : "FALLBACK MODE ACTIVE",
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isSecure
                      ? "BLE GATT + HOTP end-to-end verified"
                      : "QR + GPS radius verification",
                  style: TextStyle(
                    color: color.withOpacity(0.7),
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
            const Spacer(),
            Icon(
              Icons.chevron_right_rounded,
              color: color.withOpacity(0.4),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMasterNodeBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _successGlow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _success.withOpacity(0.4), width: 1.5),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _success.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.hub_rounded, color: _success, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Chain Secured ✅",
                  style: TextStyle(
                    color: _success,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  "Linked to Master Node · Attendance confirmed",
                  style: TextStyle(
                    color: _success.withOpacity(0.7),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String label) {
    return Text(
      label.toUpperCase(),
      style: TextStyle(
        color: _textSecondary,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.6,
      ),
    );
  }

  Widget _buildPrimaryActionCard() {
    final isSecure = _isSecureMode;
    final btReady = _bluetoothOn || !isSecure;
    final color = isSecure ? (btReady ? _accent : _danger) : _warning;
    final glowColor = isSecure
        ? (btReady ? _accentGlow : _danger.withOpacity(0.15))
        : _warningGlow;

    return GestureDetector(
      onTap: () {
        if (isSecure) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  SecurePeerGatewayPage(classroomId: widget.classroomId),
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
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [color.withOpacity(0.18), color.withOpacity(0.06)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.35), width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      isSecure ? Icons.bolt_rounded : Icons.qr_code_2_rounded,
                      color: color,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isSecure ? "Pass Token" : "Pass Token",
                          style: TextStyle(
                            color: _textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          isSecure
                              ? (btReady
                                    ? "BLE handshake ready"
                                    : "Turn on Bluetooth to continue")
                              : "Fallback — QR scan mode",
                          style: TextStyle(
                            color: color.withOpacity(0.85),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward_ios_rounded,
                    color: color.withOpacity(0.5),
                    size: 14,
                  ),
                ],
              ),
              if (isSecure && !btReady) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: _danger.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.bluetooth_disabled_rounded,
                        color: _danger,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        "Bluetooth is off — tap to enable",
                        style: TextStyle(
                          color: _danger.withOpacity(0.9),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExceptionCard() {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                AddExceptionPage(classroomId: widget.classroomId),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _divider),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: _surfaceAlt,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(
                Icons.error_outline_rounded,
                color: _textSecondary,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Add to Exception List",
                    style: TextStyle(
                      color: _textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    "Hardware issue? Notify your teacher",
                    style: TextStyle(color: _textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded, color: _divider, size: 14),
          ],
        ),
      ),
    );
  }
}
