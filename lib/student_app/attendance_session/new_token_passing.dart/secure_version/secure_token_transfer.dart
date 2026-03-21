import 'package:attendance_app/global_variable/student_profile.dart';
import 'package:attendance_app/student_app/attendance_session/new_token_passing.dart/secure_version/secure_qr_server.dart';
import 'package:attendance_app/student_app/attendance_session/new_token_passing.dart/secure_version/secure_scanner_transmitter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Make sure to import your host page here!
// import 'package:attendance_app/student_app/attendance_session/new_token_passing.dart/secure_version/secure_proximity_host.dart';

class SecurePeerGatewayPage extends StatelessWidget {
  const SecurePeerGatewayPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A), // Deep black for battery saving
      appBar: AppBar(
        title: const Text(
          "SECURE PEER SYNC",
          style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.5),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              "Select your role to complete the attendance handshake.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.white54,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 32),

            // ---------------------------------------------------------
            // OPTION 1: THE SERVER (Show QR / Host GATT)
            // ---------------------------------------------------------
            Expanded(
              child: _AnimatedActionCard(
                title: "HOST CONNECTION",
                subtitle:
                    "Show your QR code and broadcast a secure signal for verification.",
                icon: Icons.qr_code_2_rounded,
                accentColor: Colors.tealAccent,
                onTap: () {
                  HapticFeedback.heavyImpact();

                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          const SecureProximityHostPage(classroomId: 123),
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 24),

            // ---------------------------------------------------------
            // OPTION 2: THE CLIENT (Scanner / Connect to GATT)
            // ---------------------------------------------------------
            Expanded(
              child: _AnimatedActionCard(
                title: "SCAN CLASSMATE",
                subtitle:
                    "Scan a classmate's QR to verify proximity and transfer token.",
                icon: Icons.document_scanner_rounded,
                accentColor: Colors.indigoAccent,
                onTap: () {
                  HapticFeedback.heavyImpact();

                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => SecureProximityScannerPage(
                        // Dynamically pull the scanner's real UID
                        ownUid:
                            GlobalStudentProfile.currentStudent?.uid ??
                            "UNKNOWN_UID",
                        // TODO: Pass your dynamic classroom ID here when ready
                        classroomId: 123,
                      ),
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 16), // Bottom padding
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------
// CUSTOM ANIMATED WIDGET FOR PREMIUM FEEL
// ---------------------------------------------------------
class _AnimatedActionCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accentColor;
  final VoidCallback onTap;

  const _AnimatedActionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
    required this.onTap,
  });

  @override
  State<_AnimatedActionCard> createState() => _AnimatedActionCardState();
}

class _AnimatedActionCardState extends State<_AnimatedActionCard> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        setState(() => _isPressed = true);
        HapticFeedback.lightImpact();
      },
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onTap();
      },
      onTapCancel: () {
        setState(() => _isPressed = false);
      },
      child: AnimatedScale(
        scale: _isPressed ? 0.96 : 1.0, // Shrinks slightly when pressed
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeInOut,
        child: Container(
          decoration: BoxDecoration(
            color: widget.accentColor.withOpacity(0.05),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: widget.accentColor.withOpacity(_isPressed ? 0.8 : 0.3),
              width: 2,
            ),
            boxShadow: [
              // Subtle neon glow effect
              BoxShadow(
                color: widget.accentColor.withOpacity(_isPressed ? 0.2 : 0.05),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: widget.accentColor.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(widget.icon, size: 48, color: widget.accentColor),
                ),
                const SizedBox(height: 24),
                Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5,
                    color: widget.accentColor,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  widget.subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white70,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
