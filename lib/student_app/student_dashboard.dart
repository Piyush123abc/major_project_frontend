import 'dart:async';
import 'dart:convert';
import 'package:attendance_app/global_variable/session_data_manager.dart';
import 'package:attendance_app/global_variable/student_profile.dart';
import 'package:attendance_app/security_reporter.dart';
import 'package:attendance_app/student_app/absence_proposal/ProposalSelectionPage.dart';
import 'package:attendance_app/student_app/attendance_records/attendance_record_list.dart';
import 'package:attendance_app/student_app/attendance_session/attendance_session_dasboard.dart';
import 'package:attendance_app/student_app/classroom_list/classroom_list.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../global_variable/base_url.dart';
import '../global_variable/token_handles.dart';

class StudentDashboardPage extends StatefulWidget {
  const StudentDashboardPage({super.key});

  @override
  State<StudentDashboardPage> createState() => _StudentDashboardPageState();
}

class _StudentDashboardPageState extends State<StudentDashboardPage> {
  static const _platform = MethodChannel('com.attendance/command');

  Map<String, dynamic>? profile;
  List<dynamic> enrollments = [];
  Map<int, bool> sessionStatus = {};
  bool isLoading = true;

  int _secretTapCount = 0;
  Timer? _tapTimer;

  // ── Design constants ──────────────────────────────────────────────────────
  static const _dark = Color(0xFF1A1A2E);
  static const _accent = Color(0xFF4361EE);

