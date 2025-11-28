import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // <-- IMPORTANT FOR kIsWeb
import 'attendance_form.dart';
import 'auth_page.dart';
import 'email_verification.dart';
import 'firebase_options.dart';

/// Notifications plugin (Mobile only)
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

/// Create plugin
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
FlutterLocalNotificationsPlugin();

Future<void> initNotifications() async {
  print("initNotifications");
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');

  const initSettings = InitializationSettings(
    android: android,
  );

  await flutterLocalNotificationsPlugin.initialize(
    initSettings,
    onDidReceiveNotificationResponse: onNotificationResponse,
  );
}

Future<void> onNotificationResponse(NotificationResponse response) async {
  print("onNotificationResponse");
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return;

  final userDoc =
  FirebaseFirestore.instance.collection('users').doc(uid);

  final now = DateTime.now();
  print("🔔 NotificationResponse received:");
  print("  type=${response.notificationResponseType}");
  print("  actionId=${response.actionId}");

  // User tapped the notification body
  if (response.notificationResponseType ==
      NotificationResponseType.selectedNotification) {
    print("User tapped the notification body");
    await userDoc.update({
      "lastNotificationAction": now,
      "lastAction": "notification_clicked",
    });
    return;
  }

  // User tapped the "I'm Done" button
  if (response.actionId == "DISMISS_ACTION") {
    print("User tapped the Im Done button");
    await userDoc.update({
      "lastNotificationAction": now,
      "lastAction": "pressed_done_button",
    });
    return;
  }
}



void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // 🟠 Initialize notifications ONLY on mobile
  if (!kIsWeb) {
    initNotifications();
   /* const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const settings = InitializationSettings(android: androidInit, iOS: iosInit);
    await flutterLocalNotificationsPlugin.initialize(settings,
        onDidReceiveNotificationResponse: onNotificationResponse);*/
  }

  runApp(const MyApp());
}

/// 🔔 Schedule Test Notification (MOBILE ONLY)
Future<void> scheduleTestNotification() async {
  if (kIsWeb) return; // ⛔ No notifications on Web

  const androidDetails = AndroidNotificationDetails(
    'test_channel',
    'Test Channel',
    importance: Importance.max,
    priority: Priority.high,
  );

  const details = NotificationDetails(android: androidDetails);

  final now = tz.TZDateTime.now(tz.local);
  final reminderTime = now.add(const Duration(minutes: 2));

  await flutterLocalNotificationsPlugin.zonedSchedule(
    1,
    'Test Notification',
    'If you see this, notifications work!',
    reminderTime,
    details,
    uiLocalNotificationDateInterpretation:
    UILocalNotificationDateInterpretation.absoluteTime,
    androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
  );
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
            return EmailVerificationPage(user: pendingVerificationUser!);
          }

          if (user != null && user.emailVerified) {
            if (!kIsWeb) scheduleDailyAttendanceReminder();
            return const AttendanceForm();
          }

          return AuthPage(); // pass callback
        },
      ),
    );
  }
}


/// 🕙 DAILY REMINDER — Mobile Only
Future<void> scheduleDailyAttendanceReminder() async {
  if (kIsWeb) return;

  tz.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Asia/Kolkata'));

  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return;

  final today = DateTime.now();
  final dateStr =
      "${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}";

  final firestore = FirebaseFirestore.instance;

  // 1️⃣ Skip Sunday
  if (today.weekday == DateTime.sunday) return;

  // 2️⃣ Skip 2nd & 4th Saturday
  if (today.weekday == DateTime.saturday) {
    int count = 0;
    for (int i = 1; i <= today.day; i++) {
      if (DateTime(today.year, today.month, i).weekday == DateTime.saturday) {
        count++;
      }
    }
    if (count == 2 || count == 4) return;
  }

  // 3️⃣ Holiday check
  final holidayDoc = await firestore.collection('holidays').doc(dateStr).get();
  if (holidayDoc.exists) return;

  // 4️⃣ Leave check
  final leaves = await firestore
      .collection('leaves')
      .where('userId', isEqualTo: uid)
      .where('status', isEqualTo: 'Approved')
      .get();

  for (var l in leaves.docs) {
    final start = (l['startDate'] as Timestamp).toDate();
    final end = (l['endDate'] as Timestamp).toDate();

    if (!today.isBefore(start) && !today.isAfter(end)) {
      return;
    }
  }

  // Notification config
  const androidDetails = AndroidNotificationDetails(
    'attendance_reminder_channel',
    'Attendance Reminder',
    importance: Importance.max,
    priority: Priority.high,
    actions: [
      AndroidNotificationAction(
        'DISMISS_ACTION',
        'I’m Done ✅',
        showsUserInterface: true,
        cancelNotification: true,
      ),
    ],
  );

  const details = NotificationDetails(android: androidDetails);

  final now = tz.TZDateTime.now(tz.local);
  var scheduleTime = tz.TZDateTime(tz.local, now.year, now.month, now.day, 10);
  // for testing
 // var scheduleTime = now.add(const Duration(minutes: 1));
  // If it's already past 10 AM: remind next day
  if (scheduleTime.isBefore(now)) {
    scheduleTime = scheduleTime.add(const Duration(days: 1));
  }

  // ❗ DO NOT cancel all notifications → allows tomorrow's reminder
  await flutterLocalNotificationsPlugin.zonedSchedule(
    101, // use a consistent ID
    'Attendance Reminder',
    'Please mark your attendance 📸',
    scheduleTime,
    details,
    uiLocalNotificationDateInterpretation:
    UILocalNotificationDateInterpretation.absoluteTime,
    androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    matchDateTimeComponents: DateTimeComponents.time, // 🔥 repeats daily
  );
}


// class AttendanceApp extends StatelessWidget {
//   const AttendanceApp({super.key});
//
//   @override
//   Widget build(BuildContext context) {
//     return const Scaffold(
//       body: AttendanceForm(),
//     );
//   }
// }
/// 🧍 Authentication page (your existing AuthPage)

