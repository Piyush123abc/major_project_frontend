import 'dart:convert';
import 'package:attendance_app/student_app/attendance_session/new_token_passing.dart/fallback_version/fallback_qr_receiver.dart';
import 'package:attendance_app/teacher_app/attendance_session/GetExceptionList.dart';
import 'package:attendance_app/teacher_app/attendance_session/MasterNodesManagerPage.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../global_variable/base_url.dart';
import '../../global_variable/token_handles.dart';
import '../../global_variable/session_data_manager.dart';
import 'ReceiveTokenPage.dart';

class AttendanceSessionPage extends StatefulWidget {
  final int classroomId;

  const AttendanceSessionPage({super.key, required this.classroomId});

  @override
  State<AttendanceSessionPage> createState() => _AttendanceSessionPageState();
}

class _AttendanceSessionPageState extends State<AttendanceSessionPage> {
  bool _loading = true;
  String? _errorMessage;

  // Toggle state for Secure BLE Mode vs Fallback Mode
  bool _isSecureMode = true;

  @override
  void initState() {
    super.initState();
    _fetchSessionCredentials();
  }

  // ==========================================
  // FETCH SESSION CREDENTIALS
  // ==========================================
  Future<void> _fetchSessionCredentials() async {
    String classIdStr = widget.classroomId.toString();

    // Skip if already loaded
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
          "${BaseUrl.value}/session/teacher/classroom/${widget.classroomId}/credentials/",
        ),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        SessionDataManager.instance.saveCredentials(
          classroomId: classIdStr,
          kClass: data['k_class'],
          sessionSeed: data['session_seed'] ?? "",
          // This now captures the EXACT UID (e.g., 'teacher1') from Django
          nodeId: data['node_id']?.toString() ?? "unknown",
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
  // NAVIGATION METHODS
  // ==========================================
  void _goToExceptionList(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ExceptionListPage(classroomId: widget.classroomId),
      ),
    );
  }

  void _goToMasterNodes(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            MasterNodesManagerPage(classroomId: widget.classroomId),
      ),
    );
  }

  // ==========================================
  // END SESSION LOGIC
  // ==========================================
  Future<void> _endSession(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Confirm End Session"),
        content: const Text("Are you sure you want to finalize attendance?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Yes"),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    Future<http.Response?> tryRequest() async {
      try {
        return await http.post(
          Uri.parse(
            "${BaseUrl.value}/session/teacher/classroom/${widget.classroomId}/finalize/",
          ),
          headers: await TokenHandles.getAuthHeaders(),
        );
      } catch (e) {
        return null;
      }
    }

    var response = await tryRequest();

    if (response != null && response.statusCode == 401) {
      final refreshed = await TokenHandles.refreshAccessToken();
      if (refreshed) {
        response = await tryRequest();
      }
    }

    if (response == null) {
      _showResultDialog(context, "❌ Network error");
      return;
    }

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final summary = data["summary"];

      SessionDataManager.instance.clearSession(widget.classroomId.toString());

      _showResultDialog(
        context,
        "✅ ${data["message"]}\n\n"
        "📊 Summary:\n"
        "- Total: ${summary["total_students"]}\n"
        "- Present: ${summary["present"]}\n"
        "- Absent: ${summary["absent"]}",
        success: true,
      );
    } else {
      _showResultDialog(context, "⚠️ Failed: ${response.body}");
    }
  }

  void _showResultDialog(
    BuildContext context,
    String message, {
    bool success = false,
  }) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Finalize Result"),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              if (success) {
                Navigator.pop(context);
              }
            },
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // UI BUILDER
  // ==========================================
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
      appBar: AppBar(title: const Text("Attendance Session")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              "📝 Classroom ID: ${widget.classroomId}",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 30),

            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: SwitchListTile(
                title: const Text("Secure BLE Verification"),
                subtitle: Text(
                  _isSecureMode
                      ? "Ready: High Security Mode"
                      : "Fallback Mode (Basic Token Passing)",
                  style: TextStyle(
                    color: _isSecureMode ? Colors.green : Colors.orange,
                  ),
                ),
                value: _isSecureMode,
                activeColor: Colors.green,
                onChanged: (bool newValue) {
                  setState(() {
                    _isSecureMode = newValue;
                  });
                },
              ),
            ),
            const SizedBox(height: 30),

            ElevatedButton.icon(
              onPressed: () => _goToExceptionList(context),
              icon: const Icon(Icons.error_outline),
              label: const Text("Exception List"),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            const SizedBox(height: 16),

            // THE MAGIC FIX IS IN THIS BUTTON LOGIC 👇
            ElevatedButton.icon(
              onPressed: () {
                // Pull the EXACT identity we got from Django
                final creds = SessionDataManager.instance.getCredentials(
                  widget.classroomId.toString(),
                );
                final actualUid = creds?.nodeId ?? "unknown";

                if (_isSecureMode) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          ReceiveTokenPage(classroomId: widget.classroomId),
                    ),
                  );
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => FallbackQrReceiverPage(
                        ownUid:
                            actualUid, // Guaranteed to be 'teacher1' (or whatever is in your DB)
                        classroomId: widget.classroomId,
                      ),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.qr_code),
              label: Text(
                _isSecureMode
                    ? "Receive Token (Secure)"
                    : "Receive Token (Fallback)",
              ),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: _isSecureMode ? Colors.blue : Colors.orange,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 16),

            ElevatedButton.icon(
              onPressed: () => _goToMasterNodes(context),
              icon: const Icon(Icons.hub),
              label: const Text("Manage Master Nodes"),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            const SizedBox(height: 40),

            ElevatedButton.icon(
              onPressed: () => _endSession(context),
              icon: const Icon(Icons.stop_circle),
              label: const Text("End Session"),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
