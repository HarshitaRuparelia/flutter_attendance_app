import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // <-- IMPORTANT FOR kIsWeb
import 'attendance_form.dart';
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

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          if (snapshot.hasData) {
            // 🟢 Schedule attendance reminder ONLY on mobile
            if (!kIsWeb) {
              scheduleDailyAttendanceReminder();
            }
            return const AttendanceApp();
          }

          return const AuthPage();
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


class AttendanceApp extends StatelessWidget {
  const AttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: AttendanceForm(),
    );
  }
}
/// 🧍 Authentication page (your existing AuthPage)
class AuthPage extends StatefulWidget {
  const AuthPage({super.key});
  @override
  _AuthPageState createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  bool isLogin = true;
  bool _loading = false;
  bool _obscurePassword = true;

  Future<void> signupUser(String email, String password, String name, String phone) async {
    try {
      setState(() => _loading = true);
      UserCredential userCredential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);

      String uid = userCredential.user!.uid;

      await FirebaseFirestore.instance.collection("users").doc(uid).set({
        "uid": uid,
        "email": email,
        "name": name,
        "phone": phone,
        "createdAt": FieldValue.serverTimestamp(),
      });
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Signup failed: $e")));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Please fill all required fields")));
      return;
    }

    setState(() => _loading = true);

    try {
      if (isLogin) {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );
      } else {
        await signupUser(
          _emailController.text.trim(),
          _passwordController.text.trim(),
          _nameController.text.trim(),
          _phoneController.text.trim(),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.orange.shade50,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(
          "H S D R And Associates Taxteck",
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.deepOrange, Colors.orangeAccent],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        shape: const Border(
          bottom: BorderSide(color: Colors.black, width: 1),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
        child: Center(
          child: Column(
            children: [
              // Login / SignUp header text below AppBar
              Text(
                isLogin ? "Login" : "Sign Up",
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.orangeAccent,
                ),
              ),
              const SizedBox(height: 16),

              // Card with the actual form
              Card(
                elevation: 6,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isLogin ? Icons.lock_open_rounded : Icons.person_add_alt_1_rounded,
                        color: Colors.orangeAccent,
                        size: 70,
                      ),
                      const SizedBox(height: 16),

                      if (!isLogin)
                        TextField(
                          controller: _nameController,
                          decoration: InputDecoration(
                            labelText: "Full Name",
                            prefixIcon: const Icon(Icons.person_outline, color: Colors.orangeAccent),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      if (!isLogin) const SizedBox(height: 16),

                      if (!isLogin)
                        TextField(
                          controller: _phoneController,
                          decoration: InputDecoration(
                            labelText: "Phone Number",
                            prefixIcon: const Icon(Icons.phone_outlined, color: Colors.orangeAccent),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          keyboardType: TextInputType.phone,
                        ),
                      if (!isLogin) const SizedBox(height: 16),

                      TextField(
                        controller: _emailController,
                        decoration: InputDecoration(
                          labelText: "Email",
                          prefixIcon: const Icon(Icons.email_outlined, color: Colors.orangeAccent),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        keyboardType: TextInputType.emailAddress,
                      ),
                      const SizedBox(height: 16),

                      TextField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        decoration: InputDecoration(
                          labelText: "Password",
                          prefixIcon: const Icon(Icons.lock_outline, color: Colors.orangeAccent),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword ? Icons.visibility_off : Icons.visibility,
                              color: Colors.orange,
                            ),
                            onPressed: () {
                              setState(() {
                                _obscurePassword = !_obscurePassword;
                              });
                            },
                          ),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: 24),

                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orangeAccent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _loading
                              ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                              : Text(
                            isLogin ? "Login" : "Sign Up",
                            style: const TextStyle(
                                color: Colors.black45,
                                fontSize: 16,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      TextButton(
                        onPressed: () => setState(() => isLogin = !isLogin),
                        child: Text(
                          isLogin
                              ? "Don't have an account? Sign Up"
                              : "Already have an account? Login",
                          style: const TextStyle(fontSize: 15, color: Colors.orangeAccent),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),

    );
  }
}

