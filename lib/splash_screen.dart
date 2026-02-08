import 'dart:io';
import 'package:attendance_app_new/attendance_form.dart';
import 'package:attendance_app_new/auth_page.dart';
import 'package:attendance_app_new/email_verification.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'logger.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;
  String _status = "Checking app status...";

  @override
  void initState() {
    super.initState();
    AppLogger.log(
      event: "Splash started",
      uid: _uid,
    );
    _startChecks();
  }

  Future<void> _startChecks() async {
    try {
      setState(() => _status = "Checking internet...");

      // 1️⃣ Check internet
      final hasInternet = await _hasInternet();

      AppLogger.log(
        event: "Internet check",
        uid: _uid,
        data: {
          "connected": hasInternet,
        },
      );

      if (!hasInternet) {
        _showError("No Internet", "Internet connection is required to start the app.");
        return;
      }

      setState(() => _status = "Checking app version...");

      // 2️⃣ Check app version
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;
      AppLogger.log(
        event: "Current app version",
        uid: _uid,
        data: {
          "version": currentVersion,
        },
      );

      final snap = await FirebaseFirestore.instance
          .collection("app_config")
          .doc("version_info")
          .get();

      if (snap.exists) {
        final latestVersion = snap["latest_version"] as String;
        final apkUrl = snap["apk_url"] as String?;
        final msg = snap["message"] as String? ?? "Please update the app.";

        AppLogger.log(
          event: "Version info fetched",
          uid: _uid,
          data: {
            "current": currentVersion,
            "latest": latestVersion,
            "build": packageInfo.buildNumber,
          },
        );

        if (_isUpdateRequired(currentVersion, latestVersion)) {
          print("show update dialog");
          _showUpdateDialog(latestVersion: latestVersion, message: msg, apkUrl: apkUrl);
          return;
        }
      }
      else {
        AppLogger.log(event: "App up to date", uid: _uid);
      }

      // 3️⃣ Small delay for UX
      await Future.delayed(const Duration(seconds: 1));

      setState(() => _status = "Checking authentication...");

      final user = FirebaseAuth.instance.currentUser;

      // 4️⃣ Track installed version in Firestore
      if (user != null) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .set({
          'last_installed_version': currentVersion,
          'last_seen': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      // Check auth
      if (user == null) {
        AppLogger.log(event: "Navigate → AuthPage", uid: _uid);
        _navigateTo(const AuthPage());
        return;
      }

      // IMPORTANT: reload user to get latest verification state
      await user.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;

      if (!refreshedUser!.emailVerified) {
        AppLogger.log(
          event: "Navigate → EmailVerificationPage",
          uid: refreshedUser.uid,
        );
        _navigateTo(const EmailVerificationPage());
        return;
      }

      // ✅ If verified → sync Firestore
      await FirebaseFirestore.instance
          .collection('users')
          .doc(refreshedUser.uid)
          .set({
        'isEmailVerified': true,
        'emailVerifiedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      AppLogger.log(
        event: "Email verified & synced",
        uid: refreshedUser.uid,
      );

      AppLogger.log(
        event: "Navigate → AttendanceForm",
        uid: user.uid,
      );

      // ✅ Logged in & verified
      _navigateTo(const AttendanceForm());
    } catch (e, st) {
      AppLogger.log(
        event: "Splash error",
        uid: _uid,
        data: {
          "error": e.toString(),
          "stack": st.toString(),
        },
      );
      _showError("Error", e.toString());
    }
  }

  // ----------------------------
  // 🔢 Version comparison
  // ----------------------------
  bool _isUpdateRequired(String current, String latest) {
    final c = current.split('.').map(int.parse).toList();
    final l = latest.split('.').map(int.parse).toList();
    for (int i = 0; i < l.length; i++) {
      if (c.length <= i || c[i] < l[i]) return true;
      if (c[i] > l[i]) return false;
    }
    return false;
  }

  // ----------------------------
  // 🌐 Internet check
  // ----------------------------
  Future<bool> _hasInternet() async {
    try {
      final result = await InternetAddress.lookup('google.com').timeout(const Duration(seconds: 3));
      return result.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // ----------------------------
  // 🚀 Navigation
  // ----------------------------
  void _navigateTo(Widget page) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => page),
    );
  }

  // ----------------------------
  // 🔔 Update dialog
  // ----------------------------
  void _showUpdateDialog({
    required String latestVersion,
    required String message,
    String? apkUrl,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text("Update Required"),
        content: Text("$message\n\nLatest Version: $latestVersion"),
        actions: [
          ElevatedButton(
            onPressed: () async {
              AppLogger.log(
                event: "Update button clicked",
                uid: _uid,
                data: {
                  "apkUrl": apkUrl,
                },
              );
              final uri = Uri.parse(apkUrl!);
              final launched = await launchUrl(uri, mode: LaunchMode.externalApplication,);

              AppLogger.log(
                event: launched ? "APK launched" : "APK launch failed",
                uid: _uid,
                data: {
                  "apkUrl": apkUrl,
                },
              );
            },
            child: const Text("Update Now"),
          )

        ],
      ),
    );
  }

  // ----------------------------
  // ❌ Error dialog
  // ----------------------------
  void _showError(String title, String msg) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(msg),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _startChecks(); // retry
            },
            child: const Text("Retry"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.verified_user, size: 60),
            const SizedBox(height: 20),
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(_status),
          ],
        ),
      ),
    );
  }
}
