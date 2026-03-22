import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'package:attendance_app/global_variable/base_url.dart';
import 'package:attendance_app/global_variable/session_data_manager.dart';
import 'package:attendance_app/global_variable/token_handles.dart';
import 'package:attendance_app/global_variable/transmission_counter.dart';

// Pipeline States
enum ScanStage { camera, hunting, connecting, measuring, verifying, report }

class SecureProximityScannerPage extends StatefulWidget {
  final String ownUid;
  final int classroomId;

  const SecureProximityScannerPage({
    super.key,
    required this.ownUid,
    required this.classroomId,
  });

  @override
  State<SecureProximityScannerPage> createState() =>
      _SecureProximityScannerPageState();
}

class _SecureProximityScannerPageState
    extends State<SecureProximityScannerPage> {
  final MobileScannerController _cameraController = MobileScannerController();
  StreamSubscription? _bleScanSub;

  ScanStage _stage = ScanStage.camera;
  String _statusText = "Align QR Code inside the frame";

  // Report Data
  List<int> _rtts = [];
  int? _rssi;
  bool _nonceVerified = false;
  int? _peerNodeId;
  String _backendMessage = "";
  bool _isSuccess = false;

  // --- NEW: Terminal Logs for debugging ---
  final List<String> _terminalLogs = [];

  // GATT Constants
  final String writeCharUuid = "11111111-2222-3333-4444-555555555555";
  final String notifyCharUuid = "22222222-3333-4444-5555-666666666666";

  @override
  void initState() {
    super.initState();
    _checkBluetooth();
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

  Future<void> _checkBluetooth() async {
    if (Platform.isAndroid) {
      var state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) await FlutterBluePlus.turnOn();
    }
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _bleScanSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  // ==========================================
  // PHASE 1: CAMERA SCAN
  // ==========================================
  void _onQrDetected(String targetUuid) {
    if (_stage != ScanStage.camera) return;

    HapticFeedback.lightImpact();
    _cameraController.stop(); // Kill camera to save resources
    _addLog("QR Scanned: ${targetUuid.substring(0, 8)}...");

    setState(() {
      _stage = ScanStage.hunting;
      _statusText = "Hunting Host Signal...";
    });

    _huntForHost(targetUuid.trim().toLowerCase());
  }

  // ==========================================
  // PHASE 2: HUNT & CONNECT
  // ==========================================
  Future<void> _huntForHost(String targetUuid) async {
    _addLog("Starting BLE Scan for Host...");

    _bleScanSub = FlutterBluePlus.scanResults.listen((results) async {
      for (var r in results) {
        List<String> uuids = r.advertisementData.serviceUuids
            .map((u) => u.toString().toLowerCase())
            .toList();

        if (uuids.contains(targetUuid)) {
          _bleScanSub?.cancel();
          FlutterBluePlus.stopScan();

          _addLog("Host Found! RSSI: ${r.rssi} dBm");

          setState(() {
            _rssi = r.rssi;
            _stage = ScanStage.connecting;
            _statusText = "Signal Caught. Connecting...";
          });

          await _executeSecureHandshake(r.device, targetUuid);
          break;
        }
      }
    });

    FlutterBluePlus.startScan(
      withServices: [Guid(targetUuid)],
      androidScanMode: AndroidScanMode.lowLatency,
      timeout: const Duration(seconds: 10),
    );
  }

  // ==========================================
  // PHASE 3: THE CRYPTO HANDSHAKE
  // ==========================================
  Future<void> _executeSecureHandshake(
    BluetoothDevice device,
    String serviceUuid,
  ) async {
    try {
      _addLog("Connecting to GATT Server...");
      await device.connect(autoConnect: false, mtu: null);

      if (Platform.isAndroid) {
        await device.requestConnectionPriority(
          connectionPriorityRequest: ConnectionPriority.high,
        );
        await device.requestMtu(512);
        _addLog("MTU Requested. Radio Optimized.");
      }

      setState(() {
        _stage = ScanStage.measuring;
        _statusText = "Executing RTT Burst...";
      });

      _addLog("Discovering Services...");
      List<BluetoothService> services = await device.discoverServices();
      BluetoothService? targetService;
      for (var s in services) {
        if (s.uuid.toString().toLowerCase() == serviceUuid) targetService = s;
      }

      if (targetService == null)
        throw Exception("Service not found on target.");

      BluetoothCharacteristic? writeChar;
      BluetoothCharacteristic? notifyChar;

      for (var c in targetService.characteristics) {
        if (c.uuid.toString() == writeCharUuid) writeChar = c;
        if (c.uuid.toString() == notifyCharUuid) notifyChar = c;
      }

      if (writeChar == null || notifyChar == null)
        throw Exception("GATT Pipes missing.");
      _addLog("GATT Pipes secured.");

      // 3. Prepare the Cryptographic Challenge
      final creds = SessionDataManager.instance.getCredentials(
        widget.classroomId.toString(),
      );
      if (creds == null) throw Exception("Session Keys Missing");

      // SHA-256(seed + counter) -> Truncate to 16 bytes for AES block
      SecureCounter.scanIndex++;
      var bytes = utf8.encode(
        creds.sessionSeed + SecureCounter.scanIndex.toString(),
      );
      var digest = sha256.convert(bytes);
      List<int> challengeNonce = digest.bytes.sublist(0, 16);

      // Encrypt the Challenge
      final key = enc.Key.fromBase16(creds.kClass);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.ecb));
      final encryptedChallenge = encrypter
          .encryptBytes(challengeNonce)
          .bytes
          .toList();

      // 4. Set the Echo Trap
      _addLog("Setting Echo Trap (CCCD)...");
      await notifyChar.setNotifyValue(true);
      Completer<List<int>> echoCompleter = Completer();

      final notifySub = notifyChar.onValueReceived.listen((value) {
        if (value.isNotEmpty && !echoCompleter.isCompleted) {
          _addLog("ECHO RECEIVED from Host!");
          echoCompleter.complete(value);
        }
      });

      // 5. The RTT Burst (3 rapid writes) RESTORED WITH LOGS
      _addLog("Firing RTT Burst (3 writes)...");
      List<int> bursts = [];
      for (int i = 0; i < 3; i++) {
        Stopwatch sw = Stopwatch()..start();
        await writeChar.write(encryptedChallenge, withoutResponse: false);
        sw.stop();
        bursts.add(sw.elapsedMilliseconds);
        _addLog("Write ${i + 1} ACKed in ${sw.elapsedMilliseconds}ms");
        await Future.delayed(const Duration(milliseconds: 10)); // Tiny breath
      }

      setState(() {
        _rtts = bursts;
        _stage = ScanStage.verifying;
        _statusText = "Verifying Echo...";
      });

      _addLog("Burst complete. Waiting 5s for Echo...");

      // 6. Catch the Echo
      List<int> echoPayload = await echoCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw Exception("Echo Timeout. Host took too long or crashed.");
        },
      );
      notifySub.cancel();

      _addLog("Disconnecting cleanly...");
      await device.disconnect(); // Free the Host instantly!

      // 7. Verify the Crypto
      _addLog("Decrypting Host Echo...");
      final decryptedEcho = encrypter.decryptBytes(
        enc.Encrypted(Uint8List.fromList(echoPayload)),
      );

      // Compare the first 14 bytes
      bool nonceMatch = true;
      for (int i = 0; i < 14; i++) {
        if (decryptedEcho[i] != challengeNonce[i]) nonceMatch = false;
      }

      _nonceVerified = nonceMatch;

      if (!nonceMatch)
        throw Exception(
          "Cryptographic Nonce mismatch. Possible Replay/Spoofing Attack.",
        );

      // Check RTT Limit (Using the minimum RTT to avoid random OS lag spikes)
      int minRtt = bursts.reduce(min);
      if (minRtt > 150)
        throw Exception(
          "RTT Exceeded 150ms ($minRtt ms). Relay Attack Detected.",
        );

      // Extract Host Node ID (Last 2 bytes)
      _peerNodeId = (decryptedEcho[14] << 8) | decryptedEcho[15];
      _addLog("Crypto Verified! Node ID: $_peerNodeId");

      // 8. Django Backend Sync
      await _syncWithDjango(_peerNodeId.toString());
    } catch (e) {
      device.disconnect();
      _addLog("FAIL: $e", isError: true);
      _failProtocol(e.toString());
    }
  }

  // ==========================================
  // PHASE 4: BACKEND SYNC
  // ==========================================
  Future<void> _syncWithDjango(String hostTempId) async {
    setState(() => _statusText = "Syncing with Server...");
    try {
      final headers = await TokenHandles.getAuthHeaders();
      String rawBase = BaseUrl.value.endsWith('/')
          ? BaseUrl.value.substring(0, BaseUrl.value.length - 1)
          : BaseUrl.value;
      final url = Uri.parse(
        "$rawBase/session/student/classroom/${widget.classroomId}/pass-token/",
      );

      final response = await http.post(
        url,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode({"from_uid": widget.ownUid, "to_uid": hostTempId}),
      );

      final body = jsonDecode(response.body);

      if (response.statusCode == 200) {
        setState(() {
          _isSuccess = true;
          _backendMessage =
              "Connected to Node: ${body['verified_with'] ?? hostTempId}";
          _stage = ScanStage.report;
        });
        HapticFeedback.heavyImpact();
      } else {
        _failProtocol(body["error"] ?? "Django rejected the connection.");
      }
    } catch (e) {
      _failProtocol("Network connection failed.");
    }
  }

  void _failProtocol(String reason) {
    if (!mounted) return;
    setState(() {
      _isSuccess = false;
      _backendMessage = reason;
      _stage = ScanStage.report;
    });
    HapticFeedback.vibrate();
  }

  // ==========================================
  // UI BUILDERS
  // ==========================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black, // Pure utility black
      body: SafeArea(
        child: Column(
          children: [
            // HEADER
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "SECURE SCANNER",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (_stage != ScanStage.report)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.indigoAccent,
                      ),
                    ),
                ],
              ),
            ),

            // DYNAMIC CONTENT AREA
            Expanded(
              flex: 5,
              child: _stage == ScanStage.camera
                  ? _buildCameraView()
                  : _stage == ScanStage.report
                  ? _buildReportView()
                  : _buildProcessingView(),
            ),

            // --- NEW: TERMINAL LOGS UI ---
            if (_stage != ScanStage.camera && _stage != ScanStage.report)
              Expanded(
                flex: 2,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
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
                        "SCANNER LOGS",
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
              ),

            // RED EXIT BUTTON (Always at bottom)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: SizedBox(
                width: double.infinity,
                height: 60,
                child: ElevatedButton.icon(
                  onPressed: () {
                    HapticFeedback.heavyImpact();
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.stop_circle_outlined, size: 28),
                  label: Text(
                    _stage == ScanStage.report ? "DONE & EXIT" : "ABORT SCAN",
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
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
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraView() {
    return Stack(
      alignment: Alignment.center,
      children: [
        MobileScanner(
          controller: _cameraController,
          onDetect: (capture) {
            final barcodes = capture.barcodes;
            if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
              _onQrDetected(barcodes.first.rawValue!);
            }
          },
        ),
        // Simple targeting box
        Container(
          width: 250,
          height: 250,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.indigoAccent, width: 3),
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        Positioned(
          bottom: 40,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _statusText,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProcessingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.radar, size: 80, color: Colors.indigoAccent),
          const SizedBox(height: 30),
          Text(
            _statusText,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReportView() {
    Color themeColor = _isSuccess ? Colors.greenAccent : Colors.redAccent;
    IconData themeIcon = _isSuccess
        ? Icons.check_circle_outline
        : Icons.error_outline;

    String calculateAverageRtt() {
      if (_rtts.isEmpty) return "N/A";
      double avg = _rtts.reduce((a, b) => a + b) / _rtts.length;
      return "${avg.toStringAsFixed(1)} ms";
    }

    String calculateMinRtt() {
      if (_rtts.isEmpty) return "N/A";
      return "${_rtts.reduce(min)} ms";
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- HEADER SECTION ---
            Container(
              padding: const EdgeInsets.symmetric(vertical: 24),
              decoration: BoxDecoration(
                color: themeColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: themeColor.withOpacity(0.3),
                  width: 2,
                ),
              ),
              child: Column(
                children: [
                  Icon(themeIcon, size: 70, color: themeColor),
                  const SizedBox(height: 12),
                  Text(
                    _isSuccess ? "HANDSHAKE SECURED" : "HANDSHAKE FAILED",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: themeColor,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // --- CARD 1: TELEMETRY & TIMING ---
            _buildSectionCard(
              title: "CONNECTION TELEMETRY",
              icon: Icons.radar,
              iconColor: Colors.blueAccent,
              child: Column(
                children: [
                  _buildDataRow(
                    "Signal (RSSI)",
                    "${_rssi ?? 'N/A'} dBm",
                    isGood: _rssi != null && _rssi! > -80,
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8.0),
                    child: Divider(color: Colors.white12),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildMiniStatBox(
                        "Burst 1",
                        _rtts.isNotEmpty ? "${_rtts[0]}ms" : "N/A",
                      ),
                      _buildMiniStatBox(
                        "Burst 2",
                        _rtts.length > 1 ? "${_rtts[1]}ms" : "N/A",
                      ),
                      _buildMiniStatBox(
                        "Burst 3",
                        _rtts.length > 2 ? "${_rtts[2]}ms" : "N/A",
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildHighlightStat("Min RTT", calculateMinRtt()),
                      _buildHighlightStat("Avg RTT", calculateAverageRtt()),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // --- CARD 2: CRYPTOGRAPHY ---
            _buildSectionCard(
              title: "SECURITY VERIFICATION",
              icon: Icons.lock_outline,
              iconColor: Colors.purpleAccent,
              child: Column(
                children: [
                  _buildDataRow(
                    "AES Nonce Match",
                    _nonceVerified ? "VERIFIED" : "FAILED",
                    isGood: _nonceVerified,
                  ),
                  const SizedBox(height: 8),
                  _buildDataRow(
                    "Extracted Peer ID",
                    _peerNodeId?.toString() ?? "NONE",
                    isGood: _peerNodeId != null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // --- CARD 3: CLOUD SYNC ---
            _buildSectionCard(
              title: "DJANGO SERVER RESPONSE",
              icon: Icons.cloud_done_outlined,
              iconColor: Colors.orangeAccent,
              child: Text(
                _backendMessage,
                style: TextStyle(
                  color: _isSuccess ? Colors.greenAccent : Colors.redAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ),
            const SizedBox(height: 20), // Bottom padding
          ],
        ),
      ),
    );
  }

  // --- NEW UI HELPER WIDGETS ---

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required Color iconColor,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        border: Border.all(color: Colors.grey.shade900),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: iconColor),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  color: iconColor.withOpacity(0.8),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _buildDataRow(String label, String value, {required bool isGood}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        Text(
          value,
          style: TextStyle(
            color: isGood ? Colors.greenAccent : Colors.redAccent,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
            fontSize: 15,
          ),
        ),
      ],
    );
  }

  Widget _buildMiniStatBox(String label, String value) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 10),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHighlightStat(String label, String value) {
    return Row(
      children: [
        Text(
          "$label: ",
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        Text(
          value,
          style: const TextStyle(
            color: Colors.cyanAccent,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
            fontSize: 14,
          ),
        ),
      ],
    );
  }

  Widget _buildReportLine(String label, String value, bool isGood) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          Text(
            value,
            style: TextStyle(
              color: isGood ? Colors.greenAccent : Colors.redAccent,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