  @override
  void initState() {
    super.initState();
    SessionDataManager.instance.clearAll();
    debugPrint("🧹 Crypto cache purged on Dashboard entry.");
    _fetchDashboardData();
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
      _syncFCMToken();
    });
  }

  @override
  void dispose() {
    _tapTimer?.cancel();
    super.dispose();
  }

  // ─── BACKDOOR (UNCHANGED) ─────────────────────────────────────────────────

  void _handleSecretTap() {
    _secretTapCount++;
    _tapTimer?.cancel();
    _tapTimer = Timer(const Duration(seconds: 2), () {
      _secretTapCount = 0;
    });

    final int tapsLeft = 8 - _secretTapCount;

    if (tapsLeft <= 3 && tapsLeft > 0) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Tap $tapsLeft more time(s) to access Admin Sync."),
          duration: const Duration(milliseconds: 500),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else if (_secretTapCount >= 8) {
      _secretTapCount = 0;
      _tapTimer?.cancel();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resetKeystoreToCurrentBiometrics();
      });
    }
  }

  Future<void> _resetKeystoreToCurrentBiometrics() async {
    debugPrint("🔐 [SUPER RESET] Step 1: Method entered.");
    if (!mounted) return;

    final TextEditingController passwordController = TextEditingController();
    bool isPasswordSubmitted = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text("🚨 Admin Device Sync"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "This will bind this physical device to your account and reset local biometrics.",
              ),
              const SizedBox(height: 16),
              TextField(
                controller: passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: "Admin Password"),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () {
                isPasswordSubmitted = true;
                Navigator.pop(context);
              },
              child: const Text(
                "Sync Device",
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        );
      },
    );

    if (!isPasswordSubmitted || passwordController.text.isEmpty) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Please scan fingerprint to generate new keys..."),
        backgroundColor: Colors.blueAccent,
        behavior: SnackBarBehavior.floating,
      ),
    );

    try {
      debugPrint("🔐 [SUPER RESET] Step 2: Calling native biometric prompt...");
      final String authResult = await _platform.invokeMethod(
        'showBiometricPrompt',
      );
      if (authResult != "SUCCESS") throw Exception("Biometric Auth Failed");

      debugPrint("🔐 [SUPER RESET] Step 3: Resetting local biometric keys...");
      final String localResetResult = await _platform.invokeMethod(
        'resetBiometricKey',
      );
      if (localResetResult != "SUCCESS")
        throw Exception("Local Keystore Reset Failed");

      debugPrint(
        "🔐 [SUPER RESET] Step 4: Generating silent device binding key...",
      );
      final String newPublicKey = await _platform.invokeMethod(
        'generateDeviceBindingKey',
      );
      if (newPublicKey.startsWith("Error")) throw Exception(newPublicKey);

      debugPrint("🔐 [SUPER RESET] Step 5: Syncing with Django backend...");
      final headers = await TokenHandles.getAuthHeaders();
      final url = Uri.parse("${BaseUrl.value}/user/student/device/bind/");
      final response = await http.post(
        url,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode({
          "public_key": newPublicKey,
          "admin_password": passwordController.text.trim(),
        }),
      );
      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "✅ ${data['message'] ?? 'Device synced successfully!'}",
            ),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        throw Exception(data['error'] ?? "Server rejected the key.");
      }
    } catch (e) {
      debugPrint("🔐 [SUPER RESET] ❌ Failed: $e");
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("❌ Sync Failed: $e"),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ─── SESSION ENTRY (UNCHANGED) ────────────────────────────────────────────

  Future<void> _onEnterSessionPressed(Map<String, dynamic> enrollment) async {
    if (!mounted) return;

    bool hasBiometrics = false;
    try {
      hasBiometrics = await _platform.invokeMethod('isBiometricAvailable');
    } catch (e) {
      hasBiometrics = false;
    }

    if (!hasBiometrics) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "No biometric hardware detected. Bypassing local check...",
          ),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
      _navigateToSession(enrollment);
      return;
    }

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Checking Security Status..."),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );

    bool keyInvalidated = false;

    try {
      debugPrint("🔒 [SESSION] Checking keystore key validity...");
      await _platform.invokeMethod('checkBiometricKey');
    } on PlatformException catch (e) {
      if (e.code == "KEY_INVALIDATED") {
        debugPrint("🔒 [SESSION] Key Invalidated (Biometrics changed).");
        keyInvalidated = true;
        await SecurityReporter.reportAnomaly(
          anomalyTypeInt: 5,
          source: "dashboard_biometric_key_invalidated",
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("❌ Security Check Error: ${e.message}"),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("❌ Unexpected Error: $e"),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (keyInvalidated && mounted) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.redAccent,
                  size: 28,
                ),
                SizedBox(width: 8),
                Text("Security Warning", style: TextStyle(fontSize: 20)),
              ],
            ),
            content: const Text(
              "Biometric settings on this device have been changed.\n\n"
              "Normally, this would block your access. Since this is a demo, you may proceed after verifying your fingerprint.",
              style: TextStyle(fontSize: 16),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text(
                  "OK, I Understand",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ],
          );
        },
      );
    }

    if (!mounted) return;

    try {
      debugPrint("🔒 [SESSION] Requesting biometric auth...");
      final String authResult = await _platform.invokeMethod(
        'showBiometricPrompt',
      );
      debugPrint("🔒 [SESSION]    Auth result → $authResult");

      if (authResult != "SUCCESS") {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("❌ Authentication failed or cancelled."),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("✅ Identity Verified!"),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("❌ Authentication failed: ${e.message}"),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("❌ Unexpected Biometric Error: $e"),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    _navigateToSession(enrollment);
  }

  Future<void> _navigateToSession(Map<String, dynamic> enrollment) async {
    final classroomId = enrollment["id"];
    final classroomName = enrollment["name"] ?? "Class";
    final classroomCode = enrollment["code"] ?? "N/A";

    if (mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AttendanceSessionPage(
            classroomId: classroomId,
            classroomName: classroomName,
            classroomCode: classroomCode,
          ),
        ),
      );
    }
    _fetchDashboardData(showLoading: false);
  }

  // ─── REST OF METHODS (UNCHANGED) ─────────────────────────────────────────

  Future<void> _syncFCMToken() async {
    try {
      final headers = await TokenHandles.getAuthHeaders();
      if (headers.isEmpty) return;
      String? fcmToken = await FirebaseMessaging.instance.getToken();
      if (fcmToken == null) return;
      final url = Uri.parse("${BaseUrl.value}/user/profile/update-fcm/");
      final response = await http.post(
        url,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode({"fcm_token": fcmToken}),
      );
      if (response.statusCode == 200) {
        debugPrint("✅ Student FCM Token synced successfully.");
      } else {
        debugPrint("⚠️ FCM sync failed: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("❌ Error syncing FCM Token: $e");
    }
  }

  Future<http.Response> _getWithAuth(String url) async {
    final headers = await TokenHandles.getAuthHeaders();
    return http.get(Uri.parse(url), headers: headers);
  }

  Future<void> _fetchDashboardData({bool showLoading = true}) async {
    if (showLoading) setState(() => isLoading = true);
    try {
      final profileRes = await _getWithAuth("${BaseUrl.value}/user/profile/");
      final enrollmentsRes = await _getWithAuth(
        "${BaseUrl.value}/user/student/enrollments/",
      );
      if (profileRes.statusCode == 200 && enrollmentsRes.statusCode == 200) {
        final parsedProfile = jsonDecode(profileRes.body);
        final parsedEnrollments = jsonDecode(enrollmentsRes.body);
        GlobalStudentProfile.setProfile(
          StudentProfile.fromJwtPayload(parsedProfile),
        );
        if (mounted) {
          setState(() {
            profile = parsedProfile;
            enrollments = parsedEnrollments;
          });
        }
        _syncFCMToken();
        for (var enrollment in parsedEnrollments) {
          _fetchSessionStatus(enrollment["id"]);
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "Failed to load data (Profile: ${profileRes.statusCode}, Enrollments: ${enrollmentsRes.statusCode})",
              ),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Error: $e")));
      }
    } finally {
      if (mounted && showLoading) setState(() => isLoading = false);
    }
  }

  Future<void> _fetchSessionStatus(int classroomId) async {
    try {
      final res = await _getWithAuth(
        "${BaseUrl.value}/session/session/status/$classroomId/",
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (mounted) {
          setState(() {
            sessionStatus[classroomId] = data["active"] ?? false;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _onEnrollMorePressed() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const StudentClassroomSearchPage(),
      ),
    );
    _fetchDashboardData(showLoading: false);
  }

  Future<void> _onClassCardTapped(Map<String, dynamic> classroom) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AttendanceRecordPage(
          classroomId: classroom['id'],
          classroomName: classroom['name'],
          classroomCode: classroom['code'],
        ),
      ),
    );
    _fetchDashboardData(showLoading: false);
  }

  Future<void> _onAbsenceProposalPressed() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ProposalSelectionPage()),
    );
    _fetchDashboardData(showLoading: false);
  }

  // ─── BUILD ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final sortedEnrollments = List<dynamic>.from(enrollments)
      ..sort((a, b) {
        final bool aActive = sessionStatus[a["id"]] ?? false;
        final bool bActive = sessionStatus[b["id"]] ?? false;
        if (aActive && !bActive) return -1;
        if (!aActive && bActive) return 1;
        return 0;
      });

    final activeCount = sessionStatus.values.where((v) => v == true).length;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F8),
      appBar: AppBar(
        title: const Text(
          "Dashboard",
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: Colors.white,
          ),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: _dark,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
            onPressed: _fetchDashboardData,
            tooltip: "Refresh",
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator(color: _accent))
          : RefreshIndicator(
              color: _accent,
              onRefresh: _fetchDashboardData,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  // ── Profile Header ──────────────────────────────────────
                  _ProfileHeader(
                    profile: profile,
                    enrollmentCount: enrollments.length,
                    activeCount: activeCount,
                    onSecretTap: _handleSecretTap,
                  ),

                  const SizedBox(height: 20),

                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ── Quick Actions ─────────────────────────────────
                        _SectionLabel(
                          icon: Icons.bolt_rounded,
                          label: "Quick Actions",
                        ),
                        const SizedBox(height: 10),
                        _AbsenceProposalTile(onTap: _onAbsenceProposalPressed),

                        const SizedBox(height: 24),

                        // ── Enrolled Classes ──────────────────────────────
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _SectionLabel(
                              icon: Icons.school_rounded,
                              label: "Enrolled Classes",
                            ),
                            _EnrollMoreButton(onTap: _onEnrollMorePressed),
                          ],
                        ),
                        const SizedBox(height: 10),

                        if (sortedEnrollments.isEmpty)
                          _EmptyState()
                        else
                          ...sortedEnrollments.map((enrollment) {
                            final classroomId = enrollment["id"];
                            final subject = enrollment["name"] ?? "Class";
                            final teacher =
                                enrollment["teacher_name"] ?? "Unknown";
                            final code = enrollment["code"] ?? "";
                            final isActive = sessionStatus[classroomId] == true;

                            return _ClassCard(
                              subject: subject,
                              teacher: teacher,
                              code: code,
                              isActive: isActive,
                              onCardTap: () => _onClassCardTapped(enrollment),
                              onEnterSession: () =>
                                  _onEnterSessionPressed(enrollment),
                            );
                          }).toList(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

// ─── Profile Header ───────────────────────────────────────────────────────────

class _ProfileHeader extends StatelessWidget {
  final Map<String, dynamic>? profile;
  final int enrollmentCount;
  final int activeCount;
  final VoidCallback onSecretTap;

  const _ProfileHeader({
    required this.profile,
    required this.enrollmentCount,
    required this.activeCount,
    required this.onSecretTap,
  });

  @override
  Widget build(BuildContext context) {
    final username = profile?['username']?.toString() ?? 'Student';
    final uid = profile?['uid']?.toString() ?? 'N/A';
    final branch = profile?['branch']?.toString() ?? 'N/A';
    final initials = username.isNotEmpty
        ? username.substring(0, 1).toUpperCase()
        : 'S';

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A2E),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(28),
          bottomRight: Radius.circular(28),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Avatar — secret tap target
              GestureDetector(
                onTap: onSecretTap,
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: const Color(0xFF4361EE),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withOpacity(0.2),
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      initials,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
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
                    Text(
                      username,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        _ProfileChip(icon: Icons.badge_outlined, label: uid),
                        const SizedBox(width: 8),
                        _ProfileChip(
                          icon: Icons.school_outlined,
                          label: branch,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          // Stats row
          Row(
            children: [
              _StatCard(
                value: "$enrollmentCount",
                label: "Classes",
                icon: Icons.class_rounded,
              ),
              const SizedBox(width: 12),
              _StatCard(
                value: "$activeCount",
                label: "Active Now",
                icon: Icons.radio_button_checked_rounded,
                highlight: activeCount > 0,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProfileChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _ProfileChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: Colors.white54),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Colors.white60),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final bool highlight;

  const _StatCard({
    required this.value,
    required this.label,
    required this.icon,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        decoration: BoxDecoration(
          color: highlight
              ? const Color(0xFF1DB954).withOpacity(0.15)
              : Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: highlight
                ? const Color(0xFF1DB954).withOpacity(0.4)
                : Colors.white.withOpacity(0.1),
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: highlight ? const Color(0xFF1DB954) : Colors.white54,
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: highlight ? const Color(0xFF1DB954) : Colors.white,
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: highlight
                        ? const Color(0xFF1DB954).withOpacity(0.8)
                        : Colors.white54,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Section Label ────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  const _SectionLabel({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: const Color(0xFF4361EE)),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A2E),
          ),
        ),
      ],
    );
  }
}

// ─── Absence Proposal Tile ────────────────────────────────────────────────────

class _AbsenceProposalTile extends StatelessWidget {
  final VoidCallback onTap;
  const _AbsenceProposalTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE8E8EE)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.description_outlined,
                color: Colors.orange.shade700,
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Absence Proposal",
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    "Submit or track absence requests",
                    style: TextStyle(fontSize: 12, color: Color(0xFF8A8A9A)),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: Colors.grey.shade400,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Enroll More Button ───────────────────────────────────────────────────────

class _EnrollMoreButton extends StatelessWidget {
  final VoidCallback onTap;
  const _EnrollMoreButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF4361EE).withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, size: 14, color: Color(0xFF4361EE)),
            SizedBox(width: 4),
            Text(
              "Enroll More",
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF4361EE),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Class Card ───────────────────────────────────────────────────────────────

class _ClassCard extends StatelessWidget {
  final String subject;
  final String teacher;
  final String code;
  final bool isActive;
  final VoidCallback onCardTap;
  final VoidCallback onEnterSession;

  const _ClassCard({
    required this.subject,
    required this.teacher,
    required this.code,
    required this.isActive,
    required this.onCardTap,
    required this.onEnterSession,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isActive
              ? const Color(0xFF1DB954).withOpacity(0.5)
              : const Color(0xFFE8E8EE),
          width: isActive ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isActive
                ? const Color(0xFF1DB954).withOpacity(0.08)
                : Colors.black.withOpacity(0.04),
            blurRadius: isActive ? 12 : 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left accent strip
              Container(
                width: 5,
                decoration: BoxDecoration(
                  color: isActive
                      ? const Color(0xFF1DB954)
                      : const Color(0xFF4361EE).withOpacity(0.3),
                ),
              ),
              // Card content
              Expanded(
                child: InkWell(
                  onTap: onCardTap,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    subject,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF1A1A2E),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.person_outline_rounded,
                                        size: 13,
                                        color: Colors.grey.shade500,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        teacher,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (code.isNotEmpty) ...[
                                    const SizedBox(height: 3),
                                    Row(
                                      children: [
                                        Icon(
                                          Icons.tag_rounded,
                                          size: 12,
                                          color: Colors.grey.shade400,
                                        ),
                                        const SizedBox(width: 3),
                                        Text(
                                          code,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey.shade400,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            // Status badge
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: isActive
                                    ? const Color(0xFF1DB954).withOpacity(0.1)
                                    : Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: isActive
                                          ? const Color(0xFF1DB954)
                                          : Colors.grey.shade400,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    isActive ? "Live" : "Inactive",
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: isActive
                                          ? const Color(0xFF1DB954)
                                          : Colors.grey.shade500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),

                        // Enter Session Button
                        if (isActive) ...[
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            height: 42,
                            child: ElevatedButton.icon(
                              onPressed: onEnterSession,
                              icon: const Icon(
                                Icons.fingerprint_rounded,
                                size: 18,
                              ),
                              label: const Text(
                                "Enter Attendance Session",
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF1DB954),
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Empty State ──────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE8E8EE)),
      ),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: const Color(0xFF4361EE).withOpacity(0.08),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.school_outlined,
              size: 30,
              color: Color(0xFF4361EE),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            "No classes yet",
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "Tap 'Enroll More' above to join your first class",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }
}
