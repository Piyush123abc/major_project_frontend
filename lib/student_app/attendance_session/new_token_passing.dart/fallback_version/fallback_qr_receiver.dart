import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:attendance_app/global_variable/base_url.dart';
import 'package:attendance_app/global_variable/session_data_manager.dart';
import 'package:attendance_app/global_variable/token_handles.dart';
import 'package:attendance_app/global_variable/fallback_counter.dart';
import 'package:flutter/material.dart';
import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;

class FallbackQrReceiverPage extends StatefulWidget {
  final String ownUid;
  final int classroomId;

  const FallbackQrReceiverPage({
    super.key,
    required this.ownUid,
    required this.classroomId,
  });

  @override
  State<FallbackQrReceiverPage> createState() => _FallbackQrReceiverPageState();
}

class _FallbackQrReceiverPageState extends State<FallbackQrReceiverPage> {
  static const int rssiThreshold = -75;

  bool _isScanning = false;
  bool _isResultScreen = false;
  String? _verifiedPeerUid;

  bool _isRefreshing = false;

  // Diagnostic State Variables
  int? _lastRssi;
  String? _lastRawPayload;
  String? _lastDecryptedId;
  bool _isBackendRejected = false;

  StreamSubscription? _scanSubscription;
  String _currentTargetUuid = '';

  @override
  void initState() {
    super.initState();
    _initializeReceiver();
  }

  Future<void> _initializeReceiver() async {
    if (Platform.isAndroid) {
      try {
        var state = await FlutterBluePlus.adapterState.first;
        if (state != BluetoothAdapterState.on) {
          await FlutterBluePlus.turnOn();
          await Future.delayed(const Duration(seconds: 1));
        }
      } catch (e) {
        debugPrint("Could not turn on BT: $e");
      }
    }

    _currentTargetUuid = getCurrentUuid();
    _startBleScanning();
  }

  // ---------------- Core Logic ----------------

  String getCurrentUuid() {
    final creds = SessionDataManager.instance.getCredentials(
      widget.classroomId.toString(),
    );
    final String idToUse = creds?.nodeId ?? "0000";
    final raw = "$idToUse${FallbackCounter.scanIndex}";

    String clean = raw.padRight(32, '0');
    if (clean.length > 32) clean = clean.substring(0, 32);

    return "${clean.substring(0, 8)}-"
        "${clean.substring(8, 12)}-"
        "${clean.substring(12, 16)}-"
        "${clean.substring(16, 20)}-"
        "${clean.substring(20)}";
  }

  String formatUuid(String input) {
    return input.trim().replaceAll('-', '').toLowerCase();
  }

  String decryptPayload(List<int> encryptedBytes) {
    try {
      final creds = SessionDataManager.instance.getCredentials(
        widget.classroomId.toString(),
      );
      if (creds == null) return "";

      final key = enc.Key.fromBase16(creds.kClass);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.ecb));

      final encryptedData = enc.Encrypted(Uint8List.fromList(encryptedBytes));
      final decryptedString = encrypter.decrypt(encryptedData);

