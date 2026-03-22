import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:encrypt/encrypt.dart' as enc;
import 'package:http/http.dart' as http;

import 'package:attendance_app/global_variable/base_url.dart';
import 'package:attendance_app/global_variable/token_handles.dart';
import 'package:attendance_app/global_variable/teacher_profile.dart';
import 'package:attendance_app/global_variable/session_data_manager.dart';

class TeacherSecureHostPage extends StatefulWidget {
  final int classroomId;

  const TeacherSecureHostPage({super.key, required this.classroomId});

  @override
  State<TeacherSecureHostPage> createState() => _TeacherSecureHostPageState();
}

class _TeacherSecureHostPageState extends State<TeacherSecureHostPage> {
  static const MethodChannel _methodChannel = MethodChannel(
    'com.attendance/command',
  );
  static const EventChannel _eventChannel = EventChannel(
    'com.attendance/events',
  );

  StreamSubscription? _eventSubscription;
  final List<String> _terminalLogs = [];

  late String _teacherUid;
  late String _bleServiceUuid;

  bool _isBroadcasting = false;
  bool _isLoadingKeys =
      true; // Added to prevent broadcasting before keys arrive

  @override
  void initState() {
    super.initState();

    // 1. Pull the TEACHER'S UID from the GlobalStore
    _teacherUid = GlobalStore.teacherUid;
    _bleServiceUuid = _formatUidToBleUuid(_teacherUid);

    _eventSubscription = _eventChannel.receiveBroadcastStream().listen((event) {
      final payload = event.toString();

      if (payload.startsWith("FATAL:HARDWARE:")) {
        if (mounted) setState(() => _isBroadcasting = false);
        _addLog(
          payload.replaceAll("FATAL:HARDWARE:", "HW ERROR:"),
          isError: true,
        );
      } else if (payload.startsWith("LOG:")) {
        if (mounted) setState(() => _isBroadcasting = true);
        _addLog(payload.replaceAll("LOG:", "SYS:"));
      } else if (payload.startsWith("ACK:")) {
        HapticFeedback.lightImpact();
      } else if (payload.startsWith("CHALLENGE:")) {
        final parts = payload.split(":");
        if (parts.length >= 8) {
          String macAddress = parts.sublist(1, 7).join(":");
          String hexPayload = parts.last;

          _addLog("AUTH: Challenge from $macAddress");
          _handleIncomingChallenge(
            macAddress: macAddress,
            hexPayload: hexPayload,
          );
        }
      }
    });

    // 2. Fetch keys first, then start the server
    _initializeHost();
  }

  // --- NEW: FETCH KEYS FROM DJANGO ---
  Future<void> _initializeHost() async {
    await _fetchTeacherKeys();
    if (!_isLoadingKeys) {
      _startServer();
    }
  }

