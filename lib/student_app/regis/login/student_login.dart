import 'dart:convert';
import 'package:attendance_app/security_reporter.dart';
import 'package:attendance_app/student_app/student_dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app_device_integrity/app_device_integrity.dart';
import '../../../global_variable/base_url.dart';
import '../../../global_variable/token_handles.dart';
import '../../../global_variable/student_profile.dart';

// ── Step model ────────────────────────────────────────────────────────────────

enum _StepState { idle, running, passed, warning, failed }

class _SecurityStep {
  final String title;
  final String subtitle;
  final IconData icon;
  _StepState state;

  _SecurityStep({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.state = _StepState.idle,
  });
}

// ── Page ──────────────────────────────────────────────────────────────────────

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  static const _platform = MethodChannel('com.attendance/command');

  final ScrollController _scrollController = ScrollController();

  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;
  String? _error;
  bool _isVerified = false;

  // ✅ NEW: Controls when to show the manual "Continue" button
  bool _readyToNavigate = false;

  // ── Security steps (UI only) ────────────────────────────────────────────────
  final List<_SecurityStep> _steps = [
    _SecurityStep(
      title: 'Server Challenge',
      subtitle: 'Fetching cryptographic nonce',
      icon: Icons.lock_outline,
    ),
    _SecurityStep(
      title: 'Hardware Binding',
      subtitle: 'Android Keystore signature check',
      icon: Icons.smartphone,
    ),
    _SecurityStep(
      title: 'Play Integrity API',
      subtitle: 'Google attestation token',
      icon: Icons.verified_user_outlined,
    ),
    _SecurityStep(
      title: 'Credential Verify',
      subtitle: 'Server authentication',
      icon: Icons.key_outlined,
    ),
    _SecurityStep(
      title: 'Profile Fetch',
      subtitle: 'Loading student data',
      icon: Icons.person_outline,
    ),
  ];

  bool _showSteps = false;

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _setStep(int index, _StepState state) {
    if (mounted) setState(() => _steps[index].state = state);
  }

  void _resetSteps() {
    for (final s in _steps) {
      s.state = _StepState.idle;
    }
  }

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
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

  Future<void> _saveCredentials(String username, String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_username', username);
    await prefs.setString('saved_password', password);
  }

  Future<void> _showSecurityWarningDialog() async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.orange.shade50,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Colors.orange, width: 2),
          ),
          title: const Row(
            children: [
              Icon(Icons.phone_android, color: Colors.orange, size: 32),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  "UNRECOGNIZED DEVICE",
                  style: TextStyle(
                    color: Colors.orange,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          content: const Text(
            "This is NOT your registered device.\n\n"
            "You are allowed to proceed for this session, but your attendance will be FLAGGED as suspicious in the system. Please reset your device binding.",
            style: TextStyle(fontSize: 16, color: Colors.black87),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
              child: const Text("I Understand, Proceed"),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showIntegrityWarningDialog() async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
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
            "Google Play Protect has flagged this app version.\n\n"
            "This app appears to be modified, unofficial, or running on an insecure device (e.g., rooted). Your actions may be monitored.",
            style: TextStyle(fontSize: 16, color: Colors.black87),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text("Proceed Anyway (Testing)"),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
  }

  // ── Login logic ─────────────────────────────────────────────────────────────

  Future<void> _login() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = "Please enter both username and password");
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();

    setState(() {
      _loading = true;
      _error = null;
      _isVerified = false;
      _readyToNavigate = false; // Reset the button
      _showSteps = true;
      _resetSteps();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
          );
        }
      });
    });

    try {
      // ── Step 0 : Server Challenge ─────────────────────────────────────────
      _setStep(0, _StepState.running);

      final challengeUrl = Uri.parse(
        "${BaseUrl.value}/user/student/login/challenge/",
      );
      final challengeRes = await http.post(
        challengeUrl,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"username": username}),
      );

      if (challengeRes.statusCode != 200) {
        _setStep(0, _StepState.failed);
        throw Exception("Failed to get security challenge. Invalid User?");
      }

      final challengeData = jsonDecode(challengeRes.body);
      final String challengeString = challengeData['challenge'];
      _setStep(0, _StepState.passed);

      // ── Step 1 : Hardware Binding ─────────────────────────────────────────
      await Future.delayed(const Duration(milliseconds: 500));
      _setStep(1, _StepState.running);

      String signatureHex = "";
      try {
        final String result = await _platform.invokeMethod(
          'signDeviceChallenge',
          {'challenge': challengeString},
        );

        if (!result.startsWith("Error")) {
          signatureHex = result;
          _setStep(1, _StepState.passed);
        } else {
          _setStep(1, _StepState.warning);
        }
      } catch (e) {
        debugPrint("Native channel failed: $e");
        _setStep(1, _StepState.warning);
      }

      // ── Step 2 : Play Integrity ───────────────────────────────────────────
      await Future.delayed(const Duration(milliseconds: 600));
      _setStep(2, _StepState.running);

      String googleIntegrityToken = "";
      try {
        final integrity = AppDeviceIntegrity();

        final token = await integrity.getAttestationServiceSupport(
          challengeString: challengeString,
          gcp: 964919316579,
        );

        googleIntegrityToken = token ?? "";
        if (googleIntegrityToken.isNotEmpty) {
          _setStep(2, _StepState.passed);
        } else {
          _setStep(2, _StepState.warning);
        }
      } catch (e) {
        debugPrint("Play Integrity Generation Failed: $e");
        _setStep(2, _StepState.warning);
      }

      // ── Step 3 : Credential Verify ────────────────────────────────────────
      await Future.delayed(const Duration(milliseconds: 400));
      _setStep(3, _StepState.running);

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
          "integrity_token": googleIntegrityToken,
        }),
      );

      if (verifyRes.statusCode == 200) {
        final data = jsonDecode(verifyRes.body);
        final access = data["access"];
        final refresh = data["refresh"];
        final deviceStatus = data["device_status"];

        TokenHandles.setTokens(access, refresh);
        await _saveCredentials(username, password);
        _setStep(3, _StepState.passed);

        // ── Step 4 : Profile Fetch ────────────────────────────────────────
        _setStep(4, _StepState.running);

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
          _setStep(4, _StepState.passed);

          if (mounted) {
            if (deviceStatus == "INTEGRITY_FAILED") {
              _setStep(2, _StepState.failed);
              await SecurityReporter.reportAnomaly(
                anomalyTypeInt: 6,
                source: "login_page_integrity_check",
              );
              await _showIntegrityWarningDialog(); // Pauses for dialog
            } else if (deviceStatus == "BINDING_FAILED" ||
                deviceStatus == "WARNING") {
              _setStep(1, _StepState.failed);
              await SecurityReporter.reportAnomaly(
                anomalyTypeInt: 4,
                source: "login_page_device_binding",
              );
              await _showSecurityWarningDialog(); // Pauses for dialog
            } else {
              setState(() => _isVerified = true);
            }

            // ✅ NEW: Instead of navigating automatically, reveal the button
            if (mounted) {
              setState(() {
                _readyToNavigate = true;
              });

              // Scroll to the very bottom one last time to reveal the button
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _scrollController.animateTo(
                  _scrollController.position.maxScrollExtent,
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeOutCubic,
                );
              });
            }
          }
        } else {
          _setStep(4, _StepState.failed);
          setState(() {
            _error =
                "Failed to fetch profile (Status: ${profileRes.statusCode})";
          });
        }
      } else {
        _setStep(3, _StepState.failed);
        final data = jsonDecode(verifyRes.body);
        setState(() {
          _error = data["detail"] ?? data["error"] ?? "Login failed";
        });
      }
    } catch (e) {
      setState(() => _error = "Error: $e");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: const Text("Student Login"),
        backgroundColor: const Color(0xFF1A1A2E),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // ── Login card ──────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // Shield icon header
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A2E),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Icon(
                        Icons.shield_outlined,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      "Secure Login",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Attendance Management System",
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade500,
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _usernameController,
                      enabled: !_loading && !_readyToNavigate,
                      decoration: InputDecoration(
                        labelText: "Username",
                        prefixIcon: const Icon(Icons.person_outline),
                        filled: true,
                        fillColor: const Color(0xFFF5F6FA),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: Color(0xFF1A1A2E),
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passwordController,
                      enabled: !_loading && !_readyToNavigate,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: "Password",
                        prefixIcon: const Icon(Icons.lock_outline),
                        filled: true,
                        fillColor: const Color(0xFFF5F6FA),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: Color(0xFF1A1A2E),
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.error_outline,
                              color: Colors.red.shade700,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  color: Colors.red.shade700,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),

                    // Only show the primary login button if we haven't finished the process
                    if (!_readyToNavigate)
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _login,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1A1A2E),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            elevation: 0,
                          ),
                          child: _loading
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text(
                                  "Login Securely",
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                        ),
                      ),
                  ],
                ),
              ),

              // ── Security verification panel ─────────────────────────────
              if (_showSteps) ...[
                const SizedBox(height: 20),
                _SecurityVerificationPanel(
                  steps: _steps,
                  isLoading: _loading,
                  isVerified: _isVerified,
                ),
              ],

              // ✅ NEW: The manual continue button that appears at the very end
              if (_readyToNavigate) ...[
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const StudentDashboardPage(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: const Text(
                      "Continue to Dashboard",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade600,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 2,
                    ),
                  ),
                ),
                const SizedBox(height: 10), // Padding below the button
              ],
            ],
          ),
        ),
      ),

      // ── Verified badge (bottom bar) ─────────────────────────────────────
      bottomNavigationBar: _isVerified
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 16,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.green.shade400, width: 2),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.verified_user_rounded, color: Colors.green),
                      SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          "App Integrity & Android Binding Confirmed",
                          style: TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : null,
    );
  }
}

