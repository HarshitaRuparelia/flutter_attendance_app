import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import 'attendance_history_screen.dart';
import 'leave_screen.dart';

class AttendanceForm extends StatefulWidget {
  const AttendanceForm({super.key});

  @override
  State<AttendanceForm> createState() => _AttendanceFormState();
}

class _AttendanceFormState extends State<AttendanceForm> {
  File? _punchInImage;
  File? _punchOutImage;
  String _punchInAddress = "";
  String _punchOutAddress = "";
  Position? _position;
  bool _loading = false;
  String address = "";
  final User? user = FirebaseAuth.instance.currentUser;
  bool _alreadySubmitted = false;
  DateTime? _submittedTime; // Punch In
  DateTime? _punchOutTime; // Punch Out
  bool _isLate = false;
  String _totalHours = "";
  bool _exemptionRequested = false;

  // ---------------- Helper Methods ----------------

  Future<String> _getUserName() async {
    if (user == null) return "User";
    DocumentSnapshot doc = await FirebaseFirestore.instance
        .collection("users")
        .doc(user!.uid)
        .get();

    if (doc.exists && doc.data() != null) {
      return doc["name"] ?? "User";
    } else {
      return "User";
    }
  }

  Future<void> _captureSelfie({required bool isPunchOut}) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.camera);
    if (picked != null) {
      File imageFile = File(picked.path);
      await _getLocation();
      setState(() {
        if (isPunchOut) {
          _punchOutImage = imageFile;
          _punchOutAddress = address;
        } else {
          _punchInImage = imageFile;
          _punchInAddress = address;
        }
      });
    }
  }

  Future<void> _getLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied) return;

    Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);
    setState(() {
      _position = pos;
    });
    address = await getAddressFromLatLng(_position!);
  }

  Future<String> getAddressFromLatLng(Position position) async {
    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isNotEmpty) {
        final place = placemarks.first;
        return "${place.name}, ${place.street}, ${place.locality}, ${place.administrativeArea}, ${place.postalCode}, ${place.country}";
      } else {
        return "Address not found";
      }
    } catch (e) {
      return "Error: $e";
    }
  }

  Future<XFile?> compressImage(File file) async {
    final targetPath =
        "${file.parent.path}/compressed_${DateTime.now().millisecondsSinceEpoch}.jpg";

    var result = await FlutterImageCompress.compressAndGetFile(
      file.absolute.path,
      targetPath,
      quality: 60,
      format: CompressFormat.jpeg,
    );

    return result;
  }

  Future<void> _checkAttendance() async {
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);

    final snap = await FirebaseFirestore.instance
        .collection("attendance")
        .where("userId", isEqualTo: user?.uid)
        .where("punchInDate", isEqualTo: todayDate)
        .get();

    if (snap.docs.isNotEmpty) {
      final data = snap.docs.first.data();
      setState(() {
        _alreadySubmitted = true;
        _submittedTime = (data["punchInTime"] as Timestamp).toDate();
        _punchOutTime = data["punchOutTime"] != null
            ? (data["punchOutTime"] as Timestamp).toDate()
            : null;
        _isLate = data["isLate"] ?? false;
        if (data["totalHours"] != null) {
          int mins = data["totalHours"];
          _totalHours = "${mins ~/ 60}h ${mins % 60}m";
        }
      });
    }
  }
  Future<void> _checkExemptionStatus() async {
    if (user == null) return;

    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);

    final exemptionSnap = await FirebaseFirestore.instance
        .collection("exemptions")
        .where("userId", isEqualTo: user!.uid)
        .where("date", isGreaterThanOrEqualTo: Timestamp.fromDate(todayDate))
        .where("date", isLessThan: Timestamp.fromDate(todayDate.add(const Duration(days: 1))))
        .get();

    if (exemptionSnap.docs.isNotEmpty) {
      setState(() {
        _exemptionRequested = true;
      });
    }
  }


  Future<void> _submitAttendance() async {
    if (_punchInImage == null || _position == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Please take selfie & location")));
      return;
    }

    DateTime now = DateTime.now();
    DateTime allowedTime = DateTime(now.year, now.month, now.day, 9, 0);
    if (now.isBefore(allowedTime)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Punch In allowed only after 9:00 AM")),
      );
      return;
    }


    setState(() => _loading = true);

    try {
      final compressedSelfie = await compressImage(_punchInImage!);
      if (compressedSelfie == null) throw Exception("Image compression failed");

      final ref = FirebaseStorage.instance
          .ref()
          .child("selfies/punchin_${DateTime.now().millisecondsSinceEpoch}.jpg");
      File file = File(compressedSelfie.path);
      await ref.putFile(file);
      final selfieUrl = await ref.getDownloadURL();

      DateTime now = DateTime.now();
      DateTime cutoff = DateTime(now.year, now.month, now.day, 10, 15);
      bool isLate = now.isAfter(cutoff);

      await FirebaseFirestore.instance.collection("attendance").add({
        "userId": user?.uid,
        "punchInLatitude": _position!.latitude,
        "punchInLongitude": _position!.longitude,
        "punchInAddress": _punchInAddress,
        "punchInTime": now,
        "punchInDate": DateTime(now.year, now.month, now.day),
        "punchInSelfieUrl": selfieUrl,
        "isLate": isLate,
      });

      setState(() {
        _submittedTime = now;
        _alreadySubmitted = true;
        _isLate = isLate;
      });

      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Punch In successful ✅")));
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Error: $e")));
    }

    setState(() => _loading = false);
  }

  Future<void> _punchOut() async {
    if (_punchOutImage == null || _position == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Please take selfie & location")));
      return;
    }

    setState(() => _loading = true);

    try {
      final compressedSelfie = await compressImage(_punchOutImage!);
      if (compressedSelfie == null) throw Exception("Image compression failed");

      final ref = FirebaseStorage.instance
          .ref()
          .child("selfies/punchout_${DateTime.now().millisecondsSinceEpoch}.jpg");
      File file = File(compressedSelfie.path);
      await ref.putFile(file);
      final selfieUrl = await ref.getDownloadURL();

      final today = DateTime.now();
      final todayDate = DateTime(today.year, today.month, today.day);

      final snap = await FirebaseFirestore.instance
          .collection("attendance")
          .where("userId", isEqualTo: user?.uid)
          .where("punchInDate", isEqualTo: todayDate)
          .get();

      if (snap.docs.isNotEmpty) {
        DateTime punchOutTime = DateTime.now();
        Duration totalHours = punchOutTime.difference(_submittedTime!);

        await FirebaseFirestore.instance
            .collection("attendance")
            .doc(snap.docs.first.id)
            .update({
          "punchOutTime": punchOutTime,
          "punchOutSelfieUrl": selfieUrl,
          "punchOutLatitude": _position!.latitude,
          "punchOutLongitude": _position!.longitude,
          "punchOutAddress": _punchOutAddress,
          "totalHours": totalHours.inMinutes,
        });

        setState(() {
          _punchOutTime = punchOutTime;
          _totalHours = "${totalHours.inHours}h ${totalHours.inMinutes % 60}m";
        });

        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Punch Out successful ✅")));
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Error: $e")));
    }

    setState(() => _loading = false);
  }

  Future<void> _requestExemption() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || _submittedTime == null || _punchOutTime == null) return;

      final duration = _punchOutTime!.difference(_submittedTime!);
      final hours = duration.inHours;
      final minutes = duration.inMinutes.remainder(60);
      final totalHours = "$hours h $minutes m";

      await FirebaseFirestore.instance.collection('exemptions').add({
        'userId': user.uid,
        'date': Timestamp.fromDate(DateTime(
          _submittedTime!.year,
          _submittedTime!.month,
          _submittedTime!.day,
        )),
        'totalHours': totalHours,
        'reason': 'Worked less than 9 hours',
        'status': 'Pending',
        'requestedAt': Timestamp.now(),
      });

      setState(() {
        _exemptionRequested = true; // new state variable
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Exemption request sent to Admin ✅')),
      );
    } catch (e) {
      print("Error submitting exemption: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }


  Future<void> _applyLeave() async {
    DateTimeRange? selectedRange = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 90)),
      initialDateRange: DateTimeRange(
        start: DateTime.now(),
        end: DateTime.now(),
      ),
      helpText: "Select leave date(s)",
    );

    if (selectedRange == null) return;

    DateTime startDate = selectedRange.start;
    DateTime endDate = selectedRange.end;

    final userId = user?.uid;
    if (userId == null) return;

    try {
      QuerySnapshot existing = await FirebaseFirestore.instance
          .collection("leaves")
          .where("userId", isEqualTo: userId)
          .where("startDate", isLessThanOrEqualTo: endDate)
          .where("endDate", isGreaterThanOrEqualTo: startDate)
          .get();

      if (existing.docs.isNotEmpty) {
        var leave = existing.docs.first.data() as Map<String, dynamic>;
        String status = leave["status"] ?? "Pending";
        DateTime existingStart = (leave["startDate"] as Timestamp).toDate();
        DateTime existingEnd = (leave["endDate"] as Timestamp).toDate();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "⚠️ You already applied leave from "
                  "${existingStart.day}-${existingStart.month}-${existingStart.year} "
                  "to ${existingEnd.day}-${existingEnd.month}-${existingEnd.year}\n"
                  "Status: $status",
            ),
            duration: const Duration(seconds: 5),
          ),
        );
        return;
      }

      await FirebaseFirestore.instance.collection("leaves").add({
        "userId": userId,
        "startDate": DateTime(startDate.year, startDate.month, startDate.day),
        "endDate": DateTime(endDate.year, endDate.month, endDate.day),
        "timestamp": DateTime.now(),
        "status": "Pending",
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            startDate == endDate
                ? "✅ Leave applied for ${startDate.day}-${startDate.month}-${startDate.year}"
                : "✅ Leave applied from ${startDate.day}-${startDate.month}-${startDate.year} to ${endDate.day}-${endDate.month}-${endDate.year}",
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Error applying leave: $e")));
    }
  }

  @override
  void initState() {
    super.initState();
    _checkAttendance();
    _checkExemptionStatus();
  }

  // ------------------- Build UI -------------------

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _getUserName(),
      builder: (context, snapshot) {
        String title = "Attendance Monitoring System";
        if (snapshot.connectionState == ConnectionState.done && snapshot.hasData) {
          title = "Welcome ${snapshot.data}";
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w400)),
            backgroundColor: Colors.orangeAccent,
          ),
          drawer: Drawer(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                UserAccountsDrawerHeader(
                  decoration: const BoxDecoration(color: Colors.orangeAccent),
                  accountName: Text(snapshot.data ?? "User"),
                  accountEmail: Text(FirebaseAuth.instance.currentUser?.email ?? ""),
                  currentAccountPicture: const CircleAvatar(
                    backgroundColor: Colors.white,
                    child: Icon(Icons.person, size: 40, color: Colors.orange),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.calendar_month, color: Colors.orange),
                  title: const Text("Leave Requests"),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const LeaveScreen()),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.history, color: Colors.orange),
                  title: const Text("Attendance History"),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AttendanceHistoryScreen()),
                    );
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.logout, color: Colors.red),
                  title: const Text("Logout"),
                  onTap: () => FirebaseAuth.instance.signOut(),
                ),
              ],
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Card(
                  elevation: 3,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Attendance",
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),

                        // Punch In Row
                        Row(
                          children: [
                            const Icon(Icons.login, color: Colors.green),
                            const SizedBox(width: 8),
                            Text(
                              _submittedTime != null
                                  ? "Punch In: ${DateFormat('dd MMM, hh:mm a').format(_submittedTime!)}"
                                  : "Punch In: Not yet",
                            ),
                          ],
                        ),

                        if (_isLate)
                          const Text("⚠️ Late Punch In", style: TextStyle(color: Colors.red)),

                        // Punch In Image & Address
                        if (_punchInImage != null)
                          Column(
                            children: [
                              const SizedBox(height: 8),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(_punchInImage!, height: 120),
                              ),
                              const SizedBox(height: 4),
                              if (_punchInAddress.isNotEmpty)
                                Text("📍 Address: $_punchInAddress",
                                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                                    textAlign: TextAlign.center),
                            ],
                          ),

                        const SizedBox(height: 12),

                        // Punch Out Row
                        Row(
                          children: [
                            const Icon(Icons.logout, color: Colors.red),
                            const SizedBox(width: 8),
                            Text(
                              _punchOutTime != null
                                  ? "Punch Out: ${DateFormat('dd MMM, hh:mm a').format(_punchOutTime!)}"
                                  : "Punch Out: Not yet",
                            ),
                          ],
                        ),

                        // ✅ Calculate total working hours
                        Builder(builder: (context) {
                          if (_submittedTime != null && _punchOutTime != null) {
                            final duration = _punchOutTime!.difference(_submittedTime!);
                            final hours = duration.inHours;
                            final minutes = duration.inMinutes.remainder(60);
                            final totalHours = "$hours h $minutes m";

                            bool showExemption = hours < 9;

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 8),
                                Text("Total Hours: $totalHours",
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold, fontSize: 15)),
                                if (showExemption && !_exemptionRequested)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: ElevatedButton.icon(
                                      onPressed: _requestExemption,
                                      icon: const Icon(Icons.report_problem),
                                      label: const Text("Seek Exemption"),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.orange,
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          } else {
                            return const SizedBox.shrink();
                          }
                        }),

                        // Punch Out Image & Address
                        if (_punchOutImage != null)
                          Column(
                            children: [
                              const SizedBox(height: 8),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(_punchOutImage!, height: 120),
                              ),
                              const SizedBox(height: 4),
                              if (_punchOutAddress.isNotEmpty)
                                Text("📍 Address: $_punchOutAddress",
                                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                                    textAlign: TextAlign.center),
                            ],
                          ),

                        const SizedBox(height: 12),

                        // Buttons
                        if (!_alreadySubmitted)
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () => _captureSelfie(isPunchOut: false),
                              icon: const Icon(Icons.camera_alt),
                              label: const Text("Capture Selfie"),
                            ),
                          ),
                        if (!_alreadySubmitted)
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _loading ? null : _submitAttendance,
                              child: _loading
                                  ? const CircularProgressIndicator(color: Colors.white)
                                  : const Text("Punch In"),
                            ),
                          ),
                        if (_alreadySubmitted && _punchOutTime == null)
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () => _captureSelfie(isPunchOut: true),
                              icon: const Icon(Icons.camera_alt),
                              label: const Text("Capture Selfie"),
                            ),
                          ),
                        if (_alreadySubmitted && _punchOutTime == null)
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _loading ? null : _punchOut,
                              child: _loading
                                  ? const CircularProgressIndicator(color: Colors.white)
                                  : const Text("Punch Out"),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );

      },
    );
  }
}