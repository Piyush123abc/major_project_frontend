// lib/student/student_register_page.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // ✅ Added for MethodChannel
import 'package:http/http.dart' as http;
import 'package:cryptography/cryptography.dart'; // ✅ For backend keypair
import '../../../global_variable/base_url.dart';

class StudentRegisterPage extends StatefulWidget {
  const StudentRegisterPage({super.key});

  @override
  State<StudentRegisterPage> createState() => _StudentRegisterPageState();
}

class _StudentRegisterPageState extends State<StudentRegisterPage> {
  // ✅ Setup the platform channel to communicate with Kotlin locally
  static const _platform = MethodChannel('com.attendance/command');

  final _formKey = GlobalKey<FormState>();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _uidController = TextEditingController();
  final TextEditingController _branchController = TextEditingController();

  bool _isLoading = false;

  // ✅ Generate a new software keypair for the backend payload
  Future<String> _generatePublicKey() async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();

    // Extract and encode public key
    final publicKey = await keyPair.extractPublicKey();
    final rawBytes = publicKey.bytes;
    return base64Encode(rawBytes);
  }

  Future<void> _registerStudent() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    bool hasBiometrics = false;

    try {
      // ─── STEP 1: LOCAL HARDWARE SECURITY ────────────────────────────

      // Ask Native OS if the phone actually has a fingerprint scanner
      try {
        hasBiometrics = await _platform.invokeMethod('isBiometricAvailable');
      } catch (e) {
        // Failsafe if an old phone doesn't understand the command
        hasBiometrics = false;
      }

      if (hasBiometrics) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                "Please scan fingerprint to set up local security...", // Softer language
              ),
              backgroundColor: Colors.blueAccent,
            ),
          );
        }

        final String authResult = await _platform.invokeMethod(
          'showBiometricPrompt',
        );

        if (authResult != "SUCCESS") {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  "❌ Fingerprint authentication failed. Registration aborted.",
                ),
                backgroundColor: Colors.red,
              ),
            );
            setState(() => _isLoading = false);
          }
          return; // Stop registration if they cancel the prompt
        }

        // Lock the Android Keystore to current biometrics locally
        await _platform.invokeMethod('resetBiometricKey');
      } else {
        // Graceful skip for older phones without biometric hardware
        debugPrint(
          "No biometric hardware detected. Skipping local Keystore lock.",
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                "No fingerprint sensor detected. Proceeding with standard registration...",
              ),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
      // ────────────────────────────────────────────────────────────────

      // ─── STEP 2: BACKEND REGISTRATION ───────────────────────────────

      // Generate software fingerprint key for backend compatibility
      final fingerprintKey = await _generatePublicKey();

      final url = Uri.parse("${BaseUrl.value}/user/register/student/");
      final body = jsonEncode({
        "username": _usernameController.text,
        "password": _passwordController.text,
        "uid": _uidController.text,
        "branch": _branchController.text,
        "fingerprint_key": fingerprintKey, // send backend key
      });

      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: body,
      );

      if (response.statusCode == 201 || response.statusCode == 200) {
        final data = jsonDecode(response.body);

        if (mounted) {
          showDialog(
            context: context,
            barrierDismissible: false, // Force them to press OK
            builder: (context) => AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              icon: const Icon(
                Icons.check_circle,
                color: Colors.green,
                size: 48,
              ),
              // ✅ FittedBox guarantees the text will shrink to fit the screen instead of overflowing
              title: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  "Registration Successful 🎉",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: double.maxFinite,
                  child: Text(
                    hasBiometrics
                        ? "Your account has been registered and local device security is configured.\n\nDetails: $data"
                        : "Your account has been registered.\n\n(Note: Local hardware security was skipped as this device lacks a fingerprint scanner.)\n\nDetails: $data",
                    style: const TextStyle(fontSize: 15, height: 1.4),
                  ),
                ),
              ),
              actionsAlignment: MainAxisAlignment.center,
              actions: [
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context); // close dialog
                    Navigator.pop(context); // go back
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 12,
                    ),
                  ),
                  child: const Text(
                    "OK",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ],
            ),
          );
        }
      } else {
        final error = jsonDecode(response.body);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text("Error: $error")));
        }
      }
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("❌ Hardware Security Error: ${e.message}"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Something went wrong: $e")));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Student Registration")),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              TextFormField(
                controller: _usernameController,
                decoration: const InputDecoration(labelText: "Username"),
                validator: (v) => v!.isEmpty ? "Enter username" : null,
              ),
              TextFormField(
                controller: _passwordController,
                decoration: const InputDecoration(labelText: "Password"),
                obscureText: true,
                validator: (v) => v!.isEmpty ? "Enter password" : null,
              ),
              TextFormField(
                controller: _uidController,
                decoration: const InputDecoration(labelText: "UID"),
                validator: (v) => v!.isEmpty ? "Enter UID" : null,
              ),
              TextFormField(
                controller: _branchController,
                decoration: const InputDecoration(labelText: "Branch"),
                validator: (v) => v!.isEmpty ? "Enter branch" : null,
              ),
              const SizedBox(height: 30),
              _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton(
                      onPressed: _registerStudent,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                      ),
                      child: const Text("Register"),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
