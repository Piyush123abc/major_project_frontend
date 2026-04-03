import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:attendance_app/global_variable/base_url.dart';
import 'package:attendance_app/global_variable/token_handles.dart';
import 'dart:io' show Platform;

class SecurityReporter {
  /// Sends a security anomaly report to the backend silently.
  ///
  /// [anomalyTypeInt] matches the Django Enum:
  /// 1 = Latency Spike, 2 = Proximity Violation, 3 = Rapid Scans,
  /// 4 = Device Mismatch, 5 = Biometric Altered, 6 = Play Integrity Fail
  static Future<void> reportAnomaly({
    required int anomalyTypeInt,
    required String source,
  }) async {
    try {
      final headers = await TokenHandles.getAuthHeaders();
      headers["Content-Type"] = "application/json";

      // Safely handle trailing slashes in BaseUrl just in case
      String rawBase = BaseUrl.value.endsWith('/')
          ? BaseUrl.value.substring(0, BaseUrl.value.length - 1)
          : BaseUrl.value;

      final url = Uri.parse("$rawBase/session/security/student-report/");

      final osType = Platform.isAndroid ? "Android" : "iOS";

      // Actually capture the response object
      final response = await http.post(
        url,
        headers: headers,
        body: jsonEncode({
          "anomaly_type": anomalyTypeInt,
          "context": {"source": source, "os": osType},
        }),
      );

      // Check if Django accepted it (200 OK or 201 Created)
      if (response.statusCode == 200 || response.statusCode == 201) {
        debugPrint(
          "✅ Security Tripwire: Anomaly $anomalyTypeInt reported successfully from $source.",
        );
      } else {
        // Django rejected it! Print the exact error.
        debugPrint("❌ Server rejected anomaly report!");
        debugPrint("👉 Status Code: ${response.statusCode}");
        debugPrint("👉 Response Body: ${response.body}");
      }
    } catch (e) {
      // This catches total network failures (e.g., WiFi disconnected)
      debugPrint("❌ Network/App Error while sending anomaly report: $e");
    }
  }
}
