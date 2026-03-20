import 'package:attendance_app/global_variable/student_profile.dart';
import 'package:attendance_app/student_app/attendance_session/new_token_passing.dart/fallback_version/fallback_qr_receiver.dart';
import 'package:attendance_app/student_app/attendance_session/new_token_passing.dart/fallback_version/fallback_scanner_transmitter.dart';
import 'package:flutter/material.dart';

class FallbackTokenTransferPage extends StatelessWidget {
  final String ownUid;
  final int classroomId;

  const FallbackTokenTransferPage({
    super.key,
    required this.ownUid,
    required this.classroomId,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Pass Token (Fallback)"),
        backgroundColor: Colors.orange, // Visual indicator for fallback mode
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ==========================================
            // INFO BANNER (Explicitly stating the mode)
            // ==========================================
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.shade300),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.orange,
                    size: 28,
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Fallback Mode Active",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.deepOrange,
                            fontSize: 16,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          "Plain Encrypted BLE Token Passing (Non-GATT).\nThis method does not use strict proximity timing.",
                          style: TextStyle(
                            color: Colors.deepOrange,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 50),

            // ==========================================
            // OPTION 1: THE SCANNER (Transmitter)
            // ==========================================
            _buildRoleCard(
              context: context,
              title: "Scan a Classmate",
              subtitle:
                  "Open the camera to scan a QR code and transmit your encrypted token.",
              icon: Icons.qr_code_scanner_rounded,
              color: Colors.blueAccent,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => FallbackScannerTransmitterPage(
                      ownUid:
                          GlobalStudentProfile.currentStudent?.uid ?? "unknown",
                      classroomId: classroomId,
                    ),
                  ),
                );
              },
            ),

            const SizedBox(height: 20),

            // ==========================================
            // OPTION 2: THE QR DISPLAY (Receiver)
            // ==========================================
            _buildRoleCard(
              context: context,
              title: "Show My QR Code",
              subtitle:
                  "Display your temporary ID for a classmate to scan and verify you.",
              icon: Icons.qr_code_2_rounded,
              color: Colors.teal,
              onTap: () {
                // Navigate to the Receiver Page (The one showing the QR)
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => FallbackQrReceiverPage(
                      ownUid:
                          GlobalStudentProfile.currentStudent?.uid ?? "unknown",
                      classroomId: classroomId,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Helper widget to build large, tapable role cards
  Widget _buildRoleCard({
    required BuildContext context,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24.0, horizontal: 16.0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 40, color: color),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}
