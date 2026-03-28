import 'dart:async';
import 'dart:convert';
import 'package:attendance_app/global_variable/student_profile.dart';
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

  @override
  void initState() {
    super.initState();
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

  // ─── BACKDOOR ────────────────────────────────────────────────────────────────

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
          content: Text("Tap $tapsLeft more time(s) to reset Keystore."),
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
    debugPrint("🔐 [RESET] Step 1: Method entered.");
    if (!mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Please scan fingerprint to verify identity..."),
        backgroundColor: Colors.blueAccent,
        behavior: SnackBarBehavior.floating,
      ),
    );

    try {
      debugPrint("🔐 [RESET] Step 2: Calling native biometric prompt...");
      final String authResult = await _platform.invokeMethod(
        'showBiometricPrompt',
      );
      debugPrint("🔐 [RESET]    Native result → $authResult");

      if (authResult != "SUCCESS") {
        if (!mounted) return;
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("❌ Authentication failed."),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      debugPrint(
        "🔐 [RESET] Step 3: Resetting biometric-bound key via native...",
      );
      final String keyResult = await _platform.invokeMethod(
        'resetBiometricKey',
      );
      debugPrint("🔐 [RESET]    Key reset result → $keyResult");
      debugPrint("🔐 [RESET] ✅ Done. Key is now bound to current biometrics.");

      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "✅ Keystore successfully locked to current biometrics.",
          ),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 4),
        ),
      );
    } on PlatformException catch (e) {
      debugPrint("🔐 [RESET] ❌ PlatformException: ${e.code} - ${e.message}");
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("❌ Failed: ${e.message}"),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e, stack) {
      debugPrint("🔐 [RESET] ❌ Unexpected: $e\n$stack");
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("❌ Keystore reset failed: $e"),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ─── SESSION ENTRY ────────────────────────────────────────────────────────────

  Future<void> _onEnterSessionPressed(Map<String, dynamic> enrollment) async {
    if (!mounted) return;

    // ─── STEP 0: CHECK IF DEVICE HAS BIOMETRICS ───────────────────────────
    bool hasBiometrics = false;
    try {
      hasBiometrics = await _platform.invokeMethod('isBiometricAvailable');
    } catch (e) {
      hasBiometrics = false;
    }

    // IF NO HARDWARE -> SMOOTH PASS DIRECTLY TO SESSION
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
      return; // Stop here, skip all security checks
    }
    // ───────────────────────────────────────────────────────────────────────

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Checking Security Status..."),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );

    bool keyInvalidated = false;

    // STEP 1: Check Keystore Validity
    try {
      debugPrint("🔒 [SESSION] Checking keystore key validity...");
      await _platform.invokeMethod('checkBiometricKey');
    } on PlatformException catch (e) {
      if (e.code == "KEY_INVALIDATED") {
        debugPrint("🔒 [SESSION] Key Invalidated (Biometrics changed).");
        keyInvalidated = true;
      } else {
        // Stop entirely if there is a different hardware error (like KEY_MISSING)
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

    // STEP 2: Show Warning Dialog if Fingerprints Changed
    if (keyInvalidated && mounted) {
      await showDialog(
        context: context,
        barrierDismissible: false, // Forces user to tap OK to proceed
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

    // STEP 3: Always Request Biometric Auth (Even if key was invalid)
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
        return; // Block Entry
      }

      // Identity Verified Successfully
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
      return; // Block Entry
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("❌ Unexpected Biometric Error: $e"),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return; // Block Entry
    }

    // STEP 4: Navigate to Session Page
    _navigateToSession(enrollment);
  }

  // Helper method extracted to avoid repeating navigation code
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

  // ─── REST OF METHODS ─────────────────────────────────────────────────────────

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

  // ─── BUILD ────────────────────────────────────────────────────────────────────

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

    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text(
          "Student Dashboard",
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.blueAccent),
            onPressed: _fetchDashboardData,
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _fetchDashboardData,
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                children: [
                  if (profile != null)
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.blue.shade700, Colors.blue.shade400],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.blue.withOpacity(0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20.0),
                        child: Row(
                          children: [
                            GestureDetector(
                              onTap: _handleSecretTap,
                              child: CircleAvatar(
                                radius: 30,
                                backgroundColor: Colors.white,
                                child: Text(
                                  profile!['username']
                                          ?.toString()
                                          .substring(0, 1)
                                          .toUpperCase() ??
                                      "U",
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue.shade700,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "${profile!['username'] ?? 'Student'}",
                                    style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "UID: ${profile!['uid'] ?? 'N/A'}",
                                    style: TextStyle(
                                      color: Colors.blue.shade100,
                                      fontSize: 14,
                                    ),
                                  ),
                                  Text(
                                    "Branch: ${profile!['branch'] ?? 'N/A'}",
                                    style: TextStyle(
                                      color: Colors.blue.shade100,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  const SizedBox(height: 16),

                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: _onAbsenceProposalPressed,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16.0,
                          vertical: 18.0,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.description_outlined,
                                  color: Colors.orange.shade700,
                                ),
                                const SizedBox(width: 12),
                                const Text(
                                  "Absence Proposal",
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const Icon(
                              Icons.arrow_forward_ios,
                              size: 16,
                              color: Colors.grey,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "Enrolled Classes",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _onEnrollMorePressed,
                        icon: const Icon(Icons.add_circle),
                        label: const Text("Enroll More"),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.blue.shade700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  if (sortedEnrollments.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: Text(
                          "No enrollments found.\nTap 'Enroll More' to get started.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey, fontSize: 16),
                        ),
                      ),
                    ),

                  ...sortedEnrollments.map((enrollment) {
                    final classroomId = enrollment["id"];
                    final subject = enrollment["name"] ?? "Class";
                    final teacher = enrollment["teacher_name"] ?? "Unknown";
                    final isActive = sessionStatus[classroomId] == true;

                    return Card(
                      margin: const EdgeInsets.only(bottom: 16),
                      elevation: isActive ? 4 : 1,
                      shadowColor: isActive
                          ? Colors.green.withOpacity(0.4)
                          : null,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: isActive
                            ? const BorderSide(color: Colors.green, width: 1.5)
                            : BorderSide(color: Colors.grey.shade200),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => _onClassCardTapped(enrollment),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Text(
                                      subject,
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isActive
                                          ? Colors.green.shade50
                                          : Colors.grey.shade100,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(
                                      isActive ? "Active Session" : "Inactive",
                                      style: TextStyle(
                                        color: isActive
                                            ? Colors.green.shade700
                                            : Colors.grey.shade600,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Icon(
                                    Icons.person_outline,
                                    size: 16,
                                    color: Colors.grey.shade600,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    teacher,
                                    style: TextStyle(
                                      color: Colors.grey.shade700,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                              if (isActive) ...[
                                const SizedBox(height: 16),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: () =>
                                        _onEnterSessionPressed(enrollment),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.green,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                    child: const Text(
                                      "Enter Attendance Session",
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ],
              ),
            ),
    );
  }
}
