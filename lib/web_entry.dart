import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'attendance_form.dart';
import 'auth_page.dart';
import 'email_verification.dart';

class WebEntry extends StatelessWidget {
  const WebEntry({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const AuthPage();
        }

        final user = snapshot.data!;

        if (!user.emailVerified) {
          return const EmailVerificationPage();
        }

        return const AttendanceForm();
      },
    );
  }
}
