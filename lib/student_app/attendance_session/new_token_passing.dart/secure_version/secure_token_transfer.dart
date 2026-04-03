import 'dart:async'; // <-- ADDED for StreamSubscription
import 'package:firebase_messaging/firebase_messaging.dart'; // <-- ADDED for FCM
import 'package:attendance_app/global_variable/student_profile.dart';
import 'package:attendance_app/student_app/attendance_session/new_token_passing.dart/secure_version/secure_qr_server.dart';
import 'package:attendance_app/student_app/attendance_session/new_token_passing.dart/secure_version/secure_scanner_transmitter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// CHANGED: Converted to StatefulWidget to hold the FCM Listener state
class SecurePeerGatewayPage extends StatefulWidget {
  final int classroomId;

  const SecurePeerGatewayPage({super.key, required this.classroomId});

  @override
  State<SecurePeerGatewayPage> createState() => _SecurePeerGatewayPageState();
}

class _SecurePeerGatewayPageState extends State<SecurePeerGatewayPage> {
  // --- FCM State Variables ---
  bool _isConnectedToMasterNode = false;
  StreamSubscription<RemoteMessage>? _fcmSubscription;

  @override
  void initState() {
    super.initState();
    _listenForConnectionVerification();
  }

  // --- FCM Listener Logic ---
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
          HapticFeedback.mediumImpact(); // Nice little physical tap when secured!
        }
      }
    });
  }

  @override
  void dispose() {
    _fcmSubscription?.cancel();
    super.dispose();
  }

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

            // Adjust spacing based on if banner is showing
            SizedBox(height: _isConnectedToMasterNode ? 16 : 32),

            // ---------------------------------------------------------
            // THE COMPACT SECURE BANNER
            // ---------------------------------------------------------
            if (_isConnectedToMasterNode)
              Container(
                margin: const EdgeInsets.only(bottom: 24),
                padding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: Colors.greenAccent.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.greenAccent.withOpacity(0.5),
                    width: 1.5,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.verified_user,
                      color: Colors.greenAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 8),

                    // 🚨 WRAP THE TEXT IN A 'Flexible' WIDGET
                    const Flexible(
                      child: Text(
                        "Chain Secured! Connected to Teacher.",
                        style: TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign
                            .center, // Centers it if it drops to a second line
                      ),
                    ),
                  ],
                ),
              ),

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
                      builder: (context) => SecureProximityHostPage(
                        classroomId: widget.classroomId,
                      ),
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
                        ownUid:
                            GlobalStudentProfile.currentStudent?.uid ??
                            "UNKNOWN_UID",
                        classroomId: widget.classroomId,
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
        scale: _isPressed ? 0.96 : 1.0,
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
