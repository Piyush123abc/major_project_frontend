import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';

import 'package:attendance_app/HomePage.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  print("📡 Background message received: ${message.messageId}");
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  runApp(const MyApp2());
}

class MyApp2 extends StatefulWidget {
  const MyApp2({super.key});

  @override
  State<MyApp2> createState() => _MyApp2State();
}

class _MyApp2State extends State<MyApp2> {
  @override
  void initState() {
    super.initState();
    _setupFCMForegroundListener();
  }

  // --- UPGRADED REAL-TIME LISTENER ---
  Future<void> _setupFCMForegroundListener() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;

    // 1. Explicitly request permission (Required for Android 13+ and iOS)
    NotificationSettings settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    print('🔐 User granted permission: ${settings.authorizationStatus}');

    // 2. Configure foreground notification presentation (For iOS mainly)
    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );

    // 3. Listen for the message
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('🔔 FCM MESSAGE RECEIVED IN FOREGROUND!');
      print('Data Payload: ${message.data}');
      print('Notification Payload: ${message.notification?.title}');

      // Safely extract text (Sometimes Firebase puts it in data instead of notification)
      String title =
          message.notification?.title ??
          message.data['title'] ??
          'System Alert';
      String body =
          message.notification?.body ??
          message.data['body'] ??
          'You have a new update.';

      IconData alertIcon = Icons.info_outline;
      Color primaryColor = Colors.blueAccent;

      if (message.data['type'] == 'connection_verified') {
        alertIcon = Icons.verified_user;
        primaryColor = Colors.greenAccent;
      } else if (message.data['type'] == 'final') {
        if (message.data['status'] == 'present') {
          alertIcon = Icons.check_circle;
          primaryColor = Colors.greenAccent;
        } else {
          alertIcon = Icons.cancel;
          primaryColor = Colors.redAccent;
        }
      }

      // Grab the context
      final context = navigatorKey.currentContext;

      if (context == null) {
        print(
          '❌ ERROR: navigatorKey.currentContext is NULL. Cannot show dialog.',
        );
        return;
      }

      print('✅ Context found! Drawing the Alert Dialog now...');

      // Draw the dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: primaryColor.withOpacity(0.5),
                width: 1.5,
              ),
            ),
            title: Row(
              children: [
                Icon(alertIcon, color: primaryColor, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: primaryColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 20,
                    ),
                  ),
                ),
              ],
            ),
            content: Text(
              body,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 16,
                height: 1.4,
              ),
            ),
            actions: [
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor.withOpacity(0.15),
                    foregroundColor: primaryColor,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    "OK",
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      home: const HomePage(),
    );
  }
}
