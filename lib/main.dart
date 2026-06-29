import 'package:attendance_app_new/splash_screen.dart';
import 'package:attendance_app_new/web_entry.dart';
import 'package:attendance_app_new/route_observer.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_store_plus/media_store_plus.dart';
import 'firebase_options.dart';
import 'notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await MediaStore.ensureInitialized();
    MediaStore.appFolder = 'TaxTeckAMS';
  }

  // 🟠 Initialize notifications ONLY on mobile
  if (!kIsWeb) {
    initNotifications();
  }

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorObservers: [appRouteObserver],
      home: kIsWeb ? const WebEntry() : const SplashScreen(),
    );
  }
}