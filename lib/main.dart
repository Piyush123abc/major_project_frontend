import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

import 'package:attendance_app/HomePage.dart';

void main() async {
  // 1. Ensure Flutter bindings are initialized before calling native code
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Initialize Firebase for the current platform (Android/iOS/Web)
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // 3. Run your specific app entry point
  runApp(const MyApp2());
}

class MyApp2 extends StatelessWidget {
  const MyApp2({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: HomePage(), // ✅ Now Scaffold has MaterialApp ancestor
    );
  }
}