  Future<void> _fetchTeacherKeys() async {
    _addLog("SYS: Fetching Teacher Session Keys...");
    try {
      final headers = await TokenHandles.getAuthHeaders();
      String rawBase = BaseUrl.value.endsWith('/')
          ? BaseUrl.value.substring(0, BaseUrl.value.length - 1)
          : BaseUrl.value;

      final url = Uri.parse(
        "$rawBase/session/teacher/classroom/${widget.classroomId}/credentials/",
      );
      final response = await http.get(url, headers: headers);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        SessionDataManager.instance.saveCredentials(
          classroomId: widget.classroomId.toString(),
          kClass: data['k_class'],
          sessionSeed: data['session_seed'] ?? "TEACHER_SEED",
          nodeId: data['node_id'].toString(), // This will be '0' from Django
        );

        _addLog("SYS: Keys acquired. Node ID: ${data['node_id']}");
        if (mounted) {
          setState(() {
            _isLoadingKeys = false;
          });
        }
      } else {
        _addLog(
          "SYS ERR: Failed to fetch keys. Code: ${response.statusCode}",
          isError: true,
        );
      }
    } catch (e) {
      _addLog("SYS ERR: Network error fetching keys.", isError: true);
    }
  }
  // -----------------------------------

  void _addLog(String msg, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      String prefix = isError ? "🔴 " : "🟢 ";
      String time = DateTime.now()
          .toIso8601String()
          .split('T')[1]
          .substring(0, 8);
      _terminalLogs.insert(0, "$prefix[$time] $msg");
    });
  }

  void _handleIncomingChallenge({
    required String macAddress,
    required String hexPayload,
  }) {
    try {
      final creds = SessionDataManager.instance.getCredentials(
        widget.classroomId.toString(),
      );
      if (creds == null) {
        _addLog("CRYPTO ERR: No session keys found.", isError: true);
        return;
      }

      final key = enc.Key.fromBase16(creds.kClass);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.ecb));

      final encryptedBytes = _hexToBytes(hexPayload);
      final decryptedBytes = encrypter.decryptBytes(
        enc.Encrypted(Uint8List.fromList(encryptedBytes)),
      );

      List<int> newPayload = decryptedBytes.sublist(0, 14);
      int myNodeId = int.parse(creds.nodeId); // Parses "0" perfectly!

      newPayload.add((myNodeId >> 8) & 0xFF);
      newPayload.add(myNodeId & 0xFF);

      final newEncrypted = encrypter.encryptBytes(newPayload);
      final hexResponse = _bytesToHex(newEncrypted.bytes.toList());

      _methodChannel.invokeMethod('sendEcho', {
        'address': macAddress,
        'payload': hexResponse,
      });

      HapticFeedback.heavyImpact();
      _addLog("AUTH: Identity stamped & echoed!");
    } catch (e) {
      _addLog("CRYPTO ERR: Decryption failed.", isError: true);
    }
  }

  List<int> _hexToBytes(String hex) {
    List<int> bytes = [];
    for (int i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  String _bytesToHex(List<int> bytes) {
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join('')
        .toUpperCase();
  }

  String _formatUidToBleUuid(String uid) {
    String hex = uid.codeUnits
        .map((c) => c.toRadixString(16).padLeft(2, '0'))
        .join('');
    hex = hex.padRight(32, '0');
    if (hex.length > 32) hex = hex.substring(0, 32);
    return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}";
  }

  Future<void> _startServer() async {
    try {
      _addLog("SYS: Starting BLE Server...");
      await _methodChannel.invokeMethod('startServer', {
        'useForegroundService': false,
        'advMode': 'LOW_LATENCY',
        'uuid': _bleServiceUuid,
      });
    } catch (e) {
      _addLog("SYS ERR: Bridge failed.", isError: true);
    }
  }

  Future<void> _stopServer() async {
    try {
      await _methodChannel.invokeMethod('stopServer');
      _addLog("SYS: Server stopped.");
    } catch (e) {}
  }

  @override
  void dispose() {
    _stopServer();
    _eventSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "TEACHER HOST",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  Icon(
                    Icons.circle,
                    size: 14,
                    color: _isBroadcasting
                        ? Colors.greenAccent
                        : Colors.redAccent,
                  ),
                ],
              ),
              const Expanded(flex: 3, child: SizedBox()),
              Text(
                "ID: $_teacherUid",
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: Colors.cyanAccent,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                "Have a student scan this to begin the chain",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.white60),
              ),
              const SizedBox(height: 20),

              // Only show QR code if keys have been fetched successfully
              Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: _isLoadingKeys
                      ? const SizedBox(
                          width: 220,
                          height: 220,
                          child: Center(
                            child: CircularProgressIndicator(
                              color: Colors.teal,
                            ),
                          ),
                        )
                      : bw.BarcodeWidget(
                          barcode: bw.Barcode.qrCode(),
                          data: _bleServiceUuid,
                          width: 220,
                          height: 220,
                          color: Colors.black,
                        ),
                ),
              ),
              const Expanded(flex: 4, child: SizedBox()),
              SizedBox(
                height: 60,
                child: ElevatedButton.icon(
                  onPressed: () {
                    HapticFeedback.heavyImpact();
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.stop_circle_outlined, size: 28),
                  label: const Text(
                    "STOP & EXIT",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent.shade700,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                height: 120,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF111111),
                  border: Border.all(color: Colors.grey.shade900),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "SYS LOGS",
                      style: TextStyle(
                        color: Colors.grey,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _terminalLogs.length,
                        itemBuilder: (context, index) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 4.0),
                            child: Text(
                              _terminalLogs[index],
                              style: TextStyle(
                                color: _terminalLogs[index].startsWith("🔴")
                                    ? Colors.redAccent
                                    : Colors.greenAccent,
                                fontSize: 11,
                                fontFamily: 'monospace',
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
