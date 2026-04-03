import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../../../global_variable/base_url.dart';
import '../../../global_variable/token_handles.dart';
import '../../../global_variable/student_profile.dart';
import 'package:attendance_app/student_app/student_dashboard.dart';

// ── Step model ────────────────────────────────────────────────────────────────

enum _StepState { idle, running, passed, warning, failed }

class _SecurityStep {
  final String title;
  final String subtitle;
  final IconData icon;
  _StepState state;
  String? detail; // optional extra detail shown after completion

  _SecurityStep({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.state = _StepState.idle,
    this.detail,
  });
}

// ── Page ──────────────────────────────────────────────────────────────────────

class StudentRegisterPage extends StatefulWidget {
  const StudentRegisterPage({super.key});

  @override
  State<StudentRegisterPage> createState() => _StudentRegisterPageState();
}

class _StudentRegisterPageState extends State<StudentRegisterPage> {
  static const _platform = MethodChannel('com.attendance/command');

  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _uidController = TextEditingController();
  final _branchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _isLoading = false;
  bool _showSteps = false;
  String? _error;

  // Registration steps
  final List<_SecurityStep> _steps = [
    _SecurityStep(
      title: 'Biometric Check',
      subtitle: 'Checking fingerprint hardware availability',
      icon: Icons.fingerprint,
    ),
    _SecurityStep(
      title: 'Fingerprint Auth',
      subtitle: 'Locking local attendance key to your fingerprint',
      icon: Icons.lock_person_outlined,
    ),
    _SecurityStep(
      title: 'Device Binding Key',
      subtitle: 'Generating Android Keystore binding key',
      icon: Icons.key_outlined,
    ),
    _SecurityStep(
      title: 'Backend Registration',
      subtitle: 'Creating account & uploading device public key',
      icon: Icons.cloud_upload_outlined,
    ),
    _SecurityStep(
      title: 'Auto Login — Challenge',
      subtitle: 'Fetching server cryptographic nonce',
      icon: Icons.lock_outline,
    ),
    _SecurityStep(
      title: 'Auto Login — Signing',
      subtitle: 'Signing challenge with device key',
      icon: Icons.edit_outlined,
    ),
    _SecurityStep(
      title: 'Auto Login — Verify',
      subtitle: 'Server verifying signed credentials',
      icon: Icons.verified_outlined,
    ),
    _SecurityStep(
      title: 'Profile Fetch',
      subtitle: 'Loading your student profile',
      icon: Icons.person_outline,
    ),
  ];

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _setStep(int index, _StepState state, {String? detail}) {
    if (mounted) {
      setState(() {
        _steps[index].state = state;
        if (detail != null) _steps[index].detail = detail;
      });
      _scrollToBottom();
    }
  }

  void _resetSteps() {
    for (final s in _steps) {
      s.state = _StepState.idle;
      s.detail = null;
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _uidController.dispose();
    _branchController.dispose();
    super.dispose();
  }

  // ── Show review bottom sheet before navigating ────────────────────────────

  Future<void> _showSuccessReviewSheet(StudentProfile profile) async {
    await showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _SuccessReviewSheet(
        steps: _steps,
        profile: profile,
        onProceed: () => Navigator.of(ctx).pop(),
      ),
    );
  }

  // ── Registration logic ───────────────────────────────────────────────────

