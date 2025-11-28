import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final emailController = TextEditingController();
  bool _loading = false;
  bool isEmailValid = false;

  final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');

  Future<bool> doesUserExist(String email) async {
    final result = await FirebaseFirestore.instance
        .collection("users")
        .where("email", isEqualTo: email.trim())
        .limit(1)
        .get();

    return result.docs.isNotEmpty;
  }

  Future<void> resetPassword() async {
    final email = emailController.text.trim();

    if (!isEmailValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter a valid email.")),
      );
      return;
    }

    setState(() => _loading = true);

    // 🔍 Check in Firestore before sending reset email
    final exists = await doesUserExist(email);

    if (!exists) {

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("This email is not registered.")),
      );
      return;
    }

    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Password reset email sent to $email")),
      );

      Navigator.pop(context);
    } on FirebaseAuthException catch (e) {
      String msg;
      switch (e.code) {
        case "invalid-email":
          msg = "Invalid email format.";
          break;
        case "user-not-found":
          msg = "No account found with this email.";
          break;
        default:
          msg = e.message ?? "Error sending reset email.";
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
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
              "Forgot Password",
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.orangeAccent,
              ),
            ),
            const SizedBox(height: 16),
          Card(
            elevation: 6,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                     Icons.lock_reset_rounded,
                    color: Colors.orangeAccent,
                    size: 70,
                  ),
                  const SizedBox(height: 16),
            const Text(
              "Enter your email and we'll send you a password reset link.",
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),

            TextField(
              controller: emailController,
              onChanged: (value) {
                setState(() {
                  isEmailValid = emailRegex.hasMatch(value.trim());
                });
              },
              decoration: InputDecoration(
                labelText: "Email",
                prefixIcon: const Icon(Icons.email_outlined, color: Colors.orangeAccent),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                errorText: emailController.text.isEmpty
                    ? null
                    : (isEmailValid ? null : "Invalid email"),
              ),
              keyboardType: TextInputType.emailAddress,
            ),

            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: (!isEmailValid || _loading) ? null : resetPassword,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isEmailValid ? Colors.orangeAccent : Colors.grey,
                ),
                child: _loading
                    ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                    : const Text("Reset Password"),
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
