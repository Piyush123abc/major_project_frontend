import 'package:attendance_app/permissions.dart';
import 'package:attendance_app/student_app/student_homepage.dart';
import 'package:attendance_app/teacher_app/teachers_homepage.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'global_variable/base_url.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _urlController = TextEditingController();
  String _statusMessage = "Connecting to server...";

  // App State Variables for Permission Blocking
  bool _isCheckingPermissions = true;
  bool _permissionsGranted = false;

  bool _isConnected = false;
  bool _isLoading = true; // Tracks the initial auto-connection attempt
  bool _showManualInput = false; // Controls whether to show the text field

  // 🌐 Future deployed URL goes here.
  // (Leave it as a dummy URL for now so it deliberately fails and shows the manual input)
  final String _deployedUrl =
      "https://intershifting-heterogonously-angella.ngrok-free.dev/";

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  // Combines your original startup checks into a strict sequence
  Future<void> _initializeApp() async {
    // Ask for permissions at startup
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool granted = await AppPermissions.requestAllPermissions(context);

      if (mounted) {
        setState(() {
          _permissionsGranted = granted;
          _isCheckingPermissions = false;
        });

        if (!granted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                "⚠️ Some permissions were not granted. App may not work properly.",
              ),
              duration: Duration(seconds: 3),
            ),
          );
        } else {
          // Attempt to connect to the deployed backend automatically
          _autoConnect();
        }
      }
    });
  }

  // ✅ Automatically tries the default URL first
  Future<void> _autoConnect() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Added a timeout so the app doesn't hang forever if the URL is unreachable
      final response = await http
          .get(Uri.parse(_deployedUrl))
          .timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        setState(() {
          _isConnected = true;
          _isLoading = false;
          _showManualInput = false;
          _statusMessage = "✅ Connected to deployed server automatically!";
        });
        BaseUrl.value = _deployedUrl; // Save globally
      } else {
        _fallbackToManualInput("Server returned ${response.statusCode}");
      }
    } catch (e) {
      _fallbackToManualInput("Could not reach deployed server.");
    }
  }

  // ✅ Triggers if auto-connect fails
  void _fallbackToManualInput(String reason) {
    setState(() {
      _isLoading = false;
      _showManualInput = true;
      _isConnected = false;
      _urlController.text = "http://192.168.29.146:8000/"; // Default local IP
      _statusMessage = "⚠️ $reason\nPlease enter URL manually.";
    });
  }

  // ✅ The original manual check
  Future<void> _checkBackend() async {
    final baseUrl = _urlController.text.trim();

    if (baseUrl.isEmpty) {
      setState(() {
        _statusMessage = "❌ Please enter a base URL.";
      });
      return;
    }

    if (baseUrl.toLowerCase() == "test") {
      setState(() {
        _isConnected = true;
        _showManualInput = false; // Hide input after success
        _statusMessage =
            "🧪 Test mode: Connected!\nBackend says: This is testing.";
      });
      BaseUrl.value = baseUrl;
      return;
    }

    // Show loading spinner for manual attempt
    setState(() {
      _isLoading = true;
      _statusMessage = "Checking manual URL...";
    });

    try {
      final response = await http
          .get(Uri.parse(baseUrl))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        setState(() {
          _isConnected = true;
          _showManualInput = false; // Hide input on success
          _statusMessage =
              "✅ Connected successfully!\nBackend says: ${response.body}";
        });
        BaseUrl.value = baseUrl;
      } else {
        setState(() {
          _isConnected = false;
          _statusMessage =
              "⚠️ Failed to connect. Status code: ${response.statusCode}";
        });
      }
    } catch (e) {
      setState(() {
        _isConnected = false;
        _statusMessage = "❌ Error: Could not connect to $baseUrl";
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _goToTeacherApp() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const TeachersHomePage()),
    );
  }

  void _goToStudentApp() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const StudentHomePage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Smart Attendance - Home")),
      body: Padding(
        padding: const EdgeInsets.all(20.0),

        // 1. Initial Permission Check State
        child: _isCheckingPermissions
            ? const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 20),
                    Text("Checking app permissions..."),
                  ],
                ),
              )
            // 2. Strict Blocking State if Permissions are Denied
            : !_permissionsGranted
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.security_update_warning,
                      size: 60,
                      color: Colors.orange,
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      "Permissions Required",
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      "This app requires Bluetooth, Location, and Camera permissions to function properly. Please grant them to continue.",
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 30),
                    ElevatedButton(
                      onPressed: _initializeApp,
                      child: const Text("Grant Permissions"),
                    ),
                  ],
                ),
              )
            // 3. Normal App Content (Only accessible if permissions granted)
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 🔄 Loading State
                  if (_isLoading) ...[
                    const CircularProgressIndicator(),
                    const SizedBox(height: 20),
                  ],

                  // ✍️ Manual Input State
                  if (_showManualInput) ...[
                    TextField(
                      controller: _urlController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: "Enter Backend Base URL",
                        hintText: "http://192.168.x.x:8000/   OR   test",
                      ),
                    ),
                    const SizedBox(height: 15),
                    ElevatedButton(
                      onPressed: _isLoading ? null : _checkBackend,
                      child: const Text("Connect Backend"),
                    ),
                    const SizedBox(height: 20),
                  ],

                  // ℹ️ Status Message
                  Text(
                    _statusMessage,
                    style: const TextStyle(fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 30),

                  // ✅ Connected State (Show App Options)
                  if (_isConnected) ...[
                    ElevatedButton.icon(
                      onPressed: _goToTeacherApp,
                      icon: const Icon(Icons.school),
                      label: const Text("Teacher App"),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                      ),
                    ),
                    const SizedBox(height: 15),
                    ElevatedButton.icon(
                      onPressed: _goToStudentApp,
                      icon: const Icon(Icons.person),
                      label: const Text("Student App"),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                      ),
                    ),
                    const SizedBox(height: 30),

                    // A fallback option in case you want to test locally while production is up
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _isConnected = false;
                          _showManualInput = true;
                          _urlController.text = "http://10.10.124.249:8000/";
                          _statusMessage = "Switched to manual configuration.";
                        });
                      },
                      icon: const Icon(Icons.settings),
                      label: const Text("Connect Manually (Debug)"),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}
