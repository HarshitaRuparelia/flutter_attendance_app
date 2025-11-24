import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:flutter/foundation.dart';
import 'attendance_history_screen.dart';
import 'leave_screen.dart';
import 'dart:io' show File;
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'camera_screen_wrapper.dart';

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
  bool _noPunchInNeeded = false;
  String? _message;
  Uint8List? _punchInImageBytes;
  Uint8List? _punchOutImageBytes;
  bool _isPreviewLoading = false;

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

  Future<void> _checkNoPunchInDay() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    String? reason;

    // 1️⃣ Sunday
    if (now.weekday == DateTime.sunday) {
      reason = "No Punch-In needed today — It's Sunday (Weekly Holiday).";
    }
    // 2️⃣ 2nd or 4th Saturday
    else if (now.weekday == DateTime.saturday) {
      int saturdayCount = 0;
      for (int d = 1; d <= now.day; d++) {
        DateTime checkDay = DateTime(now.year, now.month, d);
        if (checkDay.weekday == DateTime.saturday) saturdayCount++;
      }
      if (saturdayCount == 2 || saturdayCount == 4) {
        reason =
            "No Punch-In needed today — It's ${saturdayCount == 2 ? "2nd" : "4th"} Saturday (Holiday).";
      }
    }

    // 3️⃣ Admin-declared holidays (from Firestore)
    if (reason == null) {
      final holidaySnap = await FirebaseFirestore.instance
          .collection("holidays")
          .where("date", isGreaterThanOrEqualTo: Timestamp.fromDate(today))
          .where(
            "date",
            isLessThan: Timestamp.fromDate(today.add(const Duration(days: 1))),
          )
          .get();

      if (holidaySnap.docs.isNotEmpty) {
        final holidayData = holidaySnap.docs.first.data();
        final holidayName = holidayData["name"] ?? "Holiday";
        reason = "No Punch-In needed today — It's $holidayName.";
      }
    }

    // 4️⃣ Leave applied for today
    if (reason == null && user != null) {
      final leaveSnap = await FirebaseFirestore.instance
          .collection("leaves")
          .where("userId", isEqualTo: user!.uid)
          .where("startDate", isLessThanOrEqualTo: today)
          .where("endDate", isGreaterThanOrEqualTo: today)
          .get();

      if (leaveSnap.docs.isNotEmpty) {
        final leaveData = leaveSnap.docs.first.data();
        final leaveReason = leaveData["reason"] ?? "Leave";
        reason =
            "No Punch-In needed today — You are on leave (${leaveReason}).";
      }
    }

    // ✅ Final state update
    if (reason != null) {
      setState(() {
        _noPunchInNeeded = true;
        _message = reason;
      });
    }
  }

  Future<void> _captureSelfie({required bool isPunchOut}) async {
    print("_captureSelfie new");

    final capturedBytes = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CameraScreenWrapper()),
    );
    print("_captureSelfie result = $capturedBytes");

    if (capturedBytes == null) return;
    await _getLocation();

    Uint8List bytes;
    File? file;

    if (capturedBytes is File) {
      file = capturedBytes;
      bytes = await capturedBytes.readAsBytes();
    } else if (capturedBytes is Uint8List) {
      bytes = capturedBytes;
      file = null;
    } else {
      return;
    }

    if (!mounted) return; // 🔥 Prevents setState after dispose
    setState(() {
      _isPreviewLoading = true; // start loading preview
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      setState(() {
        if (isPunchOut) {
          _punchOutImage = file;
          _punchOutImageBytes = bytes;
          _punchOutAddress = address;
        } else {
          _punchInImage = file;
          _punchInImageBytes = bytes;
          _punchInAddress = address;
        }

        _isPreviewLoading = false; // preview finished
      });
    });
  }

  Future<void> _getLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) throw Exception("Location service disabled");

    LocationPermission permission = await Geolocator.requestPermission();

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw Exception("Location permission denied");
    }

    Position pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    setState(() {
      _position = pos;
    });

    address = await getAddressFromLatLng(pos);
  }

  Future<String> getAddressFromLatLng(Position position) async {
    try {
      // -------------------------
      // ⭐ WEB → Use Google API
      // -------------------------
      if (kIsWeb) {
        final lat = position.latitude;
        final lng = position.longitude;

        const apiKey =
            "AIzaSyBmCX9ou3KEtNlR6j9ticypDFszy-hh-mU"; // <-- add your key here

        final url = Uri.parse(
          "https://maps.googleapis.com/maps/api/geocode/json?latlng=$lat,$lng&key=$apiKey",
        );

        final response = await http.get(url);
        final data = jsonDecode(response.body);

        if (data["status"] == "OK") {
          return data["results"][0]["formatted_address"];
        } else {
          print("Geocode Response: ${response.body}");
          return "Address not found (Web)";
        }
      } else {
        // -------------------------
        // ⭐ MOBILE → Use Plugin
        // -------------------------
        final placemarks = await placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );

        if (placemarks.isEmpty) return "Address not found";

        final p = placemarks.first;

        return [
          p.name,
          p.street,
          p.subLocality,
          p.locality,
          p.administrativeArea,
          p.postalCode,
          p.country,
        ].where((x) => x != null && x!.trim().isNotEmpty).join(", ");
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
      if (!mounted) return;

      setState(() {
        _alreadySubmitted = true;

        // Punch in time
        _submittedTime = (data["punchInTime"] as Timestamp).toDate();

        // Punch out time (nullable)
        _punchOutTime = data["punchOutTime"] != null
            ? (data["punchOutTime"] as Timestamp).toDate()
            : null;

        // Late?
        _isLate = data["isLate"] ?? false;

        // TOTAL HOURS LOGIC
        if (_punchOutTime == null) {
          // 👈 user has not punched out
          _totalHours = "-";
        } else {
          // 👇 Use DB stored minutes safely
          int? mins = data["totalHours"];
          if (mins != null) {
            _totalHours = "${mins ~/ 60}h ${mins % 60}m";
          } else {
            // fallback (rare)
            final duration = _punchOutTime!.difference(_submittedTime!);
            final roundedMins = (duration.inSeconds / 60).round();
            _totalHours = "${roundedMins ~/ 60}h ${roundedMins % 60}m";
          }
        }

        // Exemption
        _exemptionRequested =
            (data["exemptionStatus"] == "requested" ||
            data["exemptionStatus"] == "approved");
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
        .where(
          "date",
          isLessThan: Timestamp.fromDate(
            todayDate.add(const Duration(days: 1)),
          ),
        )
        .get();

    if (exemptionSnap.docs.isNotEmpty) {
      setState(() {
        _exemptionRequested = true;
      });
    }
  }

  Future<void> _submitAttendance() async {
    if ((!kIsWeb && _punchInImage == null) ||
        (kIsWeb && _punchInImageBytes == null) ||
        _position == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please take selfie & location")),
      );
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
      String selfieUrl = "";

      final userName = await _getUserName(); // Fetch name from Firestore
      final formattedDate =
          "${now.year}-${now.month}-${now.day}_${now.hour}-${now.minute}";

      final ref = FirebaseStorage.instance.ref().child(
        "selfies/${userName}_PunchIn_$formattedDate.jpg",
      );

      if (kIsWeb) {
        // ✅ Upload web bytes directly
        await ref.putData(_punchInImageBytes!);
        selfieUrl = await ref.getDownloadURL();
      } else {
        // ✅ Compress only on mobile
        final compressedSelfie = await compressImage(_punchInImage!);
        if (compressedSelfie == null)
          throw Exception("Image compression failed");

        File file = File(compressedSelfie.path);
        await ref.putFile(file);
        selfieUrl = await ref.getDownloadURL();
      }

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

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Punch In successful ✅")));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Error: $e")));
    }

    setState(() => _loading = false);
  }

  Future<void> _punchOut() async {
    if (_submittedTime == null) {
      await _checkAttendance();
      if (_submittedTime == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Punch In missing. Cannot Punch Out.")),
        );
        return;
      }
    }

    if ((!kIsWeb && _punchOutImage == null) ||
        (kIsWeb && _punchOutImageBytes == null) ||
        _position == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please take selfie & location")),
      );
      return;
    }

    setState(() => _loading = true);

    try {
      String selfieUrl = "";
      final today = DateTime.now();
      final userName = await _getUserName(); // Fetch name from Firestore
      final formattedDate =
          "${today.year}-${today.month}-${today.day}_${today.hour}-${today.minute}";

      final ref = FirebaseStorage.instance.ref().child(
        "selfies/${userName}_PunchOut_$formattedDate.jpg",
      );

      if (kIsWeb) {
        /// ✅ Web: upload bytes directly
        await ref.putData(_punchOutImageBytes!);
        selfieUrl = await ref.getDownloadURL();
      } else {
        /// ✅ Mobile: compress and upload file
        final compressedSelfie = await compressImage(_punchOutImage!);
        if (compressedSelfie == null)
          throw Exception("Image compression failed");

        File file = File(compressedSelfie.path);
        await ref.putFile(file);
        selfieUrl = await ref.getDownloadURL();
      }

      final todayDate = DateTime(today.year, today.month, today.day);

      final snap = await FirebaseFirestore.instance
          .collection("attendance")
          .where("userId", isEqualTo: user?.uid)
          .where("punchInDate", isEqualTo: todayDate)
          .get();

      if (snap.docs.isNotEmpty) {
        DateTime punchOutTime = DateTime.now();
        final totalHours = punchOutTime.difference(_submittedTime!);

        final int minutes = (totalHours.inSeconds / 60).round();

        await FirebaseFirestore.instance
            .collection("attendance")
            .doc(snap.docs.first.id)
            .update({
              "punchOutTime": punchOutTime,
              "punchOutSelfieUrl": selfieUrl,
              "punchOutLatitude": _position!.latitude,
              "punchOutLongitude": _position!.longitude,
              "punchOutAddress": _punchOutAddress,
              "totalHours": minutes,
            });

        setState(() {
          _punchOutTime = punchOutTime;
          _totalHours = "${totalHours.inHours}h ${totalHours.inMinutes % 60}m";
        });

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("Punch Out successful ✅")));
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Error: $e")));
    }

    setState(() => _loading = false);
  }

  Future<void> _requestExemption() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || _submittedTime == null || _punchOutTime == null)
        return;

      final todayDate = DateTime(
        _submittedTime!.year,
        _submittedTime!.month,
        _submittedTime!.day,
      );

      final attendanceSnap = await FirebaseFirestore.instance
          .collection("attendance")
          .where("userId", isEqualTo: user.uid)
          .where("punchInDate", isEqualTo: todayDate)
          .limit(1)
          .get();

      if (attendanceSnap.docs.isEmpty) return;
      final docId = attendanceSnap.docs.first.id;

      await FirebaseFirestore.instance
          .collection("attendance")
          .doc(docId)
          .update({
            "exemptionStatus": "requested",
            "exemptionRequestedAt": Timestamp.now(),
          });

      setState(() {
        _exemptionRequested = true;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Exemption request sent to Admin ✅')),
      );
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _checkForAutoLogout() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));

    // ------------------------------
    // 1️⃣ Get yesterday's attendance
    // ------------------------------
    final yesterdayStart = DateTime(yesterday.year, yesterday.month, yesterday.day);
    final yesterdayEnd = yesterdayStart.add(const Duration(days: 1));

    final query = await FirebaseFirestore.instance
        .collection('attendance')
        .where('userId', isEqualTo: user.uid)
        .where('punchInDate', isGreaterThanOrEqualTo: yesterdayStart)
        .where('punchInDate', isLessThan: yesterdayEnd)
        .limit(1)
        .get();

    if (query.docs.isEmpty) return;

    final doc = query.docs.first;
    final data = doc.data();

    final punchIn = (data['punchInTime'] as Timestamp?)?.toDate();
    final punchOut = data['punchOutTime'];

    if (punchIn == null || punchOut != null) return;

    // --------------------------------------------
    // 2️⃣ Ensure auto-punch-out is ONLY once
    //    Trigger time: after midnight → before 7:30 AM
    // --------------------------------------------
    final midnightToday = DateTime(punchIn.year, punchIn.month, punchIn.day + 1, 0, 0);
    final cutoffTime   = DateTime(punchIn.year, punchIn.month, punchIn.day + 1, 7, 30);

    final bool isAfterMidnight = now.isAfter(midnightToday);
    final bool isBeforeCutoff  = now.isBefore(cutoffTime);
    // final bool isAfterMidnight = true;
    // final bool isBeforeCutoff  = true;

    if (!isAfterMidnight || !isBeforeCutoff) return;

    // --------------------------------------------
    // 3️⃣ Auto punch-out at fixed time: 7:30 PM
    // --------------------------------------------
    final autoPunchOut = DateTime(
      punchIn.year,
      punchIn.month,
      punchIn.day,
      19,
      30,
    );

    final int totalMinutes =
    (autoPunchOut.difference(punchIn).inSeconds / 60).round();
    debugPrint("Perform auto logout");
    await doc.reference.update({
      'punchOutTime': Timestamp.fromDate(autoPunchOut),
      'punchOutSelfieUrl': 'auto_punchout',
      'punchOutLatitude': 0.0,
      'punchOutLongitude': 0.0,
      'punchOutAddress': 'Auto punch-out by system',
      'totalHours': totalMinutes,
      'autoLogout': true,
    });

    if (mounted) {
      setState(() {
        _message = "⏰ Auto punch-out done at 7:30 PM (system generated)";
      });
    }
  }


  Widget buildSelfiePreview(bool isPunchOut) {
    final bytes = isPunchOut ? _punchOutImageBytes : _punchInImageBytes;
    if (bytes == null) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image(
        image: MemoryImage(bytes),
        width: 150,
        height: 150,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _checkForAutoLogout();
    _checkAttendance();
    _checkExemptionStatus();
    _checkNoPunchInDay();
  }

  Widget _exemptionButton(String exemptionStatus) {
    String label = "Seek Exemption";
    Color color = Colors.orange;
    bool disabled = false;

    if (exemptionStatus == "requested") {
      label = "Exemption Requested";
      color = Colors.grey;
      disabled = true;
    } else if (exemptionStatus == "approved") {
      label = "Exempted ✅";
      color = Colors.grey;
      disabled = true;
    }

    return ElevatedButton.icon(
      onPressed: disabled ? null : _requestExemption,
      icon: const Icon(Icons.report_problem),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        disabledBackgroundColor: Colors.grey,
      ),
    );
  }

  // ------------------- Build UI -------------------
  Stream<DocumentSnapshot<Map<String, dynamic>>> _todayAttendanceStream() {
    if (user == null) return const Stream.empty();
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);

    return FirebaseFirestore.instance
        .collection("attendance")
        .where("userId", isEqualTo: user!.uid)
        .where("punchInDate", isEqualTo: todayDate)
        .limit(1)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs.isNotEmpty ? snapshot.docs.first : null,
        )
        .where((doc) => doc != null)
        .cast<DocumentSnapshot<Map<String, dynamic>>>();
  }

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
            title: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w400),
            ),
            backgroundColor: Colors.orangeAccent,
          ),
          drawer: Drawer(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                UserAccountsDrawerHeader(
                  decoration: const BoxDecoration(color: Colors.orangeAccent),
                  accountName: Text(snapshot.data ?? "User"),
                  accountEmail: Text(
                    FirebaseAuth.instance.currentUser?.email ?? "",
                  ),
                  currentAccountPicture: CircleAvatar(
                    //backgroundColor: Colors.red,
                    child: Image.asset(
                      'android/assets/images/Taxtech_Logo.png', // 👈 replace with your actual logo path
                      height: 45,
                    ),
                  ),
                ),

                ListTile(
                  leading: const Icon(Icons.history, color: Colors.orange),
                  title: const Text("Attendance History"),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AttendanceHistoryScreen(),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.calendar_month,
                    color: Colors.orange,
                  ),
                  title: const Text("Leave Requests"),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const LeaveScreen()),
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
            body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: _todayAttendanceStream(),
              builder: (context, snapshot) {
                return SingleChildScrollView(

                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_message != null && !_noPunchInNeeded)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Card(
                            color: Colors.orange[50],
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 2,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  const Icon(
                                      Icons.access_time, color: Colors.orange),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      _message!,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        color: Colors.orange,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                      if (_noPunchInNeeded)
                        Card(
                          color: Colors.orange[100],
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          margin: const EdgeInsets.only(bottom: 16),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                const Icon(
                                    Icons.info_outline, color: Colors.orange),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _message ?? "No Punch-In needed today.",
                                    style: const TextStyle(
                                      color: Colors.orange,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        Card(
                          elevation: 3,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  "Attendance",
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 12),

                                // Punch In Row
                                Row(
                                  children: [
                                    const Icon(
                                        Icons.login, color: Colors.green),
                                    const SizedBox(width: 8),
                                    Text(
                                      _submittedTime != null
                                          ? "Punch In: ${DateFormat(
                                          'dd MMM, hh:mm a').format(
                                          _submittedTime!)}"
                                          : "Punch In: Not yet",
                                    ),
                                  ],
                                ),

                                if (_isLate)
                                  const Text(
                                    "⚠️ Late Punch In",
                                    style: TextStyle(color: Colors.red),
                                  ),

                                // Punch In Image & Address
                                if (_punchInImage != null ||
                                    (kIsWeb && _punchInImageBytes != null))
                                  Column(
                                    children: [
                                      const SizedBox(height: 8),
                                      buildSelfiePreview(false), // Punch In
                                      const SizedBox(height: 4),
                                      if (_punchInAddress.isNotEmpty)
                                        Text(
                                          "📍 Address: $_punchInAddress",
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey,
                                          ),
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
                                          ? "Punch Out: ${DateFormat(
                                          'dd MMM, hh:mm a').format(
                                          _punchOutTime!)}"
                                          : "Punch Out: Not yet",
                                    ),
                                  ],
                                ),

                                // ✅ Calculate total working hours
                                Builder(
                                  builder: (context) {
                                    if (_submittedTime != null &&
                                        _punchOutTime != null) {
                                      final duration = _punchOutTime!
                                          .difference(
                                        _submittedTime!,
                                      );
                                      final totalMinutes = (duration.inSeconds /
                                          60)
                                          .round();
                                      final hours = totalMinutes ~/ 60;
                                      final minutes = totalMinutes % 60;
                                      final totalHours =
                                          "$hours h ${minutes
                                          .toString()
                                          .padLeft(2, '0')} m";

                                      return Column(
                                        crossAxisAlignment: CrossAxisAlignment
                                            .start,
                                        children: [
                                          const SizedBox(height: 8),

                                          FutureBuilder<DocumentSnapshot?>(
                                            future: () async {
                                              final snap = await FirebaseFirestore
                                                  .instance
                                                  .collection("attendance")
                                                  .where(
                                                "userId",
                                                isEqualTo: user?.uid,
                                              )
                                                  .where(
                                                "punchInDate",
                                                isEqualTo: DateTime(
                                                  _submittedTime!.year,
                                                  _submittedTime!.month,
                                                  _submittedTime!.day,
                                                ),
                                              )
                                                  .limit(1)
                                                  .get();

                                              if (snap.docs.isNotEmpty) {
                                                return snap.docs.first.reference
                                                    .get();
                                              }
                                              return null;
                                            }(),
                                            builder: (context, snapshot) {
                                              String exemptionStatus = "none";
                                              if (snapshot.hasData &&
                                                  snapshot.data != null &&
                                                  snapshot.data!.exists &&
                                                  snapshot.data!.data() !=
                                                      null) {
                                                final docData =
                                                snapshot.data!.data()
                                                as Map<String, dynamic>;
                                                exemptionStatus =
                                                    docData["exemptionStatus"] ??
                                                        "none";
                                              }

                                              final bool isExemptApproved =
                                                  exemptionStatus == "approved";
                                              final bool isShortDay = hours < 9;

                                              // DECIDE TEXT
                                              String displayText = isExemptApproved
                                                  ? totalHours
                                                  : (isShortDay
                                                  ? "$totalHours (Half Day)"
                                                  : totalHours);

                                              // DECIDE COLOR
                                              Color textColor = isExemptApproved
                                                  ? Colors.green
                                                  : (isShortDay
                                                  ? Colors.red
                                                  : Colors.black);

                                              // DECIDE ICON
                                              Icon icon = Icon(
                                                isExemptApproved
                                                    ? Icons
                                                    .verified_user // GREEN approved
                                                    : Icons.access_time_filled,
                                                color: isExemptApproved
                                                    ? Colors.green
                                                    : Colors.red,
                                                size: 18,
                                              );

                                              return Column(
                                                crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                                children: [
                                                  Row(
                                                    children: [
                                                      Text(
                                                        "Total Hours: ",
                                                        style: TextStyle(
                                                          fontWeight: FontWeight
                                                              .bold,
                                                        ),
                                                      ),

                                                      if (isShortDay ||
                                                          isExemptApproved)
                                                        Padding(
                                                          padding:
                                                          const EdgeInsets.only(
                                                            left: 6,
                                                          ),
                                                          child: icon,
                                                        ),

                                                      Text(
                                                        " $displayText",
                                                        style: TextStyle(
                                                          fontWeight: FontWeight
                                                              .bold,
                                                          fontSize: 15,
                                                          color: textColor,
                                                        ),
                                                      ),
                                                    ],
                                                  ),

                                                  if (isShortDay) ...[
                                                    const SizedBox(height: 8),
                                                    _exemptionButton(
                                                        exemptionStatus),
                                                  ],
                                                ],
                                              );
                                            },
                                          ),
                                        ],
                                      );
                                    }
                                    return const SizedBox.shrink();
                                  },
                                ),

                                // Punch Out Image & Address
                                if (_punchOutImage != null ||
                                    (kIsWeb && _punchOutImageBytes != null))
                                  Column(
                                    children: [
                                      const SizedBox(height: 8),
                                      buildSelfiePreview(true), // Punch Out
                                      const SizedBox(height: 4),
                                      if (_punchOutAddress.isNotEmpty)
                                        Text(
                                          "📍 Address: $_punchOutAddress",
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey,
                                          ),
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
                                      onPressed: () =>
                                          _captureSelfie(isPunchOut: false),
                                      icon: const Icon(Icons.camera_alt),
                                      label: const Text("Capture Selfie"),
                                    ),
                                  ),
                                if (!_alreadySubmitted)
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton(
                                      onPressed: (_loading || _isPreviewLoading)
                                          ? null
                                          : _submitAttendance,
                                      child: _loading
                                          ? const CircularProgressIndicator(
                                        color: Colors.white,
                                      )
                                          : const Text("Punch In"),
                                    ),
                                  ),
                                if (_alreadySubmitted && _punchOutTime == null)
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: () =>
                                          _captureSelfie(isPunchOut: true),
                                      icon: const Icon(Icons.camera_alt),
                                      label: const Text("Capture Selfie"),
                                    ),
                                  ),
                                if (_alreadySubmitted && _punchOutTime == null)
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton(
                                      onPressed: (_loading || _isPreviewLoading)
                                          ? null
                                          : _punchOut,
                                      child: _loading
                                          ? const CircularProgressIndicator(
                                        color: Colors.white,
                                      )
                                          : const Text("Punch Out"),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                );

              },
        ));
      },
    );
  }
}
