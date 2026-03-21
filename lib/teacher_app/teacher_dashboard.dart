// lib/teacher_app/teacher_dashboard.dart
import 'dart:convert';
import 'package:attendance_app/teacher_app/absence_proposals/teacher_pending_queue.dart';
import 'package:attendance_app/teacher_app/add_classroom_page.dart';
import 'package:attendance_app/teacher_app/attendance_session/AttendanceSessionPage.dart';
import 'package:firebase_messaging/firebase_messaging.dart'; // ✅ Added
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../global_variable/base_url.dart';
import '../global_variable/token_handles.dart';

class TeacherDashboard extends StatefulWidget {
  const TeacherDashboard({super.key});

  @override
  State<TeacherDashboard> createState() => _TeacherDashboardState();
}

class _TeacherDashboardState extends State<TeacherDashboard> {
  Map<String, dynamic>? _profile;
  List<dynamic> _classrooms = [];
  bool _isLoading = true;
  String _statusMessage = "";
  Map<int, bool> _activeSessions = {};

  @override
  void initState() {
    super.initState();
    _fetchProfileAndClassrooms();
  }

  // --- NEW: Sync Teacher FCM Token to Backend ---
  Future<void> _syncFCMToken() async {
    try {
      final headers = await TokenHandles.getAuthHeaders();
      if (headers.isEmpty) return;

      // Get the Firebase Token for this device
      String? fcmToken = await FirebaseMessaging.instance.getToken();
      if (fcmToken == null) return;

      // URL: base_url/user/profile/update-fcm/
      final url = Uri.parse("${BaseUrl.value}/user/profile/update-fcm/");

      final response = await http.post(
        url,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode({"fcm_token": fcmToken}),
      );

      if (response.statusCode == 200) {
        print("✅ Teacher FCM Token synced successfully.");
      } else {
        print("⚠️ Teacher FCM sync failed: ${response.statusCode}");
      }
    } catch (e) {
      print("❌ Error syncing Teacher FCM Token: $e");
    }
  }

  Future<void> _fetchProfileAndClassrooms() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _statusMessage = "";
    });

    try {
      final profileResponse = await http.get(
        Uri.parse("${BaseUrl.value}/user/profile/"),
        headers: await TokenHandles.getAuthHeaders(),
      );

      if (profileResponse.statusCode == 200) {
        _profile = jsonDecode(profileResponse.body);

        // ✅ Trigger FCM Sync once profile is confirmed
        _syncFCMToken();
      } else {
        setState(() {
          _statusMessage =
              "❌ Failed to load profile: ${profileResponse.statusCode}";
        });
      }

      final classResponse = await http.get(
        Uri.parse("${BaseUrl.value}/user/teacher/classrooms/"),
        headers: await TokenHandles.getAuthHeaders(),
      );

      if (classResponse.statusCode == 200) {
        _classrooms = jsonDecode(classResponse.body);
        for (var classroom in _classrooms) {
          await _fetchSessionStatus(classroom['id']);
        }
      } else {
        setState(() {
          _statusMessage =
              "❌ Failed to load classrooms: ${classResponse.statusCode}";
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = "❌ Error: $e";
      });
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _fetchSessionStatus(int classroomId) async {
    try {
      final response = await http.get(
        Uri.parse("${BaseUrl.value}/session/session/status/$classroomId/"),
        headers: await TokenHandles.getAuthHeaders(),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (mounted) {
          setState(() {
            _activeSessions[classroomId] = data['active'] ?? false;
          });
        }
      } else {
        _activeSessions[classroomId] = false;
      }
    } catch (_) {
      _activeSessions[classroomId] = false;
    }
  }

  Future<void> _startOrEnterAttendance(int classroomId) async {
    bool? isActive = _activeSessions[classroomId];

    if (isActive == true) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AttendanceSessionPage(classroomId: classroomId),
        ),
      );
      _fetchProfileAndClassrooms();
      return;
    }

    setState(() {
      _statusMessage = "⏳ Starting attendance...";
    });

    try {
      final response = await http.post(
        Uri.parse(
          "${BaseUrl.value}/session/teacher/classroom/$classroomId/start/",
        ),
        headers: await TokenHandles.getAuthHeaders(),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _statusMessage = "✅ ${data['message']}";
          _activeSessions[classroomId] = true;
        });

        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                AttendanceSessionPage(classroomId: classroomId),
          ),
        );
        _fetchProfileAndClassrooms();
      } else {
        setState(() {
          _statusMessage = "❌ Failed: ${response.statusCode}";
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = "❌ Error: $e";
      });
    }
  }

  void _goToAddClassroom() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const AddClassroomPage()),
    );

    if (result == true) {
      _fetchProfileAndClassrooms();
    }
  }

  void _goToPendingProposals() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const PendingProposalsPage()),
    );
  }

  Widget _buildProfileCard() {
    if (_profile == null) return const SizedBox();
    return Card(
      elevation: 3,
      margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(15.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "👤 ${_profile!['username'] ?? 'Teacher'}",
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 5),
            Text("UID: ${_profile!['uid'] ?? ''}"),
            Text("Department: ${_profile!['department'] ?? ''}"),
          ],
        ),
      ),
    );
  }

  Widget _buildClassroomCard(dynamic classroom) {
    final classroomId = classroom['id'];
    final bool isActive = _activeSessions[classroomId] ?? false;

    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: Text(
          "${classroom['code']} - ${classroom['name']}",
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4.0),
          child: Text(
            "Created: ${classroom['created_at']?.substring(0, 10) ?? ''}\nStatus: ${isActive ? 'Session Active' : 'No Session'}",
            style: TextStyle(color: isActive ? Colors.green : Colors.grey[600]),
          ),
        ),
        trailing: ElevatedButton(
          onPressed: () => _startOrEnterAttendance(classroomId),
          style: ElevatedButton.styleFrom(
            backgroundColor: isActive ? Colors.green : Colors.deepPurple,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(isActive ? "Enter" : "Start"),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Teacher Dashboard"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchProfileAndClassrooms,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _fetchProfileAndClassrooms,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  // Approval Queue Button
                  SizedBox(
                    width: double.infinity,
                    height: 55,
                    child: ElevatedButton.icon(
                      onPressed: _goToPendingProposals,
                      icon: const Icon(Icons.pending_actions),
                      label: const Text(
                        "Approval Queue",
                        style: TextStyle(fontSize: 18),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange[800],
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildProfileCard(),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    child: Text(
                      "Your Classrooms",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  ..._classrooms.map((c) => _buildClassroomCard(c)).toList(),
                  if (_classrooms.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Text("No classrooms created yet."),
                      ),
                    ),
                  if (_statusMessage.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(10.0),
                      child: Text(
                        _statusMessage,
                        style: const TextStyle(color: Colors.red),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  const SizedBox(height: 80),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _goToAddClassroom,
        label: const Text("Add Classroom"),
        icon: const Icon(Icons.add),
      ),
    );
  }
}
