import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../../../global_variable/base_url.dart';
import '../../../global_variable/token_handles.dart';
import '../../../global_variable/student_profile.dart';
import 'package:attendance_app/student_app/student_dashboard.dart'; // Make sure this path is correct

class StudentRegisterPage extends StatefulWidget {
  const StudentRegisterPage({super.key});

  @override
  State<StudentRegisterPage> createState() => _StudentRegisterPageState();
}

class _StudentRegisterPageState extends State<StudentRegisterPage> {
  // MethodChannel to communicate with Native Android Keystore
  static const _platform = MethodChannel('com.attendance/command');

  final _formKey = GlobalKey<FormState>();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _uidController = TextEditingController();
  final TextEditingController _branchController = TextEditingController();

  bool _isLoading = false;

  Future<void> _registerStudent() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    bool hasBiometrics = false;
    String base64PublicKey = "";

    try {
      // ─── STEP 1: LOCAL HARDWARE SECURITY ────────────────────────────
      try {
        hasBiometrics = await _platform.invokeMethod('isBiometricAvailable');
      } catch (e) {
        hasBiometrics = false;
      }

      if (hasBiometrics) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                "Please scan fingerprint to set up local security...",
              ),
              backgroundColor: Colors.blueAccent,
            ),
          );
        }

        final String authResult = await _platform.invokeMethod(
          'showBiometricPrompt',
        );

        if (authResult != "SUCCESS") {
          throw Exception("Fingerprint authentication failed or was canceled.");
        }

        // Lock the Android Keystore to current biometrics locally (For Attendance)
        await _platform.invokeMethod('resetBiometricKey');
      }

      // ─── STEP 2: GENERATE SILENT DEVICE BINDING KEY ─────────────────
      // Generate the silent key for backend login verification
      base64PublicKey = await _platform.invokeMethod(
        'generateDeviceBindingKey',
      );
      if (base64PublicKey.startsWith("Error")) {
        throw Exception(base64PublicKey);
      }

      // ─── STEP 3: BACKEND REGISTRATION ───────────────────────────────
      final regUrl = Uri.parse("${BaseUrl.value}/user/register/student/");
      final regBody = jsonEncode({
        "username": _usernameController.text.trim(),
        "password": _passwordController.text.trim(),
        "uid": _uidController.text.trim(),
        "branch": _branchController.text.trim(),
        "public_key": base64PublicKey, // ✅ Send the device key immediately!
      });

      final regResponse = await http.post(
        regUrl,
        headers: {"Content-Type": "application/json"},
        body: regBody,
      );

      if (regResponse.statusCode == 201 || regResponse.statusCode == 200) {
        // Registration successful! Now let's Auto-Login.
        await _autoLoginAndNavigate();
      } else {
        final error = jsonDecode(regResponse.body);
        throw Exception(error.toString());
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("❌ Error: $e"),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─── STEP 4: AUTO-LOGIN PROCESS ───────────────────────────────────
  Future<void> _autoLoginAndNavigate() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    try {
      // 1. Get Challenge
      final challengeRes = await http.post(
        Uri.parse("${BaseUrl.value}/user/student/login/challenge/"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"username": username}),
      );
      if (challengeRes.statusCode != 200) throw Exception("Challenge failed.");

      final String challengeString = jsonDecode(challengeRes.body)['challenge'];

      // 2. Sign Challenge Silently
      final String signatureHex = await _platform.invokeMethod(
        'signDeviceChallenge',
        {'challenge': challengeString},
      );
      if (signatureHex.startsWith("Error")) throw Exception(signatureHex);

      // 3. Verify Login
      final verifyRes = await http.post(
        Uri.parse("${BaseUrl.value}/user/student/login/verify/"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "username": username,
          "password": password,
          "signature": signatureHex,
        }),
      );

      if (verifyRes.statusCode == 200) {
        final data = jsonDecode(verifyRes.body);
        TokenHandles.setTokens(data["access"], data["refresh"]);

        // 4. Fetch Profile
        final profileHeaders = await TokenHandles.getAuthHeaders();
        final profileRes = await http.get(
          Uri.parse("${BaseUrl.value}/user/profile/"),
          headers: profileHeaders,
        );

        if (profileRes.statusCode == 200) {
          final profileData = jsonDecode(profileRes.body);
          GlobalStudentProfile.setProfile(
            StudentProfile(
              id: profileData['id'],
              uid: profileData['uid'],
              username: profileData['username'],
              branch: profileData['branch'] ?? '',
              authKey: profileData['auth_key'],
            ),
          );

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text("✅ Registration Successful! Device Secured."),
                backgroundColor: Colors.green,
              ),
            );

            // Direct route to Dashboard!
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const StudentDashboardPage()),
              (route) => false, // Clears the navigation stack
            );
          }
        }
      } else {
        throw Exception("Auto-login verification failed.");
      }
    } catch (e) {
      // If auto-login fails for some weird reason, drop them at the login screen
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Registered successfully, but auto-login failed. Please log in manually.",
            ),
            backgroundColor: Colors.orange,
          ),
        );
        Navigator.pop(context); // Go back to login screen
      }
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
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text(
                        "Register & Secure Device",
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
