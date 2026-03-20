import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'; // Added for BT check
import 'package:encrypt/encrypt.dart' as enc;

import 'package:attendance_app/global_variable/session_data_manager.dart';

enum ScannerStage { scanning, transmitting }

class FallbackScannerTransmitterPage extends StatefulWidget {
  final String ownUid;
  final int classroomId;

  const FallbackScannerTransmitterPage({
    super.key,
    required this.ownUid,
    required this.classroomId,
  });

  @override
  State<FallbackScannerTransmitterPage> createState() =>
      _FallbackScannerTransmitterPageState();
}

class _FallbackScannerTransmitterPageState
    extends State<FallbackScannerTransmitterPage> {
  // State management
  ScannerStage _stage = ScannerStage.scanning;
  String? _targetUuid;

  // Controllers
  final MobileScannerController _cameraController = MobileScannerController();
  final FlutterBlePeripheral _blePeripheral = FlutterBlePeripheral();

  @override
  void initState() {
    super.initState();
    _checkAndEnableBluetooth();
  }

  /// NEW: Ensures Bluetooth is actually ON before they try to transmit
  Future<void> _checkAndEnableBluetooth() async {
    if (Platform.isAndroid) {
      try {
        var state = await FlutterBluePlus.adapterState.first;
        if (state != BluetoothAdapterState.on) {
          await FlutterBluePlus.turnOn();
        }
      } catch (e) {
        debugPrint("Could not turn on BT automatically: $e");
      }
    }
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _stopAdvertising();
    super.dispose();
  }

  // ---------------- Core Crypto Logic ----------------

  /// Encrypts the student's Node ID using the classroom's AES key
  Uint8List _getEncryptedPayload() {
    try {
      // 1. Fetch credentials
      final creds = SessionDataManager.instance.getCredentials(
        widget.classroomId.toString(),
      );

      // 2. Identify what to send (Node ID counter, or fallback to UID if missing)
      final String payloadString = creds?.nodeId ?? widget.ownUid;

      // 3. Get the key
      final String hexKey = creds?.kClass ?? "00000000000000000000000000000000";
      final key = enc.Key.fromBase16(hexKey);

      // 4. Encrypt using AES-ECB
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.ecb));
      final encrypted = encrypter.encrypt(payloadString);

      // 5. Return the raw bytes to be broadcasted (Exactly 16 bytes due to padding)
      return encrypted.bytes;
    } catch (e) {
      debugPrint("Encryption error: $e");
      return Uint8List(0);
    }
  }

  // ---------------- BLE Advertising ----------------

  Future<void> _startAdvertising(String scannedUuid) async {
    // Format the UUID properly just in case the QR code string is messy
    String cleanUuid = scannedUuid.trim().toLowerCase();

    // Get our heavily encrypted payload
    Uint8List encryptedPayload = _getEncryptedPayload();

    final advertiseData = AdvertiseData(
      serviceUuid:
          cleanUuid, // The specific channel the receiver is listening to
      manufacturerId: 1234, // Arbitrary company ID required by BLE spec
      manufacturerData: encryptedPayload, // The AES locked data!
      includeDeviceName: false, // Must be false to save payload space
    );

    try {
      await _blePeripheral.start(advertiseData: advertiseData);
      debugPrint("📡 Started Broadcasting Encrypted Payload to: $cleanUuid");
    } catch (e) {
      debugPrint("❌ BLE Advertise Error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Bluetooth Error: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _stopAdvertising() async {
    try {
      await _blePeripheral.stop();
      debugPrint("📴 Stopped Broadcasting.");
    } catch (e) {
      debugPrint("Stop error: $e");
    }
  }

  // ---------------- Event Handlers ----------------

  void _onQrDetected(String scannedValue) {
    if (_stage == ScannerStage.scanning) {
      // 1. Immediately shut off the camera to save battery & provide visual feedback
      _cameraController.stop();

      // 2. Update UI state to "Transmitting"
      setState(() {
        _stage = ScannerStage.transmitting;
        _targetUuid = scannedValue;
      });

      // 3. Kick off the Bluetooth beacon
      _startAdvertising(scannedValue);
    }
  }

  void _onConfirmationPressed() async {
    await _stopAdvertising();
    if (mounted) {
      Navigator.pop(context); // Go back to the dashboard
    }
  }

  // ---------------- UI Builders ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Scan & Send (Transmitter)"),
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
      ),
      body: _stage == ScannerStage.scanning
          ? _buildScanningState()
          : _buildTransmittingState(),
    );
  }

  /// STATE 1: Camera is open and looking for a QR code
  Widget _buildScanningState() {
    return Stack(
      children: [
        MobileScanner(
          controller: _cameraController,
          onDetect: (capture) {
            final List<Barcode> barcodes = capture.barcodes;
            if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
              _onQrDetected(barcodes.first.rawValue!);
            }
          },
        ),

        // HCI Overlay: Darkened edges with a clear scanning window
        Container(
          decoration: BoxDecoration(color: Colors.black.withOpacity(0.5)),
          child: Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.blueAccent, width: 3),
                borderRadius: BorderRadius.circular(12),
                color: Colors.transparent,
              ),
            ),
          ),
        ),

        // HCI Overlay: Clear Instructions
        Positioned(
          bottom: 60,
          left: 0,
          right: 0,
          child: Column(
            children: const [
              Icon(Icons.qr_code_scanner, color: Colors.white, size: 40),
              SizedBox(height: 12),
              Text(
                "Point at classmate's QR Code",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                ),
              ),
              SizedBox(height: 8),
              Text(
                "Transmission will start automatically.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// STATE 2: Camera is gone, phone is broadcasting BLE
  Widget _buildTransmittingState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Broadcasting Animation
            const SizedBox(
              width: 80,
              height: 80,
              child: CircularProgressIndicator(
                strokeWidth: 6,
                color: Colors.blueAccent,
              ),
            ),
            const SizedBox(height: 30),

            const Text(
              "Transmitting Token...",
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.blueAccent,
              ),
            ),
            const SizedBox(height: 12),

            const Text(
              "Keep your phone near your classmate's device.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),

            const SizedBox(height: 60),

            // HCI: Manual confirmation button
            ElevatedButton.icon(
              onPressed: _onConfirmationPressed,
              icon: const Icon(Icons.check_circle_outline),
              label: const Text("Mark as Done & Exit"),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 16,
                ),
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                textStyle: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),

            const SizedBox(height: 12),
            const Text(
              "Press this when your classmate confirms receipt.",
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