  Future<void> _registerStudent() async {
    if (!_formKey.currentState!.validate()) return;

    // Hide keyboard
    FocusManager.instance.primaryFocus?.unfocus();

    setState(() {
      _isLoading = true;
      _showSteps = true;
      _error = null;
      _resetSteps();
    });
    _scrollToBottom();

    bool hasBiometrics = false;
    String base64PublicKey = "";

    try {
      // ─── STEP 0: Biometric Check ─────────────────────────────────────
      _setStep(0, _StepState.running);
      try {
        hasBiometrics = await _platform.invokeMethod('isBiometricAvailable');
      } catch (e) {
        hasBiometrics = false;
      }
      _setStep(
        0,
        _StepState.passed,
        detail: hasBiometrics
            ? 'Fingerprint hardware detected'
            : 'No biometric hardware (skipped)',
      );

      // ─── STEP 1: Fingerprint Auth ─────────────────────────────────────
      if (hasBiometrics) {
        _setStep(1, _StepState.running);

        final String authResult = await _platform.invokeMethod(
          'showBiometricPrompt',
        );

        if (authResult != "SUCCESS") {
          _setStep(1, _StepState.failed, detail: 'Auth canceled or rejected');
          throw Exception("Fingerprint authentication failed or was canceled.");
        }

        await _platform.invokeMethod('resetBiometricKey');
        _setStep(
          1,
          _StepState.passed,
          detail: 'Attendance key locked to fingerprint',
        );
      } else {
        _setStep(
          1,
          _StepState.warning,
          detail: 'Skipped — no biometric hardware',
        );
      }

      // ─── STEP 2: Device Binding Key ───────────────────────────────────
      _setStep(2, _StepState.running);
      base64PublicKey = await _platform.invokeMethod(
        'generateDeviceBindingKey',
      );
      if (base64PublicKey.startsWith("Error")) {
        _setStep(2, _StepState.failed, detail: base64PublicKey);
        throw Exception(base64PublicKey);
      }
      _setStep(
        2,
        _StepState.passed,
        detail: 'Public key generated in Keystore',
      );

      // ─── STEP 3: Backend Registration ────────────────────────────────
      _setStep(3, _StepState.running);
      final regUrl = Uri.parse("${BaseUrl.value}/user/register/student/");
      final regBody = jsonEncode({
        "username": _usernameController.text.trim(),
        "password": _passwordController.text.trim(),
        "uid": _uidController.text.trim(),
        "branch": _branchController.text.trim(),
        "public_key": base64PublicKey,
      });

      final regResponse = await http.post(
        regUrl,
        headers: {"Content-Type": "application/json"},
        body: regBody,
      );

      if (regResponse.statusCode == 201 || regResponse.statusCode == 200) {
        _setStep(
          3,
          _StepState.passed,
          detail: 'Account created & device key uploaded',
        );
        await _autoLoginAndNavigate();
      } else {
        final error = jsonDecode(regResponse.body);
        _setStep(3, _StepState.failed, detail: error.toString());
        throw Exception(error.toString());
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─── Auto-Login ────────────────────────────────────────────────────────
  Future<void> _autoLoginAndNavigate() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    try {
      // Step 4: Challenge
      _setStep(4, _StepState.running);
      final challengeRes = await http.post(
        Uri.parse("${BaseUrl.value}/user/student/login/challenge/"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"username": username}),
      );
      if (challengeRes.statusCode != 200) {
        _setStep(
          4,
          _StepState.failed,
          detail: 'Server did not return a challenge',
        );
        throw Exception("Challenge failed.");
      }
      final String challengeString = jsonDecode(challengeRes.body)['challenge'];
      _setStep(4, _StepState.passed, detail: 'Nonce received from server');

      // Step 5: Sign
      _setStep(5, _StepState.running);
      final String signatureHex = await _platform.invokeMethod(
        'signDeviceChallenge',
        {'challenge': challengeString},
      );
      if (signatureHex.startsWith("Error")) {
        _setStep(5, _StepState.failed, detail: signatureHex);
        throw Exception(signatureHex);
      }
      _setStep(
        5,
        _StepState.passed,
        detail: 'Challenge signed with device key',
      );

      // Step 6: Verify
      _setStep(6, _StepState.running);
      final verifyRes = await http.post(
        Uri.parse("${BaseUrl.value}/user/student/login/verify/"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "username": username,
          "password": password,
          "signature": signatureHex,
        }),
      );

      if (verifyRes.statusCode != 200) {
        _setStep(
          6,
          _StepState.failed,
          detail: 'Server rejected the signed payload',
        );
        throw Exception("Auto-login verification failed.");
      }

      final data = jsonDecode(verifyRes.body);
      TokenHandles.setTokens(data["access"], data["refresh"]);
      _setStep(6, _StepState.passed, detail: 'JWT tokens issued by server');

      // Step 7: Profile
      _setStep(7, _StepState.running);
      final profileHeaders = await TokenHandles.getAuthHeaders();
      final profileRes = await http.get(
        Uri.parse("${BaseUrl.value}/user/profile/"),
        headers: profileHeaders,
      );

      if (profileRes.statusCode != 200) {
        _setStep(
          7,
          _StepState.failed,
          detail: 'Profile endpoint returned error',
        );
        throw Exception("Profile fetch failed.");
      }

      final profileData = jsonDecode(profileRes.body);
      final profile = StudentProfile(
        id: profileData['id'],
        uid: profileData['uid'],
        username: profileData['username'],
        branch: profileData['branch'] ?? '',
        authKey: profileData['auth_key'],
      );
      GlobalStudentProfile.setProfile(profile);
      _setStep(7, _StepState.passed, detail: 'Student profile loaded');

      // ── Show review sheet — teacher reads, then taps Proceed ──────────
      if (mounted) {
        await _showSuccessReviewSheet(profile);
      }

      // Navigate only after teacher taps Proceed
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const StudentDashboardPage()),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Registered successfully, but auto-login failed. Please log in manually.",
            ),
            backgroundColor: Colors.orange,
          ),
        );
        Navigator.pop(context);
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: const Text("Student Registration"),
        backgroundColor: const Color(0xFF1A1A2E),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Registration form card ──────────────────────────────────
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
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    // Header
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A2E),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Icon(
                        Icons.app_registration,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      "Create Secure Account",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Your device will be cryptographically bound",
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade500,
                      ),
                    ),
                    const SizedBox(height: 24),

                    _FormField(
                      controller: _usernameController,
                      label: "Username",
                      icon: Icons.person_outline,
                      enabled: !_isLoading,
                      validator: (v) => v!.isEmpty ? "Enter username" : null,
                    ),
                    const SizedBox(height: 12),
                    _FormField(
                      controller: _passwordController,
                      label: "Password",
                      icon: Icons.lock_outline,
                      obscure: true,
                      enabled: !_isLoading,
                      validator: (v) => v!.isEmpty ? "Enter password" : null,
                    ),
                    const SizedBox(height: 12),
                    _FormField(
                      controller: _uidController,
                      label: "UID",
                      icon: Icons.badge_outlined,
                      enabled: !_isLoading,
                      validator: (v) => v!.isEmpty ? "Enter UID" : null,
                    ),
                    const SizedBox(height: 12),
                    _FormField(
                      controller: _branchController,
                      label: "Branch",
                      icon: Icons.school_outlined,
                      enabled: !_isLoading,
                      validator: (v) => v!.isEmpty ? "Enter branch" : null,
                    ),
                    const SizedBox(height: 8),

                    // Error box
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
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _registerStudent,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1A1A2E),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          elevation: 0,
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text(
                                "Register & Secure Device",
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
            ),

            // ── Security verification panel ─────────────────────────────
            if (_showSteps) ...[
              const SizedBox(height: 20),
              _SecurityVerificationPanel(steps: _steps, isLoading: _isLoading),
              const SizedBox(height: 24),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Reusable styled form field ────────────────────────────────────────────────

class _FormField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscure;
  final bool enabled;
  final String? Function(String?)? validator;

  const _FormField({
    required this.controller,
    required this.label,
    required this.icon,
    this.obscure = false,
    this.enabled = true,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      enabled: enabled,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        filled: true,
        fillColor: const Color(0xFFF5F6FA),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF1A1A2E), width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.red.shade300),
        ),
      ),
    );
  }
}

