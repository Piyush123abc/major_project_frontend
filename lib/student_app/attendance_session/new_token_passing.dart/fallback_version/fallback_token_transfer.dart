import 'dart:convert';
import 'package:attendance_app/global_variable/base_url.dart';
import 'package:attendance_app/global_variable/student_profile.dart';
import 'package:attendance_app/global_variable/token_handles.dart';
import 'package:attendance_app/student_app/attendance_session/new_token_passing.dart/fallback_version/fallback_qr_receiver.dart';
import 'package:attendance_app/student_app/attendance_session/new_token_passing.dart/fallback_version/fallback_scanner_transmitter.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:location/location.dart' as loc; // ✅ Added Location package

class FallbackTokenTransferPage extends StatefulWidget {
  final String ownUid;
  final int classroomId;

  const FallbackTokenTransferPage({
    super.key,
    required this.ownUid,
    required this.classroomId,
  });

  @override
  State<FallbackTokenTransferPage> createState() =>
      _FallbackTokenTransferPageState();
}

class _FallbackTokenTransferPageState extends State<FallbackTokenTransferPage> {
  bool _isFetchingGPS = true;
  double? _distanceMeters;
  String? _gpsErrorMessage;

  // Set your classroom radius threshold here (e.g., 50 meters)
  final double _allowedRadius = 50.0;

  @override
  void initState() {
    super.initState();
    _fetchAndCalculateDistance();
  }

  Future<void> _fetchAndCalculateDistance() async {
    try {
      // 1. Fetch Teacher GPS from Backend
      final headers = await TokenHandles.getAuthHeaders();
      final url = Uri.parse(
        "${BaseUrl.value}/session/classroom/${widget.classroomId}/student/gps/",
      );

      final response = await http.get(url, headers: headers);

      if (response.statusCode != 200) {
        final errorData = jsonDecode(response.body);
        setState(() {
          _gpsErrorMessage =
              errorData['error'] ?? "Failed to fetch Teacher GPS.";
          _isFetchingGPS = false;
        });
        return;
      }

      final data = jsonDecode(response.body);
      final double teacherLat = data['latitude'];
      final double teacherLng = data['longitude'];

      // 2. Get Student's Current GPS (with 1-Click Turn On)
      loc.Location locationService = loc.Location();
      bool serviceEnabled = await locationService.serviceEnabled();

      if (!serviceEnabled) {
        // 👇 Triggers the native 1-Click popup
        serviceEnabled = await locationService.requestService();
        if (!serviceEnabled) {
          setState(() {
            _gpsErrorMessage = "GPS is required to check distance.";
            _isFetchingGPS = false;
          });
          return;
        }
      }

      // 3. Check and Request Permissions
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() {
            _gpsErrorMessage = "Location permission denied.";
            _isFetchingGPS = false;
          });
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _gpsErrorMessage = "Location permissions permanently denied.";
          _isFetchingGPS = false;
        });
        return;
      }

      // 4. Get Actual Position
      Position studentPosition = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // 5. Calculate Distance
      double distance = Geolocator.distanceBetween(
        teacherLat,
        teacherLng,
        studentPosition.latitude,
        studentPosition.longitude,
      );

      setState(() {
        _distanceMeters = distance;
        _isFetchingGPS = false;
      });
    } catch (e) {
      setState(() {
        _gpsErrorMessage = "Network error while checking location.";
        _isFetchingGPS = false;
      });
    }
  }

  // ==========================================
  // DISTANCE BANNER UI
  // ==========================================
  Widget _buildDistanceBanner() {
    if (_isFetchingGPS) {
      return _buildBannerContainer(
        color: Colors.blue,
        child: const Row(
          children: [
            SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text(
              "Checking distance to teacher...",
              style: TextStyle(color: Colors.blue),
            ),
          ],
        ),
      );
    }

    if (_gpsErrorMessage != null) {
      return _buildBannerContainer(
        color: Colors.grey,
        child: Row(
          children: [
            const Icon(Icons.location_disabled, color: Colors.grey),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _gpsErrorMessage!,
                style: const TextStyle(color: Colors.black87),
              ),
            ),
          ],
        ),
      );
    }

    if (_distanceMeters != null) {
      bool isTooFar = _distanceMeters! > _allowedRadius;

      return _buildBannerContainer(
        color: isTooFar ? Colors.red : Colors.green,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isTooFar ? Icons.dangerous_rounded : Icons.check_circle_rounded,
              color: isTooFar ? Colors.red : Colors.green,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isTooFar ? "Too Far from Class!" : "You are in Range",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isTooFar
                          ? Colors.red.shade700
                          : Colors.green.shade700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Distance: ${_distanceMeters!.toStringAsFixed(1)} meters",
                    style: TextStyle(
                      color: isTooFar
                          ? Colors.red.shade700
                          : Colors.green.shade700,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  /// Helper to dry up banner styling
  Widget _buildBannerContainer({
    required MaterialColor color,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.shade300),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Pass Token (Fallback)"),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Distance & GPS Status Banner
            _buildDistanceBanner(),

            const SizedBox(height: 30),

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
                      classroomId: widget.classroomId,
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
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => FallbackQrReceiverPage(
                      ownUid:
                          GlobalStudentProfile.currentStudent?.uid ?? "unknown",
                      classroomId: widget.classroomId,
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
