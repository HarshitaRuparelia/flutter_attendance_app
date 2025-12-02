import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'email_verification.dart';
import 'attendance_form.dart';
import 'forgot_password_page.dart';
import 'logger.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});
  @override
  _AuthPageState createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();

  bool isLogin = true;
  bool _loading = false;
  bool _obscurePassword = true;

  bool isValidEmail(String email) {
    final regex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    return regex.hasMatch(email);
  }
  bool isStrongPassword(String password) {
    // At least 8 chars, 1 uppercase, 1 lowercase, 1 digit, 1 special char
    final regex = RegExp(r'^(?=.*?[A-Z])(?=.*?[a-z])(?=.*?[0-9])(?=.*?[!@#\$&*~]).{8,}$');
    return regex.hasMatch(password);
  }
  String cleanErrorMessage(dynamic e) {
    if (e is FirebaseAuthException) return e.message ?? "Authentication error";
    return e.toString().replaceFirst("Exception: ", "");
  }

  Future<void> signupUser(String email, String password, String name) async {
    try {
      setState(() => _loading = true);
      UserCredential userCredential;
      // 1️⃣ Create Firebase user
      try {
        // Firebase automatically prevents duplicate emails
         userCredential = await FirebaseAuth.instance
            .createUserWithEmailAndPassword(email: email, password: password);
      } on FirebaseAuthException catch (e) {
        if (e.code == "email-already-in-use") {
          throw "This email is already registered. Please login.";
        } else {
          throw e.message ?? "Signup failed.";
        }
      }

      final user = userCredential.user!;

      // 2️⃣ Save user info in Firestore
      await FirebaseFirestore.instance.collection("users").doc(user.uid).set({
        "uid": user.uid,
        "email": email,
        "name": name,
        "createdAt": FieldValue.serverTimestamp(),
      });
      AppLogger.log(event: "Signup Success and mail sent ", uid: user.uid, data: {
        "email": email,
        "name": name,
      });
      await user.sendEmailVerification();   // ← REQUIRED

      // 3️⃣ Navigate to Email Verification Page
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => EmailVerificationPage(user: FirebaseAuth.instance.currentUser!)),
      );

    } catch (e) {
      AppLogger.log(event: "Signup Failed", data: {
        "email": email,
        "name": name,
        "error": e.toString(),
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(cleanErrorMessage(e))),
      );
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final name = _nameController.text.trim();

    if (email.isEmpty || password.isEmpty || (!isLogin && name.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please fill all required fields")),
      );
      return;
    }

    if (!isValidEmail(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter a valid email")),
      );
      return;
    }

    // 🔥 STRONG PASSWORD CHECK (Signup only)
    if (!isLogin && !isStrongPassword(password)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "Password must be 8+ chars, include upper, lower, digit & special character"),
        ),
      );
      return;
    }

    setState(() => _loading = true);

    try {
      if (isLogin) {
        // LOGIN
        AppLogger.log(event: "Login Attempt", data: {
          "email": email,
        });
        final userCredential =
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );

        final user = userCredential.user!;

        if (!user.emailVerified) {
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  EmailVerificationPage(user: FirebaseAuth.instance.currentUser!),
            ),
          );
          return;
        }

        if (!mounted) return;
        AppLogger.log(event: "Login Success", uid: user.uid);
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const AttendanceForm()),
        );
      } else {
        AppLogger.log(event: "Signup Attempt", data: {
          "email": email,
          "name": name,
        });
        // SIGNUP
        await signupUser(email, password, name);
      }
    } catch (e) {
      AppLogger.log(event: "Login Failed", data: {
        "email": email,
        "error": e.toString(),
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(cleanErrorMessage(e))),
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
            children: [
              Text(
                isLogin ? "Login" : "Sign Up",
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
                              setState(() => _obscurePassword = !_obscurePassword);
                            },
                          ),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      if (isLogin)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () {
                              AppLogger.log(event: "Forgot Password Clicked", data: {
                                "email_field": _emailController.text.trim(),
                              });
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => const ForgotPasswordPage()),
                              );
                            },
                            child: const Text("Forgot Password?"),
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
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: _loading
                              ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                              : Text(
                            isLogin ? "Login" : "Sign Up",
                            style: const TextStyle(
                                color: Colors.black45, fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextButton(
                      onPressed: () {
                        AppLogger.log(event: isLogin ? "Go to Signup" : "Go to Login");
                         setState(() => isLogin = !isLogin);
                        },
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
