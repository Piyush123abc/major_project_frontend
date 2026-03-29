import 'dart:convert';
import 'package:attendance_app/student_app/student_dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart'; // 🔴 Added this import
import '../../../global_variable/base_url.dart';
import '../../../global_variable/token_handles.dart';
import '../../../global_variable/student_profile.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  // MethodChannel to communicate with Native Android Keystore
  static const _platform = MethodChannel('com.attendance/command');

  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;

  // 🔴 1. Load saved credentials when the page opens
  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
  }

  Future<void> _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUsername = prefs.getString('saved_username');
    final savedPassword = prefs.getString('saved_password');

    if (savedUsername != null && savedPassword != null) {
      setState(() {
        _usernameController.text = savedUsername;
        _passwordController.text = savedPassword;
      });
    }
  }

  // 🔴 2. Save credentials after a successful login
  Future<void> _saveCredentials(String username, String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_username', username);
    await prefs.setString('saved_password', password);
  }

  // The Warning Dialog Method
  Future<void> _showSecurityWarningDialog() async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false, // User must tap the button to close
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.red.shade50,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Colors.red, width: 2),
          ),
          title: const Row(
            children: [
              Icon(Icons.warning_rounded, color: Colors.red, size: 32),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  "SECURITY ALERT",
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          content: const Text(
            "This is NOT your registered device.\n\n"
            "You are allowed to proceed for this session, but your attendance will be FLAGGED as suspicious in the system.",
            style: TextStyle(fontSize: 16, color: Colors.black87),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text("I Understand, Proceed"),
              onPressed: () {
                Navigator.of(context).pop(); // Close the dialog
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _login() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = "Please enter both username and password");
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // =========================================================
      // STEP 1: Request Login Challenge
      // =========================================================
      final challengeUrl = Uri.parse(
        "${BaseUrl.value}/user/student/login/challenge/",
      );
      final challengeRes = await http.post(
        challengeUrl,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"username": username}),
      );

      if (challengeRes.statusCode != 200) {
        throw Exception("Failed to get security challenge. Invalid User?");
      }

      final challengeData = jsonDecode(challengeRes.body);
      final String challengeString = challengeData['challenge'];

      // =========================================================
      // STEP 2: Sign Challenge via Native Keystore (SILENTLY)
      // =========================================================
      String signatureHex = "";
      try {
        // This silently asks the Keystore to sign the string. No UI popup!
        final String result = await _platform.invokeMethod(
          'signDeviceChallenge',
          {'challenge': challengeString},
        );

        if (result.startsWith("Error")) {
          debugPrint("Silent signing failed: $result");
          // signatureHex remains empty
        } else {
          signatureHex = result;
        }
      } catch (e) {
        debugPrint("Native channel failed: $e");
        // signatureHex remains empty, triggering the "WARNING" status from backend
      }

      // =========================================================
      // STEP 3: Verify Signature & Password
      // =========================================================
      final verifyUrl = Uri.parse(
        "${BaseUrl.value}/user/student/login/verify/",
      );
      final verifyRes = await http.post(
        verifyUrl,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "username": username,
          "password": password,
          "signature": signatureHex,
        }),
      );

      if (verifyRes.statusCode == 200) {
        final data = jsonDecode(verifyRes.body);
        final access = data["access"];
        final refresh = data["refresh"];
        final deviceStatus = data["device_status"]; // Check our custom flag

        // Save tokens
        TokenHandles.setTokens(access, refresh);

        // 🔴 3. Save the username and password since login was a success
        await _saveCredentials(username, password);

        // Fetch profile
        final profileHeaders = await TokenHandles.getAuthHeaders();
        final profileRes = await http.get(
          Uri.parse("${BaseUrl.value}/user/profile/"),
          headers: profileHeaders,
        );

        if (profileRes.statusCode == 200) {
          final profileData = jsonDecode(profileRes.body);
          final studentProfile = StudentProfile(
            id: profileData['id'],
            uid: profileData['uid'],
            username: profileData['username'],
            branch: profileData['branch'] ?? '',
            authKey: profileData['auth_key'],
          );
          GlobalStudentProfile.setProfile(studentProfile);

          // 🔴 STEP 4: Check Binding Status
          if (deviceStatus == "WARNING" && mounted) {
            await _showSecurityWarningDialog(); // Halts execution until clicked
          } else if (mounted) {
            // ✅ SUCCESS: Show the verified message
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text("✅ Device binding securely verified!"),
                backgroundColor: Colors.green,
                behavior: SnackBarBehavior.floating,
                duration: Duration(seconds: 2),
              ),
            );
          }

          // Navigate to dashboard AFTER dialog is closed (or immediately if SECURE)
          if (mounted) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const StudentDashboardPage()),
            );
          }
        } else {
          setState(() {
            _error =
                "Failed to fetch profile (Status: ${profileRes.statusCode})";
          });
        }
      } else {
        final data = jsonDecode(verifyRes.body);
        setState(() {
          _error = data["detail"] ?? data["error"] ?? "Login failed";
        });
      }
    } catch (e) {
      setState(() {
        _error = "Error: $e";
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Student Login")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(labelText: "Username"),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(labelText: "Password"),
              obscureText: true,
            ),
            const SizedBox(height: 20),
            if (_error != null)
              Text(
                _error!,
                style: const TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _loading ? null : _login,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                ),
                child: _loading
                    ? const SizedBox(
                        height: 24,
                        width: 24,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text("Login", style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