// ── Security Verification Panel Widget ────────────────────────────────────────

class _SecurityVerificationPanel extends StatelessWidget {
  final List<_SecurityStep> steps;
  final bool isLoading;
  final bool isVerified;

  const _SecurityVerificationPanel({
    required this.steps,
    required this.isLoading,
    required this.isVerified,
  });

  // Determine overall result from step states
  _OverallResult get _overallResult {
    if (isLoading) return _OverallResult.running;
    final hasFailed = steps.any((s) => s.state == _StepState.failed);
    final hasWarning = steps.any((s) => s.state == _StepState.warning);
    if (hasFailed) return _OverallResult.failed;
    if (hasWarning) return _OverallResult.warning;
    final allDone = steps.every((s) => s.state == _StepState.passed);
    if (allDone) return _OverallResult.passed;
    return _OverallResult.running;
  }

  @override
  Widget build(BuildContext context) {
    final result = _overallResult;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Panel header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: Color(0xFF1A1A2E),
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                // Animated dot
                _PulseDot(isLoading: isLoading, result: result),
                const SizedBox(width: 10),
                Text(
                  isLoading
                      ? "Running Security Checks..."
                      : result == _OverallResult.passed
                      ? "All Checks Passed"
                      : result == _OverallResult.warning
                      ? "Completed with Warnings"
                      : "Security Check Failed",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const Spacer(),
                Text(
                  "${steps.where((s) => s.state == _StepState.passed || s.state == _StepState.warning || s.state == _StepState.failed).length}/${steps.length}",
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.6),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          // Step list
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: steps.map((step) => _StepCard(step: step)).toList(),
            ),
          ),

