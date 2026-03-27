import 'dart:convert';
import 'package:attendance_app/global_variable/base_url.dart';
import 'package:attendance_app/global_variable/token_handles.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class AttendanceRecordPage extends StatefulWidget {
  final int classroomId;
  final String classroomName;
  final String classroomCode;

  const AttendanceRecordPage({
    super.key,
    required this.classroomId,
    required this.classroomName,
    required this.classroomCode,
  });

  @override
  State<AttendanceRecordPage> createState() => _AttendanceRecordPageState();
}

class _AttendanceRecordPageState extends State<AttendanceRecordPage> {
  bool _isLoading = true;
  String _errorMessage = "";
  List<dynamic> _records = [];

  int totalClasses = 0;
  int presentCount = 0;
  int absentCount = 0;
  int pendingCount = 0;

  double attendancePercentage = 0.0;
  double maxPotentialPercentage = 0.0;
  int classesNeededFor75 = 0;

  @override
  void initState() {
    super.initState();
    _fetchAttendanceRecords();
  }

  Future<void> _fetchAttendanceRecords() async {
    setState(() {
      _isLoading = true;
      _errorMessage = "";
    });

    final url =
        "${BaseUrl.value}/user/student/attendance/?classroom_id=${widget.classroomId}";

    try {
      final headers = await TokenHandles.getAuthHeaders();
      final response = await http.get(Uri.parse(url), headers: headers);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _records = data;

        totalClasses = _records.length;
        presentCount = _records.where((r) => r['status'] == "PRESENT").length;
        absentCount = _records.where((r) => r['status'] == "ABSENT").length;
        pendingCount = _records.where((r) => r['status'] == "PENDING").length;

        attendancePercentage = totalClasses > 0
            ? (presentCount / totalClasses) * 100
            : 0.0;

        maxPotentialPercentage = totalClasses > 0
            ? ((presentCount + pendingCount) / totalClasses) * 100
            : 0.0;

        if (attendancePercentage < 75.0 && totalClasses > 0) {
          classesNeededFor75 = (3 * totalClasses) - (4 * presentCount);
          if (classesNeededFor75 < 0) classesNeededFor75 = 0;
        } else {
          classesNeededFor75 = 0;
        }

        setState(() {
          _isLoading = false;
        });
      } else {
        final data = jsonDecode(response.body);
        setState(() {
          _errorMessage =
              data['detail'] ??
              data['message'] ??
              'Failed to fetch attendance records';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = "Something went wrong: $e";
        _isLoading = false;
      });
    }
  }

  // --- UI Components ---

  Widget _buildOverviewCard() {
    final bool isSafe = attendancePercentage >= 75.0;
    final Color ringColor = isSafe ? Colors.green : Colors.redAccent;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.1),
            spreadRadius: 2,
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // FIX: Wrapped the text Column in Expanded to prevent horizontal overflow
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Overall Attendance",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "${attendancePercentage.toStringAsFixed(1)}%",
                      style: TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.bold,
                        color: ringColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16), // Buffer space
              SizedBox(
                height: 80,
                width: 80,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CircularProgressIndicator(
                      value: totalClasses > 0 ? presentCount / totalClasses : 0,
                      strokeWidth: 8,
                      backgroundColor: Colors.grey.shade200,
                      color: ringColor,
                    ),
                    Center(
                      child: Icon(
                        isSafe ? Icons.check_circle : Icons.warning_rounded,
                        color: ringColor,
                        size: 32,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // --- 75% Target Alert ---
          if (!isSafe && classesNeededFor75 > 0)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.trending_up, color: Colors.red.shade700),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      "You need to attend $classesNeededFor75 more consecutive class${classesNeededFor75 > 1 ? 'es' : ''} to reach 75%.",
                      style: TextStyle(
                        color: Colors.red.shade800,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else if (isSafe && totalClasses > 0)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.green.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.verified, color: Colors.green.shade700),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      "Great job! You are maintaining above 75% attendance.",
                      style: TextStyle(
                        color: Colors.green.shade800,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 20),

          // FIX: Changed to a 2x2 grid instead of a 4-item row
          Column(
            children: [
              Row(
                children: [
                  _statTile("Total", totalClasses.toString(), Colors.blue),
                  const SizedBox(width: 8),
                  _statTile("Present", presentCount.toString(), Colors.green),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _statTile("Absent", absentCount.toString(), Colors.red),
                  const SizedBox(width: 8),
                  _statTile("Pending", pendingCount.toString(), Colors.orange),
                ],
              ),
            ],
          ),

          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),

          Text(
            "Max Potential (Including Pending): ${maxPotentialPercentage.toStringAsFixed(1)}%",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statTile(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 20,
                color: color,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: color.withOpacity(0.8),
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordCard(Map<String, dynamic> record) {
    final date = record['date'] ?? 'Unknown Date';
    final status = record['status'] ?? 'UNKNOWN';
    final timestamp = record['timestamp'] ?? 'No time recorded';

    Color statusColor;
    IconData statusIcon;

    switch (status) {
      case "PRESENT":
        statusColor = Colors.green;
        statusIcon = Icons.check_circle;
        break;
      case "ABSENT":
        statusColor = Colors.red;
        statusIcon = Icons.cancel;
        break;
      case "PENDING":
        statusColor = Colors.orange;
        statusIcon = Icons.hourglass_empty;
        break;
      default:
        statusColor = Colors.grey;
        statusIcon = Icons.help_outline;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(statusIcon, color: statusColor, size: 24),
        ),
        title: Text(
          date,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4.0),
          child: Row(
            children: [
              Icon(Icons.access_time, size: 14, color: Colors.grey.shade600),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  timestamp,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            status,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: statusColor,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        // FIX: Added Flexible/Overflow handling to the AppBar title as well
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.classroomName,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              widget.classroomCode,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage.isNotEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _errorMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.red, fontSize: 16),
                    ),
                  ],
                ),
              ),
            )
          : _records.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.inbox_outlined,
                    size: 64,
                    color: Colors.grey.shade400,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    "No attendance records yet.",
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _fetchAttendanceRecords,
              child: ListView.builder(
                padding: const EdgeInsets.all(16.0),
                itemCount: _records.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 24.0),
                      child: _buildOverviewCard(),
                    );
                  }
                  return _buildRecordCard(_records[index - 1]);
                },
              ),
            ),
    );
  }
}
