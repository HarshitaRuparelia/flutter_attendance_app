import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart'; // for kIsWeb
import 'package:flutter/material.dart';
import 'attendance_form.dart'; // your home page
import 'logger.dart';

class EmailVerificationPage extends StatefulWidget {
  final User user;
  const EmailVerificationPage({required this.user, super.key});

  @override
  State<EmailVerificationPage> createState() => _EmailVerificationPageState();
}

class _EmailVerificationPageState extends State<EmailVerificationPage> {
  bool _loading = false;

  /// Check if email is verified
  Future<void> checkVerification() async {
    setState(() => _loading = true);

    try {
      // Refresh user data
      await widget.user.reload();
      final user = FirebaseAuth.instance.currentUser!;

      if (user.emailVerified) {
        // Update Firestore
        await FirebaseFirestore.instance
            .collection("users")
            .doc(user.uid)
            .update({"isEmailVerified": true});

        AppLogger.log(
          event: "Navigate → AttendanceForm",
          uid: user.uid,
        );

        // Navigate to home safely
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const AttendanceForm()),
        );
      } else {
        AppLogger.log(
          event: "Email Not Yet Verified",
          uid: user.uid,
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Email not verified yet.")),
        );
      }
    } catch (e) {
      AppLogger.log(
        event: "Check Verification FAILED",
        uid: widget.user.uid,
        data: {"error": e.toString()},
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error checking verification: $e")),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Resend verification email (different for Web vs Mobile)
  Future<void> resendVerificationEmail() async {
    setState(() => _loading = true);

    try {
      AppLogger.log(
        event: "Resend Verification Email Clicked",
        uid: widget.user.uid,
      );
      final user = FirebaseAuth.instance.currentUser!;   // <-- IMPORTANT
      await user.sendEmailVerification();

      AppLogger.log(
        event: "Resend Verification Email SUCCESS",
        uid: user.uid,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Verification email sent.")),
      );

    } catch (e) {
      AppLogger.log(
        event: "Resend Verification Email FAILED",
        uid: widget.user.uid,
        data: {"error": e.toString()},
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error sending verification email: $e")),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.orange.shade50,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text(
          "H S D R And Associates Taxteck",
          style: TextStyle(fontWeight: FontWeight.bold),
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
        shape: const Border(bottom: BorderSide(color: Colors.black, width: 1)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
            Text(
            "Verify Your Email",
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.orangeAccent,
            ),
          ),
          const SizedBox(height: 16),
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
                    Icons.mark_email_read_rounded, // ✅ Email verification icon
                    size: 70,
                    color: Colors.orangeAccent,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    "A verification link has been sent to your email.\n \n "
                        "Please click the link to verify your account.",
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Colors.black87),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _loading ? null : () async {
                        AppLogger.log(
                          event: "Pressed: I have verified",
                          uid: widget.user.uid,
                        );
                        await checkVerification();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orangeAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _loading
                          ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                          : const Text(
                        "I have verified",
                        style: TextStyle(
                            color: Colors.black45,
                            fontSize: 16,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _loading ? null : resendVerificationEmail,
                    child: const Text(
                      "Resend verification email",
                      style: TextStyle(color: Colors.orangeAccent),
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
