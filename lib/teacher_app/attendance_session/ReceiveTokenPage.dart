import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:attendance_app/global_variable/base_url.dart';
import 'package:attendance_app/global_variable/teacher_profile.dart';
import 'package:attendance_app/global_variable/token_handles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:http/http.dart' as http;

class ReceiveTokenPage extends StatefulWidget {
  final int classroomId;
  const ReceiveTokenPage({super.key, required this.classroomId});

  @override
  State<ReceiveTokenPage> createState() => _ReceiveTokenPageState();
}

class _ReceiveTokenPageState extends State<ReceiveTokenPage> {
  static const int rssiThreshold = -75;

  String teacherUid = "";
  bool _isScanning = false;
  bool _foregroundActive = false;
  int scanIndex = 1;

  StreamSubscription? _scanSubscription;
  List<Map<String, dynamic>> allSignals = [];
  List<Map<String, dynamic>> matchedSignals = [];
  Map<String, dynamic>? latestMatchedSignal;
  String _latestRssi = "N/A";
  DateTime _lastUiUpdate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _initForegroundTask();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadTeacherUid();
    });
  }

  // ---------------- Helper Methods ----------------
  void _addLog(String msg) {
    if (!mounted) return;
    setState(() {
      allSignals.insert(0, {"message": msg});
      if (allSignals.length > 100) allSignals = allSignals.sublist(0, 100);
    });
  }

  void _loadTeacherUid() {
    final profile = GlobalStore.teacherProfile;
    if (profile != null && profile.containsKey("uid")) {
      teacherUid = profile["uid"];
      _addLog("✅ Loaded teacher UID from global store: $teacherUid");
    } else {
      _addLog("⚠️ Teacher profile not found in global store.");
    }
  }

  String getCurrentUuid() {
    final raw = "$teacherUid$scanIndex";
    String clean = raw.padRight(32, '0');
    if (clean.length > 32) clean = clean.substring(0, 32);
    return "${clean.substring(0, 8)}-"
        "${clean.substring(8, 12)}-"
        "${clean.substring(12, 16)}-"
        "${clean.substring(16, 20)}-"
        "${clean.substring(20)}";
  }

  // ---------------- BLE Scanning ----------------
  Future<void> _startScanning() async {
    if (_isScanning || teacherUid.isEmpty) return;

    if (!_foregroundActive && Platform.isAndroid) {
      await _startForegroundTask();
    }

    await _scanSubscription?.cancel();

    _scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
      if (results.isEmpty) return;

      for (var result in results) {
        try {
          int rssi = result.rssi;
          String payload = 'N/A';
          if (result.advertisementData.manufacturerData.isNotEmpty) {
            final firstData =
                result.advertisementData.manufacturerData.values.first;
            if (firstData.isNotEmpty) {
              // 1. Initialize an integer to hold the decoded value
              int decodedInt = 0;

              // 2. Reconstruct the integer from the incoming bytes (Big Endian)
              for (int i = 0; i < firstData.length; i++) {
                decodedInt = (decodedInt << 8) | firstData[i];
              }

              // 3. Convert the integer back to a string for your backend
              payload = decodedInt.toString();
            }
          }

          List<String> scannedUuids = result.advertisementData.serviceUuids
              .map((u) => u.toString().replaceAll('-', '').toLowerCase())
              .toList();

          // ✅ Dynamically get current target UUID
          final currentTargetUuid = getCurrentUuid()
              .replaceAll('-', '')
              .toLowerCase();

          final signalInfo = {
            "uuidList": scannedUuids,
            "rssi": rssi,
            "payload": payload,
            "device": result.device.name.isNotEmpty
                ? result.device.name
                : result.device.id,
            "matched": false,
          };

          // ✅ Throttled UI update every 200ms to avoid lag
          final now = DateTime.now();
          if (now.difference(_lastUiUpdate).inMilliseconds > 200) {
            if (mounted) {
              setState(() {
                allSignals.insert(0, signalInfo);
                if (allSignals.length > 50) {
                  allSignals = allSignals.sublist(0, 50);
                }
              });
            }
            _lastUiUpdate = now;
          }

          // ✅ Match detection with live UUID switching
          if (scannedUuids.contains(currentTargetUuid) &&
              rssi >= rssiThreshold) {
            final backendMessage = await _callPassToken(payload, rssi);
            signalInfo["matched"] = true;
            signalInfo["backendMessage"] = backendMessage ?? "Success";

            if (mounted) {
              setState(() {
                matchedSignals.insert(0, signalInfo);
                latestMatchedSignal = signalInfo;
                scanIndex++; // Immediately move to next UUID
              });
            }

            _addLog(
              "🎯 Matched UUID $currentTargetUuid → Moving to new UUID: ${getCurrentUuid()}",
            );
          }

          if (mounted) {
            setState(() {
              _latestRssi =
                  "$rssi dBm (${result.device.name.isNotEmpty ? result.device.name : result.device.id})";
            });
          }
        } catch (e) {
          _addLog("⚠️ Scan loop error: $e");
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(
        withServices: [],
        androidScanMode: AndroidScanMode.lowLatency,
      );
      if (!mounted) return;
      setState(() => _isScanning = true);
      _addLog("🔍 Scanning started (UUID: ${getCurrentUuid()})");
    } catch (e) {
      _addLog("❌ Scan start error: $e");
    }
  }

  Future<void> _stopScanning() async {
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _isScanning = false;
    });
    _addLog("🛑 Scanning stopped.");
  }

  // ---------------- Backend call ----------------
  Future<String?> _callPassToken(String fromUid, int rssi) async {
    try {
      final headers = await TokenHandles.getAuthHeaders();
      if (headers.isEmpty) {
        _addLog("❌ Auth failed, token missing");
        return null;
      }

      final url = Uri.parse(
        "${BaseUrl.value}/session/student/classroom/${widget.classroomId}/pass-token/",
      );

      final body = {"from_uid": fromUid, "to_uid": teacherUid};
      final response = await http.post(
        url,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode(body),
      );

      if (!mounted) return null;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _addLog("📤 Token passed successfully (RSSI: $rssi dBm)");
        return data["message"];
      } else {
        final data = jsonDecode(response.body);
        _addLog(
          "⚠️ Failed (${response.statusCode}): ${data["detail"] ?? data["error"] ?? response.body}",
        );
        return data["detail"] ?? data["error"];
      }
    } catch (e) {
      _addLog("❌ Exception: $e");
      return e.toString();
    }
  }

  // ---------------- Foreground Task ----------------
  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'bluetooth_scan_channel',
        channelName: 'BLE Scanning',
        channelDescription: 'Foreground service for continuous BLE scanning',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
        buttons: const [NotificationButton(id: 'stop', text: 'STOP')],
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 3000,
        isOnceEvent: false,
        allowWakeLock: true,
      ),
    );
  }

  Future<void> _startForegroundTask() async {
    if (_foregroundActive || !Platform.isAndroid) return;
    FlutterForegroundTask.startService(
      notificationTitle: 'BLE Scanning Active',
      notificationText: 'Bluetooth scanning running in background',
    );
    _foregroundActive = true;
  }

  @override
  void dispose() {
    _stopScanning();
    super.dispose();
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Receive Token")),
      body: Column(
        children: [
          const SizedBox(height: 10),
          if (teacherUid.isNotEmpty)
            Column(
              children: [
                const Text(
                  "📡 Active UUID (live updating):",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  getCurrentUuid(),
                  style: const TextStyle(fontFamily: "monospace"),
                ),
                const SizedBox(height: 10),
                bw.BarcodeWidget(
                  barcode: bw.Barcode.qrCode(),
                  data: getCurrentUuid(),
                  width: 160,
                  height: 160,
                ),
              ],
            ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: _isScanning ? _stopScanning : _startScanning,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isScanning ? Colors.red : Colors.blue,
                ),
                child: Text(
                  _isScanning ? "🛑 Stop Scanning" : "▶️ Start Scanning",
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text("Latest RSSI: $_latestRssi"),
          const Divider(),

          Expanded(
            child: Column(
              children: [
                if (latestMatchedSignal != null)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.green[300],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.all(10),
                    margin: const EdgeInsets.all(8),
                    child: Text(
                      "✅ Matched Device:\n"
                      "Device: ${latestMatchedSignal!['device']}\n"
                      "RSSI: ${latestMatchedSignal!['rssi']} dBm\n"
                      "Payload: ${latestMatchedSignal!['payload']}\n"
                      "Backend: ${latestMatchedSignal!['backendMessage'] ?? 'Success'}",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    reverse: true,
                    itemCount: allSignals.length.clamp(0, 50),
                    itemBuilder: (context, index) {
                      final sig = allSignals[index];
                      if (sig.containsKey("message")) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          child: Text(sig["message"]),
                        );
                      } else if (sig["matched"] == true) {
                        return Container(
                          margin: const EdgeInsets.symmetric(
                            vertical: 2,
                            horizontal: 6,
                          ),
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.green[100],
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            "✅ Matched → ${sig['device']} (${sig['rssi']} dBm)",
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        );
                      } else {
                        return ListTile(
                          title: Text(sig['device']),
                          subtitle: Text(
                            "UUIDs: ${sig['uuidList'].join(', ')}\nRSSI: ${sig['rssi']} dBm\nPayload: ${sig['payload']}",
                          ),
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
