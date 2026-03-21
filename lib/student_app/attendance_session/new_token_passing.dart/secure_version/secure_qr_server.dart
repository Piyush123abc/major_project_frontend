import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:encrypt/encrypt.dart' as enc;

import 'package:attendance_app/global_variable/student_profile.dart';
import 'package:attendance_app/global_variable/session_data_manager.dart';

class SecureProximityHostPage extends StatefulWidget {
  final int classroomId;

  const SecureProximityHostPage({super.key, required this.classroomId});

  @override
  State<SecureProximityHostPage> createState() =>
      _SecureProximityHostPageState();
}

class _SecureProximityHostPageState extends State<SecureProximityHostPage> {
  static const MethodChannel _methodChannel = MethodChannel(
    'com.attendance/command',
  );
  static const EventChannel _eventChannel = EventChannel(
    'com.attendance/events',
  );

  StreamSubscription? _eventSubscription;
  final List<String> _terminalLogs = [];

  late String _studentUid;
  late String _bleServiceUuid;

  bool _isBroadcasting = false;

  @override
  void initState() {
    super.initState();

    _studentUid = GlobalStudentProfile.currentStudent?.uid ?? "UNKNOWN_UID";
    _bleServiceUuid = _formatUidToBleUuid(_studentUid);

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
        if (parts.length == 3) {
          _addLog("AUTH: Incoming challenge from ${parts[1]}");
          _handleIncomingChallenge(macAddress: parts[1], hexPayload: parts[2]);
        }
      }
    });

    _startServer();
  }

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

  // --- CRYPTOGRAPHY ---
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
      int myNodeId = int.parse(creds.nodeId);
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

  // --- HELPERS ---
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

  // --- NATIVE BRIDGE ---
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
    } catch (e) {
      debugPrint("Failed to stop server: $e");
    }
  }

  @override
  void dispose() {
    _stopServer();
    _eventSubscription?.cancel();
    super.dispose();
  }

  // --- UI BUILDER ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black, // Pure black background
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // HEADER & STATUS DOT
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "HOST SYNC",
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

              // FLEXIBLE SPACE TO PUSH QR DOWN
              const Expanded(flex: 3, child: SizedBox()),

              // NEAT STUDENT ID & INSTRUCTION
              Text(
                "ID: $_studentUid",
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
                "Have a classmate scan this to connect",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.white60),
              ),
              const SizedBox(height: 20),

              // QR CODE DISPLAY
              Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: bw.BarcodeWidget(
                    barcode: bw.Barcode.qrCode(),
                    data: _bleServiceUuid,
                    width: 220,
                    height: 220,
                    color: Colors.black,
                  ),
                ),
              ),

              // FLEXIBLE SPACE TO PUSH BUTTON TO BOTTOM
              const Expanded(flex: 4, child: SizedBox()),

              // MASSIVE RED STOP BUTTON
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

              // SMALL SYSTEM LOGS TERMINAL
              Container(
                height: 120, // Strict, small height
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
