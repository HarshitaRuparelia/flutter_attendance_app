import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'attendance_form.dart';
import 'firebase_options.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Optionally enable Firebase App Check (for production security)
  await FirebaseAppCheck.instance.activate();

  runApp(MyApp());
  //await scheduleTestNotification();
}
Future<void> scheduleTestNotification() async {
  const androidDetails = AndroidNotificationDetails(
    'attendance_reminder_channel',
    'Attendance Reminder',
    channelDescription: 'Daily reminder to mark attendance at 10 AM',
    importance: Importance.max,
    priority: Priority.high,
  );
  const details = NotificationDetails(android: androidDetails);

  final now = tz.TZDateTime.now(tz.local);
  final reminderTime = now.add(const Duration(minutes: 2));

  print("Scheduling notification at $reminderTime");

  await flutterLocalNotificationsPlugin.zonedSchedule(
    0,
    'Attendance Reminder',
    'Please mark your attendance 📸',
    reminderTime,
    details,
    androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    uiLocalNotificationDateInterpretation:
    UILocalNotificationDateInterpretation.absoluteTime,
    matchDateTimeComponents: DateTimeComponents.time,
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Attendance Tracker',
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
                body: Center(child: CircularProgressIndicator()));
          }
          if (snapshot.hasData) {
            // Schedule the daily 10AM reminder once user is logged in
            scheduleDailyAttendanceReminder();
            /* test notification */
             /*flutterLocalNotificationsPlugin.show(
              1,
              'Test Notification',
              'If you see this, notifications work!',
              const NotificationDetails(
                android: AndroidNotificationDetails(
                  'test_channel',
                  'Test Channel',
                  importance: Importance.max,
                  priority: Priority.high,
                ),
              ),
            );*/

            return const AttendanceApp();
          }
          return AuthPage();
        },
      ),
    );
  }
}

/// 🕙 Schedules a daily reminder notification at 10 AM
/// 🕙 Schedules a daily 10 AM reminder notification with a dismiss action
Future<void> scheduleDailyAttendanceReminder() async {
  tz.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Asia/Kolkata'));

  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return;

  final firestore = FirebaseFirestore.instance;
  final today = DateTime.now();
  final todayStr =
      "${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}";

  // 🔹 1️⃣ Skip reminder on Sundays
  if (today.weekday == DateTime.sunday) {
    debugPrint("📆 Skipping reminder — Sunday.");
    return;
  }

  // 🔹 2️⃣ Skip reminder on 2nd or 4th Saturday
  if (today.weekday == DateTime.saturday) {
    // Find which Saturday of the month it is
    final firstDayOfMonth = DateTime(today.year, today.month, 1);
    int saturdayCount = 0;
    for (int i = 1; i <= today.day; i++) {
      final d = DateTime(today.year, today.month, i);
      if (d.weekday == DateTime.saturday) saturdayCount++;
    }

    if (saturdayCount == 2 || saturdayCount == 4) {
      debugPrint("📆 Skipping reminder — ${saturdayCount}th Saturday.");
      return;
    }
  }

  // 🔹 3️⃣ Skip reminder if it's a holiday
  final holidayDoc = await firestore.collection('holidays').doc(todayStr).get();
  if (holidayDoc.exists) {
    debugPrint("📆 Skipping reminder — Today ($todayStr) is a holiday.");
    return;
  }

  // 🔹 4️⃣ Skip reminder if user is on approved leave
  final leaveQuery = await firestore
      .collection('leaves')
      .where('userId', isEqualTo: uid)
      .where('status', isEqualTo: 'Approved')
      .get();

  bool onLeaveToday = false;
  for (var doc in leaveQuery.docs) {
    final start = (doc['startDate'] as Timestamp).toDate();
    final end = (doc['endDate'] as Timestamp).toDate();

    if (today.isAfter(start.subtract(const Duration(days: 1))) &&
        today.isBefore(end.add(const Duration(days: 1)))) {
      onLeaveToday = true;
      break;
    }
  }

  if (onLeaveToday) {
    debugPrint("📆 Skipping reminder — User is on approved leave today.");
    return;
  }

  // 🔔 Initialize notifications
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosInit = DarwinInitializationSettings();
  const initSettings =
  InitializationSettings(android: androidInit, iOS: iosInit);

  await flutterLocalNotificationsPlugin.initialize(
    initSettings,
    onDidReceiveNotificationResponse:
        (NotificationResponse response) async {
      if (response.actionId == 'DISMISS_ACTION') {
        debugPrint('✅ User tapped "I’m Done" action');
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null) {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .update({'lastNotificationDismissed': FieldValue.serverTimestamp()});
        }
        await flutterLocalNotificationsPlugin.cancelAll();
      }
    },
  );

  final androidPlugin = flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.requestNotificationsPermission();

  const androidDetails = AndroidNotificationDetails(
    'attendance_reminder_channel',
    'Attendance Reminder',
    channelDescription: 'Daily reminder to mark attendance at 10 AM',
    importance: Importance.max,
    priority: Priority.high,
    playSound: true,
    enableVibration: true,
    actions: <AndroidNotificationAction>[
      AndroidNotificationAction(
        'DISMISS_ACTION',
        'I’m Done ✅',
        showsUserInterface: true,
        cancelNotification: true,
      ),
    ],
  );
  const details = NotificationDetails(android: androidDetails);

  // ⏰ Schedule time
  final now = tz.TZDateTime.now(tz.local);
  var reminderTime = tz.TZDateTime(
    tz.local,
    now.year,
    now.month,
    now.day,
    10, // 10 AM
    0,
  );
  if (reminderTime.isBefore(now)) {
    reminderTime = reminderTime.add(const Duration(days: 1));
  }

  await flutterLocalNotificationsPlugin.cancelAll();

  await flutterLocalNotificationsPlugin.zonedSchedule(
    0,
    'Attendance Reminder',
    'Please mark your attendance for today 📸',
    reminderTime,
    details,
    androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    matchDateTimeComponents: DateTimeComponents.time,
    uiLocalNotificationDateInterpretation:
    UILocalNotificationDateInterpretation.absoluteTime,
  );

  debugPrint("🔔 Reminder scheduled for $reminderTime");
}



/// 🧾 Attendance screen wrapper
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

// Keep your existing AuthPage code as-is below...


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
