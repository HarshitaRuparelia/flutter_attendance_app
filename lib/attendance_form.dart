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

class AttendanceForm extends StatefulWidget {
  const AttendanceForm({super.key});

  @override
  State<AttendanceForm> createState() => _AttendanceFormState();
}

class _AttendanceFormState extends State<AttendanceForm> {
  File? _image;
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
    print("harshita test address" + address);
  }

  Future<String> getAddressFromLatLng(Position position) async {
    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isNotEmpty) {
        final place = placemarks.first;
        return "${place.name}, ${place.street}, ${place.subLocality}, ${place.locality}, ${place.subAdministrativeArea}"
            " ${place.administrativeArea}, ${place.subThoroughfare}, ${place.postalCode}, ${place.country}";
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
      quality: 40,
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
      });
    }
  }

  Future<void> _submitAttendance() async {
    if (_punchInImage  == null || _position == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Please take selfie & location")));
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

      await FirebaseFirestore.instance.collection("attendance").add({
        "userId": user?.uid,
        "punchInLatitude": _position!.latitude,
        "punchInLongitude": _position!.longitude,
        "punchInTime": DateTime.now(),
        "punchInDate": DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day),
        "punchInSelfieUrl": selfieUrl,
      });

      setState(() {
        _submittedTime = DateTime.now();
        _alreadySubmitted = true;
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
    if (_punchOutImage  == null || _position == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Please take selfie & location")));
      return;
    }

    setState(() => _loading = true);

    try {
      final compressedSelfie = await compressImage(_punchOutImage !);
      if (compressedSelfie == null) throw Exception("Image compression failed");

      final ref = FirebaseStorage.instance
          .ref()
          .child("selfies/punchout_${DateTime.now().millisecondsSinceEpoch}.jpg");
      File file = File(compressedSelfie.path);
      await ref.putFile(file);
      final selfieUrl = await ref.getDownloadURL();

      // Update today's attendance document with punchOut
      final today = DateTime.now();
      final todayDate = DateTime(today.year, today.month, today.day);

      final snap = await FirebaseFirestore.instance
          .collection("attendance")
          .where("userId", isEqualTo: user?.uid)
          .where("punchInDate", isEqualTo: todayDate)
          .get();

      if (snap.docs.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection("attendance")
            .doc(snap.docs.first.id)
            .update({
          "punchOutTime": DateTime.now(),
          "punchOutSelfieUrl": selfieUrl,
          "punchOutLatitude": _position!.latitude,
          "punchOutLongitude": _position!.longitude,
        });

        setState(() {
          _punchOutTime = DateTime.now();
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
  }

  // ------------------- Build UI -------------------

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _getUserName(),
      builder: (context, snapshot) {
        String title = "Attendance Monitoring System";
        if (snapshot.connectionState == ConnectionState.done &&
            snapshot.hasData) {
          title = "Welcome ${snapshot.data}";
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(title,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            centerTitle: false,
            backgroundColor: Colors.orangeAccent,
            elevation: 2,
            shape: const Border(
              bottom: BorderSide(color: Colors.black, width: 1),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.logout),
                onPressed: () => FirebaseAuth.instance.signOut(),
              )
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ----------------- Attendance Card -----------------
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
                              style: const TextStyle(fontSize: 14),
                            ),
                          ],
                        ),

                        // Punch In selfie & address
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
                                Text(
                                  "📍 Address: $_punchInAddress",
                                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                                  textAlign: TextAlign.center,
                                ),
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
                              style: const TextStyle(fontSize: 14),
                            ),
                          ],
                        ),

                        // Punch Out selfie & address
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
                                Text(
                                  "📍 Address: $_punchOutAddress",
                                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                                  textAlign: TextAlign.center,
                                ),
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
                const SizedBox(height: 20),

                // ----------------- Leave Card -----------------
                Card(
                  elevation: 3,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Leaves",
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _applyLeave,
                            icon: const Icon(Icons.calendar_month),
                            label: const Text("Apply Leave"),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orangeAccent,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        StreamBuilder<QuerySnapshot>(
                          stream: FirebaseFirestore.instance
                              .collection("leaves")
                              .where("userId",
                              isEqualTo: FirebaseAuth
                                  .instance.currentUser?.uid)
                              .orderBy("startDate", descending: false)
                              .snapshots(),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) return const SizedBox();
                            if (snapshot.data!.docs.isEmpty) {
                              return const Text("No leaves applied yet.");
                            }

                            return Column(
                              children: snapshot.data!.docs.map((doc) {
                                final data =
                                doc.data() as Map<String, dynamic>;
                                final start =
                                (data["startDate"] as Timestamp).toDate();
                                final end =
                                (data["endDate"] as Timestamp).toDate();
                                final status = data["status"] ?? "Pending";

                                Color statusColor = Colors.orange;
                                if (status.toLowerCase() == "approved") {
                                  statusColor = Colors.green;
                                } else if (status.toLowerCase() == "rejected") {
                                  statusColor = Colors.red;
                                }

                                return ListTile(
                                  leading: const Icon(Icons.event_note),
                                  title: Text(
                                    start == end
                                        ? "${start.day}-${start.month}-${start.year}"
                                        : "${start.day}-${start.month}-${start.year} to ${end.day}-${end.month}-${end.year}",
                                  ),
                                  subtitle: Text(
                                    "Status: $status",
                                    style: TextStyle(color: statusColor),
                                  ),
                                );
                              }).toList(),
                            );
                          },
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