// ── Security Verification Panel ───────────────────────────────────────────────

class _SecurityVerificationPanel extends StatelessWidget {
  final List<_SecurityStep> steps;
  final bool isLoading;

  const _SecurityVerificationPanel({
    required this.steps,
    required this.isLoading,
  });

  _OverallResult get _overallResult {
    if (isLoading) return _OverallResult.running;
    final hasFailed = steps.any((s) => s.state == _StepState.failed);
    final hasWarning = steps.any((s) => s.state == _StepState.warning);
    if (hasFailed) return _OverallResult.failed;
    if (hasWarning) return _OverallResult.warning;
    final allDone = steps.every(
      (s) => s.state == _StepState.passed || s.state == _StepState.warning,
    );
    if (allDone) return _OverallResult.passed;
    return _OverallResult.running;
  }

  @override
  Widget build(BuildContext context) {
    final result = _overallResult;
    final completed = steps
        .where(
          (s) =>
              s.state == _StepState.passed ||
              s.state == _StepState.warning ||
              s.state == _StepState.failed,
        )
        .length;

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
                _PulseDot(isLoading: isLoading, result: result),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    isLoading
                        ? "Running Security Setup..."
                        : result == _OverallResult.passed
                        ? "All Security Steps Passed"
                        : result == _OverallResult.warning
                        ? "Completed with Warnings"
                        : "Security Setup Failed",
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                Text(
                  "$completed/${steps.length}",
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
              children: steps.map((s) => _StepCard(step: s)).toList(),
            ),
          ),

