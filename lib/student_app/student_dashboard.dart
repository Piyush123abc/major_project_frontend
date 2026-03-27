import 'dart:convert';
import 'package:attendance_app/global_variable/student_profile.dart';
import 'package:attendance_app/student_app/absence_proposal/ProposalSelectionPage.dart';
import 'package:attendance_app/student_app/absence_proposal/absence_proposal_dashboard.dart';
import 'package:attendance_app/student_app/attendance_records/attendance_record_list.dart';
import 'package:attendance_app/student_app/attendance_session/attendance_session_dasboard.dart';
import 'package:attendance_app/student_app/classroom_list/classroom_list.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../global_variable/base_url.dart';
import '../global_variable/token_handles.dart';

class StudentDashboardPage extends StatefulWidget {
  const StudentDashboardPage({super.key});

  @override
  State<StudentDashboardPage> createState() => _StudentDashboardPageState();
}

class _StudentDashboardPageState extends State<StudentDashboardPage> {
  Map<String, dynamic>? profile;
  List<dynamic> enrollments = [];
  Map<int, bool> sessionStatus = {}; // cache classroom session status
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchDashboardData();

    // Catch token changes that happen while the app is open
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
      _syncFCMToken();
    });
  }

  // --- Sync FCM Token to Backend ---
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

  // --- HTTP GET with Authorization ---
  Future<http.Response> _getWithAuth(String url) async {
    final headers = await TokenHandles.getAuthHeaders();
    return http.get(Uri.parse(url), headers: headers);
  }

  // --- Fetch Profile and Enrollments ---
  // Added a showLoading parameter so we can refresh silently in the background
  // when navigating back from a session, without blanking the screen.
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

        // Store globally
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

        // fetch session status for each classroom
        for (var enrollment in parsedEnrollments) {
          final classroomId = enrollment["id"];
          _fetchSessionStatus(classroomId);
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

  // --- Fetch Classroom Session Status ---
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

  // --- Navigation Functions (Updated to await and refresh) ---
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

  Future<void> _onEnterSessionPressed(Map<String, dynamic> enrollment) async {
    final classroomId = enrollment["id"];
    final classroomName = enrollment["name"] ?? "Class";
    final classroomCode = enrollment["code"] ?? "N/A";

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
    // Refresh silently when returning so stale "active" sessions disappear
    _fetchDashboardData(showLoading: false);
  }

  Future<void> _onAbsenceProposalPressed() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ProposalSelectionPage()),
    );
    _fetchDashboardData(showLoading: false);
  }

  @override
  Widget build(BuildContext context) {
    // Sort enrollments: Active sessions at the top
    final sortedEnrollments = List<dynamic>.from(enrollments)
      ..sort((a, b) {
        final bool aActive = sessionStatus[a["id"]] ?? false;
        final bool bActive = sessionStatus[b["id"]] ?? false;
        if (aActive && !bActive) return -1;
        if (!aActive && bActive) return 1;
        return 0;
      });

    return Scaffold(
      backgroundColor:
          Colors.grey[50], // Slightly lighter background for contrast
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
                  // --- Modern Profile Section ---
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
                            CircleAvatar(
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

                  // --- Absence Proposal Button ---
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

                  // --- Enrollments Section Header ---
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

                  // --- Classroom Cards ---
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
                        // Highlight active classes with a green border
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
                                  // Active Status Badge
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
