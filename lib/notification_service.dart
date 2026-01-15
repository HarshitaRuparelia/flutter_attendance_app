import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'firebase_options.dart';
import 'logger.dart';
import 'package:permission_handler/permission_handler.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
FlutterLocalNotificationsPlugin();

Future<void> initNotifications() async {
  print("initNotifications");
  tz.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Asia/Kolkata'));
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');

  const initSettings = InitializationSettings(
    android: android,
  );

  await flutterLocalNotificationsPlugin.initialize(
    initSettings,
    onDidReceiveNotificationResponse: onNotificationResponse,
  );

  if (await Permission.notification.isDenied) {
    await Permission.notification.request();
  }
}
Future<void> onNotificationResponse(NotificationResponse response) async {
  try {
    AppLogger.log(event: "onNotificationResponse called");
    WidgetsFlutterBinding.ensureInitialized();

    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      AppLogger.log(event: "No logged-in user");
      return;
    }
   // if (uid == null) return;
    final uid = user.uid;
    final userDoc =
    FirebaseFirestore.instance.collection('users').doc(uid);

    final now = DateTime.now();
    AppLogger.log(event:"NotificationResponse received:");
    AppLogger.log(event:"  type=${response.notificationResponseType}");
    AppLogger.log(event:"  actionId=${response.actionId}");

    // User tapped the notification body
    if (response.notificationResponseType ==
        NotificationResponseType.selectedNotification) {
      print("User tapped the notification body");
      await userDoc.update({
        "lastNotificationAction": now,
        "lastAction": "notification_clicked",
      });
      AppLogger.log(event: "Notification clicked", uid: uid);
      return;
    }

    // User tapped the "I'm Done" button
    if (response.actionId == "DISMISS_ACTION") {
      print("User tapped the Im Done button");
      await userDoc.update({
        "lastNotificationAction": now,
        "lastAction": "pressed_done_button",
      });
      AppLogger.log(event: "User tapped the Done button", uid: uid);
      return;
    }
  }
  catch (e, s) {
    AppLogger.log(
      event: "_getLocation() Exception***",
      data: {"error": e.toString()},
    );
    debugPrintStack(stackTrace: s);
  }
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
