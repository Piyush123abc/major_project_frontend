import 'dart:convert';
import 'package:attendance_app/global_variable/base_url.dart';
import 'package:attendance_app/global_variable/token_handles.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class ExceptionListPage extends StatefulWidget {
  final int classroomId;
  const ExceptionListPage({super.key, required this.classroomId});

  @override
  State<ExceptionListPage> createState() => _ExceptionListPageState();
}

class _ExceptionListPageState extends State<ExceptionListPage>
    with TickerProviderStateMixin {
  List<Map<String, dynamic>> exceptionList = [];
  final Set<String> markedPresent = <String>{};
  bool loading = true;
  bool submitting = false;

  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  // ─── Design tokens ────────────────────────────────────────────────────────
  static const Color _bg = Color(0xFF0F1117);
  static const Color _surface = Color(0xFF1A1D27);
  static const Color _card = Color(0xFF22253A);
  static const Color _accent = Color(0xFF6C63FF);
  static const Color _accentLight = Color(0xFF8B85FF);
  static const Color _green = Color(0xFF2ECC71);
  static const Color _red = Color(0xFFE74C3C);
  static const Color _textPrimary = Color(0xFFF0F0FF);
  static const Color _textSecondary = Color(0xFF8A8DB3);
  static const Color _divider = Color(0xFF2E3150);

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    fetchExceptionList();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  // ─── Original logic (untouched) ───────────────────────────────────────────

  Future<http.Response?> _authorizedGet(Uri url) async {
    var res = await http.get(url, headers: await TokenHandles.getAuthHeaders());
    if (res.statusCode == 401 && await TokenHandles.refreshAccessToken()) {
      res = await http.get(url, headers: await TokenHandles.getAuthHeaders());
    }
    return res;
  }

  Future<http.Response?> _authorizedPost(Uri url, Object body) async {
    var headers = {
      ...await TokenHandles.getAuthHeaders(),
      "Content-Type": "application/json",
    };
    var res = await http.post(url, headers: headers, body: jsonEncode(body));
    if (res.statusCode == 401 && await TokenHandles.refreshAccessToken()) {
      headers = {
        ...await TokenHandles.getAuthHeaders(),
        "Content-Type": "application/json",
      };
      res = await http.post(url, headers: headers, body: jsonEncode(body));
    }
    return res;
  }

  Future<void> fetchExceptionList() async {
    setState(() => loading = true);

    final url = Uri.parse(
      "${BaseUrl.value}/session/teacher/classroom/${widget.classroomId}/exceptions/",
    );

    try {
      final res = await _authorizedGet(url);
      if (res == null) {
        _showError("No response from server.");
        setState(() => loading = false);
        return;
      }

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final list =
            (data["exception_list"] as List<dynamic>?)
                ?.cast<Map<String, dynamic>>() ??
            <Map<String, dynamic>>[];
        setState(() {
          exceptionList = List<Map<String, dynamic>>.from(list);
          loading = false;
        });
        _fadeController.forward();
      } else {
        String msg = "Failed to load exception list";
        try {
          final d = jsonDecode(res.body);
          msg = d["error"] ?? d["message"] ?? msg;
        } catch (_) {}
        _showError(msg);
        setState(() => loading = false);
      }
    } catch (e) {
      setState(() => loading = false);
      _showError("Network error: $e");
    }
  }

  Future<void> submitPresent() async {
    if (markedPresent.isEmpty) {
      _showError("No students marked present.");
      return;
    }

    setState(() => submitting = true);

    final url = Uri.parse(
      "${BaseUrl.value}/session/teacher/classroom/${widget.classroomId}/mark-present/",
    );

    try {
      final res = await _authorizedPost(url, {
        "present_uids": markedPresent.toList(),
      });
      setState(() => submitting = false);

      if (res == null) {
        _showError("No response from server.");
        return;
      }

      if (res.statusCode == 200) {
        String msg = "Students marked present.";
        try {
          final d = jsonDecode(res.body);
          msg = d["message"] ?? msg;
        } catch (_) {}
        _showSuccess(msg);
      } else {
        String msg = "Failed to mark present.";
        try {
          final d = jsonDecode(res.body);
          msg = d["error"] ?? d["message"] ?? msg;
        } catch (_) {}
        _showError(msg);
      }
    } catch (e) {
      setState(() => submitting = false);
      _showError("Network error: $e");
    }
  }

  // ─── Dialogs ──────────────────────────────────────────────────────────────

  void _showError(String msg) {
    showDialog(
      context: context,
      builder: (_) => _StyledDialog(
        icon: Icons.error_outline_rounded,
        iconColor: _red,
        title: "Error",
        message: msg,
        onOk: () => Navigator.pop(context),
      ),
    );
  }

  void _showSuccess(String msg) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _StyledDialog(
        icon: Icons.check_circle_outline_rounded,
        iconColor: _green,
        title: "Success",
        message: msg,
        onOk: () {
          Navigator.pop(context);
          Navigator.pop(context, true);
        },
      ),
    );
  }

  // ─── Student card ─────────────────────────────────────────────────────────

  Widget _studentCard(Map<String, dynamic> student, int index) {
    final uid = student["uid"]?.toString() ?? "";
    final username = student["username"]?.toString() ?? "Unknown";
    final isMarked = markedPresent.contains(uid);

    // Staggered entry animation
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position:
            Tween<Offset>(
              begin: Offset(0, 0.08 * (index + 1)),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(
                parent: _fadeController,
                curve: Interval(
                  (index * 0.07).clamp(0.0, 0.6),
                  ((index * 0.07) + 0.4).clamp(0.0, 1.0),
                  curve: Curves.easeOut,
                ),
              ),
            ),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isMarked ? _green.withOpacity(0.45) : _divider,
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: isMarked
                    ? _green.withOpacity(0.08)
                    : Colors.black.withOpacity(0.25),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                // Avatar
                Stack(
                  children: [
                    Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [
                            _accent.withOpacity(0.7),
                            _accentLight.withOpacity(0.4),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: const Icon(
                        Icons.person_rounded,
                        color: Colors.white70,
                        size: 28,
                      ),
                    ),
                    if (isMarked)
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: _green,
                            shape: BoxShape.circle,
                            border: Border.all(color: _card, width: 2),
                          ),
                          child: const Icon(
                            Icons.check,
                            size: 9,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),

                const SizedBox(width: 14),

                // Name + UID
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        username,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: _textPrimary,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          const Icon(
                            Icons.fingerprint_rounded,
                            size: 13,
                            color: _textSecondary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            uid,
                            style: const TextStyle(
                              fontSize: 12,
                              color: _textSecondary,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Toggle buttons
                _AttendanceToggle(
                  isMarked: isMarked,
                  onPresent: () => setState(() => markedPresent.add(uid)),
                  onAbsent: () => setState(() => markedPresent.remove(uid)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final presentCount = markedPresent.length;
    final totalCount = exceptionList.length;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
        elevation: 0,
        centerTitle: false,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: _textPrimary,
            size: 20,
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          "Exception List",
          style: TextStyle(
            color: _textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: _divider),
        ),
        actions: [
          if (!loading && totalCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: _CountBadge(present: presentCount, total: totalCount),
            ),
        ],
      ),
      body: loading
          ? _buildLoader()
          : exceptionList.isEmpty
          ? _buildEmpty()
          : _buildList(),
      bottomNavigationBar: (!loading && exceptionList.isNotEmpty)
          ? _buildSubmitBar(presentCount, totalCount)
          : null,
    );
  }

  Widget _buildLoader() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              valueColor: const AlwaysStoppedAnimation<Color>(_accent),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            "Loading exceptions…",
            style: TextStyle(color: _textSecondary, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_outline_rounded,
            size: 64,
            color: _green.withOpacity(0.6),
          ),
          const SizedBox(height: 16),
          const Text(
            "No exceptions today",
            style: TextStyle(
              color: _textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            "All students are accounted for.",
            style: TextStyle(color: _textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 12, bottom: 100),
        itemCount: exceptionList.length,
        itemBuilder: (context, index) =>
            _studentCard(exceptionList[index], index),
      ),
    );
  }

  Widget _buildSubmitBar(int presentCount, int totalCount) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      decoration: BoxDecoration(
        color: _surface,
        border: Border(top: BorderSide(color: _divider)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: submitting ? null : submitPresent,
            style: ElevatedButton.styleFrom(
              backgroundColor: _accent,
              disabledBackgroundColor: _accent.withOpacity(0.4),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: submitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.check_rounded, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        presentCount > 0
                            ? "Submit  ·  $presentCount / $totalCount Present"
                            : "Submit Present",
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
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

// ─── Reusable widgets ─────────────────────────────────────────────────────────

class _AttendanceToggle extends StatelessWidget {
  final bool isMarked;
  final VoidCallback onPresent;
  final VoidCallback onAbsent;

  static const Color _green = Color(0xFF2ECC71);
  static const Color _red = Color(0xFFE74C3C);
  static const Color _surface = Color(0xFF2A2D40);

  const _AttendanceToggle({
    required this.isMarked,
    required this.onPresent,
    required this.onAbsent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToggleBtn(
            label: "P",
            active: isMarked,
            activeColor: _green,
            onTap: onPresent,
            isLeft: true,
          ),
          _ToggleBtn(
            label: "A",
            active: !isMarked,
            activeColor: _red,
            onTap: onAbsent,
            isLeft: false,
          ),
        ],
      ),
    );
  }
}

class _ToggleBtn extends StatelessWidget {
  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;
  final bool isLeft;

  const _ToggleBtn({
    required this.label,
    required this.active,
    required this.activeColor,
    required this.onTap,
    required this.isLeft,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        width: 38,
        height: 36,
        decoration: BoxDecoration(
          color: active ? activeColor : Colors.transparent,
          borderRadius: BorderRadius.horizontal(
            left: isLeft ? const Radius.circular(10) : Radius.zero,
            right: !isLeft ? const Radius.circular(10) : Radius.zero,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : const Color(0xFF6A6D8A),
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  final int present;
  final int total;

  static const Color _accent = Color(0xFF6C63FF);

  const _CountBadge({required this.present, required this.total});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: _accent.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _accent.withOpacity(0.4)),
      ),
      child: Text(
        "$present / $total",
        style: const TextStyle(
          color: _accent,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _StyledDialog extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String message;
  final VoidCallback onOk;

  static const Color _bg = Color(0xFF1A1D27);
  static const Color _textPrimary = Color(0xFFF0F0FF);
  static const Color _textSecondary = Color(0xFF8A8DB3);
  static const Color _accent = Color(0xFF6C63FF);
  static const Color _divider = Color(0xFF2E3150);

  const _StyledDialog({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.message,
    required this.onOk,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 30),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                color: _textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _textSecondary,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            Divider(color: _divider, height: 1),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton(
                onPressed: onOk,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  "OK",
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