          // Result bar (shown when done)
          if (!isLoading) _ResultBar(result: result),
        ],
      ),
    );
  }
}

// ── Individual step card ──────────────────────────────────────────────────────

class _StepCard extends StatelessWidget {
  final _SecurityStep step;

  const _StepCard({required this.step});

  @override
  Widget build(BuildContext context) {
    final cfg = _stepConfig(step.state);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cfg.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cfg.border, width: 1),
      ),
      child: Row(
        children: [
          // Icon circle
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: cfg.iconBg,
              shape: BoxShape.circle,
            ),
            child: step.state == _StepState.running
                ? Padding(
                    padding: const EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cfg.iconColor,
                    ),
                  )
                : Icon(
                    step.state == _StepState.passed
                        ? Icons.check
                        : step.state == _StepState.failed
                        ? Icons.close
                        : step.state == _StepState.warning
                        ? Icons.warning_amber_rounded
                        : step.icon,
                    size: 18,
                    color: cfg.iconColor,
                  ),
          ),
          const SizedBox(width: 12),
          // Text
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cfg.titleColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  step.subtitle,
                  style: TextStyle(fontSize: 11, color: cfg.subtitleColor),
                ),
              ],
            ),
          ),
          // Badge
          _StatusBadge(state: step.state),
        ],
      ),
    );
  }

  _StepVisualConfig _stepConfig(_StepState state) {
    switch (state) {
      case _StepState.idle:
        return _StepVisualConfig(
          bg: const Color(0xFFF8F9FA),
          border: const Color(0xFFE9ECEF),
          iconBg: const Color(0xFFE9ECEF),
          iconColor: Colors.grey.shade500,
          titleColor: Colors.grey.shade600,
          subtitleColor: Colors.grey.shade400,
        );
      case _StepState.running:
        return _StepVisualConfig(
          bg: const Color(0xFFFFF8E1),
          border: const Color(0xFFFFE082),
          iconBg: const Color(0xFFFFE082),
          iconColor: const Color(0xFFF57F17),
          titleColor: const Color(0xFF1A1A2E),
          subtitleColor: Colors.grey.shade600,
        );
      case _StepState.passed:
        return _StepVisualConfig(
          bg: const Color(0xFFF1FBF5),
          border: const Color(0xFFA8D5B5),
          iconBg: const Color(0xFF2E7D32),
          iconColor: Colors.white,
          titleColor: const Color(0xFF1A1A2E),
          subtitleColor: Colors.grey.shade600,
        );
      case _StepState.warning:
        return _StepVisualConfig(
          bg: const Color(0xFFFFF8E1),
          border: const Color(0xFFFFCC02),
          iconBg: const Color(0xFFF57F17),
          iconColor: Colors.white,
          titleColor: const Color(0xFF1A1A2E),
          subtitleColor: Colors.grey.shade600,
        );
      case _StepState.failed:
        return _StepVisualConfig(
          bg: const Color(0xFFFFF5F5),
          border: const Color(0xFFFFCDD2),
          iconBg: const Color(0xFFC62828),
          iconColor: Colors.white,
          titleColor: const Color(0xFF1A1A2E),
          subtitleColor: Colors.grey.shade600,
        );
    }
  }
}