          // Result bar
          if (!isLoading) _ResultBar(result: result),
        ],
      ),
    );
  }
}

// ── Step card ─────────────────────────────────────────────────────────────────

class _StepCard extends StatelessWidget {
  final _SecurityStep step;
  const _StepCard({required this.step});

  @override
  Widget build(BuildContext context) {
    final cfg = _config(step.state);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cfg.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cfg.border),
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
                  (step.detail != null &&
                          step.state != _StepState.idle &&
                          step.state != _StepState.running)
                      ? step.detail!
                      : step.subtitle,
                  style: TextStyle(fontSize: 11, color: cfg.subtitleColor),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Badge
          _StatusBadge(state: step.state),
        ],
      ),
    );
  }

  _StepVisualConfig _config(_StepState state) {
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
        label = "Running";
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
        text = "Device secured & account created";
        break;
      case _OverallResult.warning:
        bg = const Color(0xFFFFF8E1);
        border = const Color(0xFFFFCC02);
        fg = const Color(0xFFF57F17);
        icon = Icons.warning_amber_rounded;
        text = "Completed with warnings";
        break;
      default:
        bg = const Color(0xFFFFF5F5);
        border = const Color(0xFFFFCDD2);
        fg = const Color(0xFFC62828);
        icon = Icons.gpp_bad_outlined;
        text = "Registration failed";
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

// ── Pulse dot ─────────────────────────────────────────────────────────────────

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
    Color color;
    if (widget.isLoading) {
      color = const Color(0xFF00C896);
    } else {
      switch (widget.result) {
        case _OverallResult.passed:
          color = Colors.greenAccent;
          break;
        case _OverallResult.warning:
          color = Colors.amber;
          break;
        default:
          color = Colors.redAccent;
      }
    }

    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );

    return widget.isLoading ? FadeTransition(opacity: _anim, child: dot) : dot;
  }
}

// ── Success Review Bottom Sheet ───────────────────────────────────────────────

class _SuccessReviewSheet extends StatefulWidget {
  final List<_SecurityStep> steps;
  final StudentProfile profile;
  final VoidCallback onProceed;

  const _SuccessReviewSheet({
    required this.steps,
    required this.profile,
    required this.onProceed,
  });

  @override
  State<_SuccessReviewSheet> createState() => _SuccessReviewSheetState();
}

class _SuccessReviewSheetState extends State<_SuccessReviewSheet> {
  final ScrollController _sheetScrollController = ScrollController();
  bool _showScrollIndicator = true;