      return decryptedString;
    } catch (e) {
      return "";
    }
  }

  // ---------------- BLE Scanning ----------------
  Future<void> _startBleScanning() async {
    if (_isScanning) return;

    await _scanSubscription?.cancel();
    String targetToHunt = formatUuid(_currentTargetUuid);

    setState(() {
      _isScanning = true;
      _isResultScreen = false;
      _isBackendRejected = false;
      _verifiedPeerUid = null;
      _lastRssi = null;
      _lastRawPayload = null;
      _lastDecryptedId = null;
    });

    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      if (results.isEmpty) return;

      for (var result in results) {
        try {
          int rssi = result.rssi;

          List<String> scannedUuids = result.advertisementData.serviceUuids
              .map((u) => u.toString().replaceAll('-', '').toLowerCase())
              .toList();

          if (scannedUuids.contains(targetToHunt) && rssi >= rssiThreshold) {
            if (result.advertisementData.manufacturerData.isNotEmpty) {
              List<int> bytes =
                  result.advertisementData.manufacturerData.values.first;

              String decryptedUid = decryptPayload(bytes);

              if (decryptedUid.isNotEmpty) {
                _stopBleScanning();

                setState(() {
                  _lastRssi = rssi;
                  _lastRawPayload = bytes
                      .map((b) => b.toRadixString(16).padLeft(2, '0'))
                      .join(' ')
                      .toUpperCase();
                  _lastDecryptedId = decryptedUid;
                  _isResultScreen = true;
                });

                // Send the Decrypted ID (The Temporary Counter) to Django
                _callPassToken(peerTempId: decryptedUid);
                break;
              }
            }
          }
        } catch (_) {}
      }
    });

    FlutterBluePlus.startScan(
      withServices: [],
      androidScanMode: AndroidScanMode.lowLatency,
      continuousUpdates: true,
    );
  }

  Future<void> _stopBleScanning() async {
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    setState(() => _isScanning = false);
  }

  // ---------------- Backend API ----------------
  Future<void> _callPassToken({required String peerTempId}) async {
    try {
      final headers = await TokenHandles.getAuthHeaders();

      String rawBase = BaseUrl.value;
      if (rawBase.endsWith('/')) {
        rawBase = rawBase.substring(0, rawBase.length - 1);
      }
      final url = Uri.parse(
        "$rawBase/session/student/classroom/${widget.classroomId}/pass-token/",
      );

      // THE FIX: We put our Permanent UID in 'from' and the Peer's Temporary ID in 'to'
      // This allows Django's "Smart Resolution" to translate the peer's ID perfectly.
      final response = await http.post(
        url,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode({
          "from_uid": widget.ownUid, // Our Permanent UID
          "to_uid": peerTempId, // Their Temporary Node ID
        }),
      );

      final body = jsonDecode(response.body);

      if (response.statusCode == 200) {
        if (mounted) {
          setState(() {
            _verifiedPeerUid = body["verified_with"] ?? "Student";
            _isBackendRejected = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("✅ Attendance Verified!"),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        if (mounted) {
          setState(() {
            _verifiedPeerUid = body["error"] ?? "Invalid Token";
            _isBackendRejected = true;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("❌ ${body["error"] ?? "Failed"}"),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _verifiedPeerUid = "Network Error";
          _isBackendRejected = true;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("❌ Error: $e")));
      }
    }
  }

  // ---------------- UI Actions ----------------
  void _scanAnother() {
    FallbackCounter.scanIndex++;
    _currentTargetUuid = getCurrentUuid();
    _startBleScanning();
  }

  Future<void> _manualRefresh() async {
    if (_isRefreshing) return;

    setState(() {
      _isRefreshing = true;
    });

    await _stopBleScanning();
    await Future.delayed(const Duration(seconds: 1));

    FallbackCounter.scanIndex++;
    setState(() {
      _currentTargetUuid = getCurrentUuid();
      _isRefreshing = false;
    });

    _startBleScanning();
  }

  @override
  void dispose() {
    _stopBleScanning();
    if (Platform.isAndroid) {
      try {
        FlutterBluePlus.turnOff();
      } catch (_) {}
    }
    super.dispose();
  }

  // ---------------- Build UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Show My QR (Receiver)"),
        backgroundColor: Colors.teal,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: _isResultScreen ? _buildResultScreen() : _buildQrScreen(),
        ),
      ),
    );
  }

  /// UI STATE 1: Waiting for a scan (Shows QR Code)
  Widget _buildQrScreen() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(height: 20),
        const Text(
          "Present this QR to a classmate.",
          style: TextStyle(fontSize: 16, color: Colors.grey),
        ),
        const SizedBox(height: 30),

        Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: _isRefreshing ? 0.3 : 1.0,
              child: bw.BarcodeWidget(
                barcode: bw.Barcode.qrCode(),
                data: _currentTargetUuid,
                width: 240,
                height: 240,
                color: Colors.black,
              ),
            ),
            if (_isRefreshing)
              const CircularProgressIndicator(
                color: Colors.teal,
                strokeWidth: 4,
              ),
          ],
        ),

        const SizedBox(height: 40),

        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.teal,
              ),
            ),
            SizedBox(width: 12),
            Text(
              "Listening for incoming token...",
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.teal,
              ),
            ),
          ],
        ),
        const SizedBox(height: 30),

        ElevatedButton.icon(
          onPressed: _isRefreshing ? null : _manualRefresh,
          icon: _isRefreshing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.autorenew),
          label: Text(_isRefreshing ? "Refreshing..." : "Refresh QR Code"),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            backgroundColor: Colors.blueGrey,
            foregroundColor: Colors.white,
          ),
        ),
      ],
    );
  }

  /// UI STATE 2: Token Received (Hides QR, Shows Diagnostics & Options)
  Widget _buildResultScreen() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        Icon(
          _isBackendRejected ? Icons.error_outline : Icons.check_circle,
          color: _isBackendRejected ? Colors.red : Colors.green,
          size: 100,
        ),
        const SizedBox(height: 16),
        Text(
          _isBackendRejected ? "Verification Failed" : "Attendance Verified!",
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: _isBackendRejected ? Colors.red : Colors.green,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _verifiedPeerUid ?? "Processing...",
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, color: Colors.grey),
        ),

        const SizedBox(height: 40),

        // DIAGNOSTIC PANEL
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.teal.shade200),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.analytics, color: Colors.teal),
                  SizedBox(width: 8),
                  Text(
                    "Transmission Details",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ],
              ),
              const Divider(),
              Text(
                "Signal Strength (RSSI): ${_lastRssi ?? 'N/A'} dBm",
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 6),
              Text(
                "Encrypted Payload: ${_lastRawPayload ?? 'N/A'}",
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(height: 6),
              Text(
                "Decrypted Node ID: ${_lastDecryptedId ?? 'N/A'}",
                style: const TextStyle(
                  fontFamily: 'monospace',
                  color: Colors.blueAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 50),

        // NAVIGATION BUTTONS
        ElevatedButton.icon(
          onPressed: _scanAnother,
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text("Scan Another Classmate"),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            backgroundColor: Colors.teal,
            foregroundColor: Colors.white,
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () {
            if (mounted) Navigator.pop(context);
          },
          icon: const Icon(Icons.exit_to_app),
          label: const Text("Back to Dashboard"),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            foregroundColor: Colors.teal,
            side: const BorderSide(color: Colors.teal),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}