class _StepVisualConfig {
  final Color bg, border, iconBg, iconColor, titleColor, subtitleColor;
  const _StepVisualConfig({
    required this.bg,
    required this.border,
    required this.iconBg,
    required this.iconColor,
    required this.titleColor,
    required this.subtitleColor,
  });
}

// ── Status badge ──────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final _StepState state;
  const _StatusBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    String label;
    Color bg, fg;

    switch (state) {
      case _StepState.idle:
        label = "Waiting";
        bg = const Color(0xFFE9ECEF);
        fg = Colors.grey.shade600;
        break;
      case _StepState.running:
        label = "Checking";
        bg = const Color(0xFFFFE082);
        fg = const Color(0xFFF57F17);
        break;
      case _StepState.passed:
        label = "Passed";
        bg = const Color(0xFFDCEFE1);
        fg = const Color(0xFF2E7D32);
        break;
      case _StepState.warning:
        label = "Warning";
        bg = const Color(0xFFFFE0B2);
        fg = const Color(0xFFE65100);
        break;
      case _StepState.failed:
        label = "Failed";
        bg = const Color(0xFFFFCDD2);
        fg = const Color(0xFFC62828);
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}

// ── Result bar ────────────────────────────────────────────────────────────────

enum _OverallResult { running, passed, warning, failed }

class _ResultBar extends StatelessWidget {
  final _OverallResult result;
  const _ResultBar({required this.result});

  @override
  Widget build(BuildContext context) {
    if (result == _OverallResult.running) return const SizedBox.shrink();

    Color bg, border, fg;
    IconData icon;
    String text;

    switch (result) {
      case _OverallResult.passed:
        bg = const Color(0xFFF1FBF5);
        border = const Color(0xFFA8D5B5);
        fg = const Color(0xFF2E7D32);
        icon = Icons.verified_user_rounded;
        text = "Full security clearance granted";
        break;
      case _OverallResult.warning:
        bg = const Color(0xFFFFF8E1);
        border = const Color(0xFFFFCC02);
        fg = const Color(0xFFF57F17);
        icon = Icons.warning_amber_rounded;
        text = "Session flagged — unrecognized device";
        break;
      default:
        bg = const Color(0xFFFFF5F5);
        border = const Color(0xFFFFCDD2);
        fg = const Color(0xFFC62828);
        icon = Icons.gpp_bad_outlined;
        text = "Security check failed";
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 18),
          const SizedBox(width: 10),
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Animated pulse dot ────────────────────────────────────────────────────────

class _PulseDot extends StatefulWidget {
  final bool isLoading;
  final _OverallResult result;

  const _PulseDot({required this.isLoading, required this.result});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Color dotColor;
    if (widget.isLoading) {
      dotColor = const Color(0xFF00C896);
    } else {
      switch (widget.result) {
        case _OverallResult.passed:
          dotColor = Colors.greenAccent;
          break;
        case _OverallResult.warning:
          dotColor = Colors.amber;
          break;
        default:
          dotColor = Colors.redAccent;
      }
    }

    return widget.isLoading
        ? FadeTransition(
            opacity: _anim,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
          )
        : Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          );
  }
}