  @override
  void initState() {
    super.initState();
    _sheetScrollController.addListener(_scrollListener);

    // Check if scrolling is even necessary after the layout builds
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollListener();
    });
  }

  void _scrollListener() {
    if (!_sheetScrollController.hasClients) return;

    final maxScroll = _sheetScrollController.position.maxScrollExtent;
    final currentScroll = _sheetScrollController.offset;

    // If the content is short enough that it doesn't scroll, hide indicator
    if (maxScroll <= 0) {
      if (_showScrollIndicator) setState(() => _showScrollIndicator = false);
      return;
    }

    // If we are within 10 pixels of the bottom, hide the indicator
    final isAtBottom = currentScroll >= (maxScroll - 10);

    if (_showScrollIndicator == isAtBottom) {
      setState(() {
        _showScrollIndicator = !isAtBottom;
      });
    }
  }

  @override
  void dispose() {
    _sheetScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final passed = widget.steps
        .where((s) => s.state == _StepState.passed)
        .length;
    final warned = widget.steps
        .where((s) => s.state == _StepState.warning)
        .length;

    final maxHeight = MediaQuery.of(context).size.height * 0.85;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Fixed Header (Drag Handle)
            const SizedBox(height: 16),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // 2. Flexible Scrollable Content WITH Indicator Overlay
            Flexible(
              child: Stack(
                children: [
                  SingleChildScrollView(
                    controller: _sheetScrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Big checkmark header
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1FBF5),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFFA8D5B5)),
                          ),
                          child: Column(
                            children: [
                              Container(
                                width: 56,
                                height: 56,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF2E7D32),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.verified_user_rounded,
                                  color: Colors.white,
                                  size: 28,
                                ),
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                "Registration Complete",
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1A1A2E),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                "Welcome, ${widget.profile.username}",
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                              const SizedBox(height: 12),
                              // Stats row
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _StatChip(
                                    label: "$passed Passed",
                                    color: const Color(0xFF2E7D32),
                                    bg: const Color(0xFFDCEFE1),
                                  ),
                                  if (warned > 0) ...[
                                    const SizedBox(width: 8),
                                    _StatChip(
                                      label: "$warned Warning",
                                      color: const Color(0xFFE65100),
                                      bg: const Color(0xFFFFE0B2),
                                    ),
                                  ],
                                  const SizedBox(width: 8),
                                  _StatChip(
                                    label: "${widget.steps.length} Total",
                                    color: Colors.grey.shade600,
                                    bg: const Color(0xFFE9ECEF),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Security summary heading
                        const Text(
                          "Security Setup Summary",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                        const SizedBox(height: 10),

                        // Compact step summary list
                        ...widget.steps.map((s) => _SummaryRow(step: s)),

                        const SizedBox(height: 20),

                        // Divider + info text
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF5F6FA),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                size: 16,
                                color: Colors.grey.shade500,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  "This device is now cryptographically bound to your account. Future logins will be verified using your hardware key.",
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),

                  // ✅ NEW: The smart scroll indicator overlay
                  if (_showScrollIndicator)
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: IgnorePointer(
                        // Lets the user scroll right through the shadow
                        child: Container(
                          height: 60,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.white.withOpacity(0.0),
                                Colors.white,
                              ],
                            ),
                          ),
                          alignment: Alignment.bottomCenter,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  "Scroll for details",
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade500,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  size: 16,
                                  color: Colors.grey.shade500,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // 3. Fixed Footer (Proceed Button)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
              child: SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: widget.onProceed,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A1A2E),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.arrow_forward_rounded, size: 18),
                      SizedBox(width: 8),
                      Text(
                        "Proceed to Dashboard",
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Summary row inside the bottom sheet ──────────────────────────────────────

class _SummaryRow extends StatelessWidget {
  final _SecurityStep step;
  const _SummaryRow({required this.step});

  @override
  Widget build(BuildContext context) {
    Color iconColor;
    IconData icon;
    switch (step.state) {
      case _StepState.passed:
        iconColor = const Color(0xFF2E7D32);
        icon = Icons.check_circle_outline;
        break;
      case _StepState.warning:
        iconColor = const Color(0xFFE65100);
        icon = Icons.warning_amber_rounded;
        break;
      case _StepState.failed:
        iconColor = const Color(0xFFC62828);
        icon = Icons.cancel_outlined;
        break;
      default:
        iconColor = Colors.grey.shade400;
        icon = Icons.radio_button_unchecked;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                if (step.detail != null)
                  Text(
                    step.detail!,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Stat chip in the bottom sheet header ─────────────────────────────────────

class _StatChip extends StatelessWidget {
  final String label;
  final Color color, bg;
  const _StatChip({required this.label, required this.color, required this.bg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
