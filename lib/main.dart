import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // <-- IMPORTANT FOR kIsWeb
import 'attendance_form.dart';
import 'auth_page.dart';
import 'email_verification.dart';
import 'firebase_options.dart';
import 'logger.dart';
import 'notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  //AppLogger.log(event: "App Launched");

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
  User? pendingVerificationUser;

  void showVerification(User user) {
    setState(() {
      pendingVerificationUser = user;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) {
          final user = FirebaseAuth.instance.currentUser;

          if (pendingVerificationUser != null) {
            AppLogger.log(
              event: "Opened EmailVerificationPage",
              uid: pendingVerificationUser!.uid,
            );
            return EmailVerificationPage(user: pendingVerificationUser!);
          }

          if (user != null && user.emailVerified) {
            AppLogger.log(event: "User logged in", uid: user.uid);
           // if (!kIsWeb) scheduleDailyAttendanceReminder();
            return const AttendanceForm();
          }

          return AuthPage(); // pass callback
        },
      ),
    );
  }
}