import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'attendance_history_screen.dart';
import 'auth_page.dart';
import 'leave_screen.dart';
import 'leave_balance_screen.dart';
import 'dart:io' show File;
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'camera_screen_wrapper.dart';
import 'logger.dart';
import 'utils/attendance_utils.dart';

// Notifications plugin (Mobile only)
import 'notification_service.dart';
import 'package:timezone/timezone.dart' as tz;

import 'ope_claim_screen.dart';
import 'clock_hours_screen.dart';
import 'utils/clock_time_utils.dart';
import 'route_observer.dart';

class AttendanceForm extends StatefulWidget {
  const AttendanceForm({super.key});

  @override
  State<AttendanceForm> createState() => _AttendanceFormState();
}

class _AttendanceFormState extends State<AttendanceForm> with RouteAware {
  File? _punchInImage;
  File? _punchOutImage;
  String? _punchInAddress;
  String? _punchOutAddress;
  Position? _position;
  bool _loading = false;
  String? address;
  final User? user = FirebaseAuth.instance.currentUser;
  bool _alreadySubmitted = false;
  bool _submittingPunchIn = false;
  bool _submittingPunchOut = false;
  DateTime? _submittedTime; // Punch In
  DateTime? _punchOutTime; // Punch Out
  bool _isLate = false;
  String _totalHours = "";
  int? _storedTotalMinutes;
  bool _exemptionRequested = false;
  bool _noPunchInNeeded = false;
  bool _clockHoursBlockPunchIn = false;
  String? _clockHoursBlockMessage;
  DateTime? _pendingClockDate;
  bool _todayClockHoursPending = false;
  String? _message;

  bool get _isClockHoursBlocking => _clockHoursBlockPunchIn == true;
  bool get _isTodayClockPending => _todayClockHoursPending == true;
  Uint8List? _punchInImageBytes;
  Uint8List? _punchOutImageBytes;
  bool _isPreviewLoading = false;
  DateTime? _punchInCaptureTime;
  DateTime? _punchOutCaptureTime;
  final TextEditingController _exemptionReasonController = TextEditingController();
  bool _isLocationValid = false;
  String _appVersion = "";

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
    AppLogger.log(event: "_checkNoPunchInDay() called ", uid: user!.uid);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    String? reason;

    // 1️⃣ Sunday
    if (now.weekday == DateTime.sunday) {
      reason = "No Punch-In needed today — It's Sunday (Weekly Holiday).";
    }
    // 2️⃣ 2nd or 4th Saturday
   /* else if (now.weekday == DateTime.saturday) {
      int saturdayCount = 0;
      for (int d = 1; d <= now.day; d++) {
        DateTime checkDay = DateTime(now.year, now.month, d);
        if (checkDay.weekday == DateTime.saturday) saturdayCount++;
      }
      AppLogger.log(event: "Saturday count this month so far: $saturdayCount", uid: user!.uid);
      if (saturdayCount == 2 || saturdayCount == 4) {
        reason =
            "No Punch-In needed today — It's ${saturdayCount == 2 ? "2nd" : "4th"} Saturday (Holiday).";
      }
    }*/

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
      AppLogger.log(event: "$reason" , uid: user!.uid);
      setState(() {
        _noPunchInNeeded = true;
        _message = reason;
      });
    }
  }

  Future<void> _checkClockHoursCompliance() async {
    if (user == null) return;

    try {
      final result = await checkPunchInClockCompliance(user!.uid);
      final today = DateTime.now();
      final todayDate = DateTime(today.year, today.month, today.day);
      final todayStatus = await getClockDayStatus(
        employeeId: user!.uid,
        date: todayDate,
      );

      if (!mounted) return;
      setState(() {
        _clockHoursBlockPunchIn = !result.canPunchIn;
        _clockHoursBlockMessage = result.message;
        _pendingClockDate = result.pendingDate;
        _todayClockHoursPending =
            isClockHoursTrackingActive(todayDate) &&
            todayStatus.hasPunchOut &&
            !todayStatus.isComplete;
      });
    } catch (e) {
      AppLogger.log(
        event: "_checkClockHoursCompliance ERROR: $e",
        uid: user?.uid,
      );
      if (!mounted) return;
      setState(() {
        _clockHoursBlockPunchIn = false;
        _clockHoursBlockMessage = null;
        _pendingClockDate = null;
        _todayClockHoursPending = false;
      });
    }
  }

  Future<void> _openClockHours({DateTime? workDate}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ClockHoursScreen(
          initialWorkDate: workDate ?? _pendingClockDate,
        ),
      ),
    );
    if (!mounted) return;
    await _refreshAfterClockHoursChange();
  }

  Future<void> _refreshAfterClockHoursChange() async {
    await _checkClockHoursCompliance();
    await _checkAttendance();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPopNext() {
    _refreshAfterClockHoursChange();
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _exemptionReasonController.dispose();
    super.dispose();
  }

  Future<void> _captureSelfie({required bool isPunchOut}) async {

    AppLogger.log(event: "_captureSelfie() called ", uid: user!.uid);
    setState(() {
      _position = null;
      address = null;
      _punchInAddress = null;
      _punchOutAddress = null;
      _isLocationValid = false;
      _punchInImage = null;
      _punchInImageBytes = null;
      _punchOutImage = null;
      _punchOutImageBytes = null;
    });

    // 🔒 HARD STOP if no internet
    if (!await hasInternet()) {
      AppLogger.log(event: "_captureSelfie 1. Internet is required to capture selfie", uid: user!.uid);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Internet is required to capture selfie"),
        ),
      );
      return;
    }
    final captureTime = DateTime.now();

    final capturedBytes = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CameraScreenWrapper()),
    );
    print("_captureSelfie result = $capturedBytes");

    if (capturedBytes == null) {
      AppLogger.log(
        event: "capturedBytes== null No image captured - user cancelled camera",
        uid: user!.uid,
      );
      return;
    }
    AppLogger.log(
      event: "Fetching device location",
      uid: user!.uid,
    );
    // 🔒 CHECK AGAIN (user may turn off internet mid-flow)
    if (!await hasInternet()) {
      AppLogger.log(event: "_captureSelfie 2. Internet is required to capture selfie", uid: user!.uid);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Internet is required to capture selfie"),
        ),
      );
      return;
    }
    final locationOk = await _getLocation();
    if (!locationOk) return;

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
          _punchOutAddress = address?.trim().isNotEmpty == true ? address : null;
          _punchOutCaptureTime = captureTime;
          AppLogger.log(
            event: "Punch OUT image set | Address: $_punchOutAddress",
            uid: user!.uid,
          );
        } else {
          _punchInImage = file;
          _punchInImageBytes = bytes;
          _punchInAddress = address?.trim().isNotEmpty == true ? address : null;
          _punchInCaptureTime = captureTime;
          AppLogger.log(
            event: "Punch IN image set | Address: $_punchInAddress",
            uid: user!.uid,
          );
        }

        _isPreviewLoading = false; // preview finished
      });
    });
  }

  Future<bool> _getLocation() async {
    try {
      AppLogger.log(event: "_getLocation() started", uid: user!.uid);

      // 1️⃣ Service check
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw Exception("Location services are disabled");
      }

      // 2️⃣ Permission check
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception("Location permission denied");
      }

      // 3️⃣ Get fresh GPS ONLY (no cached)
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 15),
      );

      // 4️⃣ Accuracy validation
      final maxAccuracy = kIsWeb ? 100.0 : 50.0;
      if (position.accuracy > maxAccuracy) {
        throw Exception(
          "Low GPS accuracy (${position.accuracy.toStringAsFixed(1)}m). "
              "Please move to open area and retry.",
        );
      }

      // 5️⃣ Mock GPS detection (Android)
      if (!kIsWeb && position.isMocked) {
        AppLogger.log(
          event: "Mock GPS detected",
          uid: user!.uid,
          data: {
            "lat": position.latitude,
            "lng": position.longitude,
          },
        );
        throw Exception("Fake / Mock GPS detected. Disable it to continue.");
      }

      // 7️⃣ Address lookup
      final fetchedAddress  = await getAddressFromLatLng(position);

      setState(() {
        _position = position;
        _isLocationValid = true;

        // 🔥 IMPORTANT: store address ONLY if available
        if (fetchedAddress == null || fetchedAddress!.trim().isEmpty) {
          _punchInAddress = null;
          _punchOutAddress = null;
        } else {
          address = fetchedAddress; // optional, if you still need it
        }
      });

      AppLogger.log(
        event: "Location OK",
        uid: user!.uid,
        data: {
          "lat": position.latitude,
          "lng": position.longitude,
          "accuracy": position.accuracy,
          "mocked": !kIsWeb ? position.isMocked : false,
        },
      );
      return true;
    } catch (e) {
      AppLogger.log(
        event: "_getLocation FAILED",
        uid: user!.uid,
        data: {"error": e.toString()},
      );
      setState(() {
        _position = null;
         address = null;
        _punchInAddress = null;
        _punchOutAddress = null;
        _punchInImage = null;
        _punchInImageBytes = null;
        _punchOutImage = null;
        _punchOutImageBytes = null;
        _isLocationValid = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
      return false;
    }
  }

  Future<bool> hasInternet() async {
    if (kIsWeb) {
      // If web app is loaded, internet already exists
      return true;
    }

    try {
      final response = await http
          .get(Uri.parse('https://clients3.google.com/generate_204'))
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  Future<String?> getAddressFromLatLng(Position position) async {
    try {
      // -------------------------
      // ⭐ WEB → Use Google API
      // -------------------------
    //  if (kIsWeb) {
        final lat = position.latitude;
        final lng = position.longitude;

        const apiKey =
            "AIzaSyBmCX9ou3KEtNlR6j9ticypDFszy-hh-mU"; // <-- add your key here

        final url = Uri.parse(
          "https://maps.googleapis.com/maps/api/geocode/json?latlng=$lat,$lng&key=$apiKey",
        );

        final response = await http.get(url).timeout(
          const Duration(seconds: 5),
        );

        final data = jsonDecode(response.body);

        if (data["status"] == "OK" && data["results"] != null && data["results"].isNotEmpty) {
          return data["results"][0]["formatted_address"];
        } else {
          AppLogger.log(
            event: "Address not found (Web) Geocode Response =>  ${response.body}",
            uid: user!.uid);
          print("Geocode Response: ${response.body}");
          return null;
          //return "Address not found (Web)";
        }
      // } else {
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
          p.name,               // building / landmark name
          p.street,             // road
          p.subLocality,        // locality / area
          p.locality,           // city
          p.administrativeArea, // state
          p.postalCode,         // pin code
          p.country,            // country
        ].where((x) => x != null && x!.trim().isNotEmpty).toSet() // removes duplicates automatically
        .join(", ");
      // }
    }
    on SocketException {
      // 🔥 Internet OFF or very slow
      AppLogger.log(
        event: "Location not captured as (Internet is off)",
        uid: user!.uid,
      );
      //return "Location not captured as (Internet is off)";
      return null;
    }
    on TimeoutException {
      // 🔥 Slow internet
      AppLogger.log(
        event: "Location not captured as (Network is slow)",
        uid: user!.uid,
      );
     // return "Location not captured as (Network is slow)";
      return null;
    }
    catch (e) {
      AppLogger.log(
        event: "getAddressFromLatLng Exception",
        uid: user!.uid,
        data: {"error": e.toString()},
      );
      //return "Error: $e";
      return null;
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
    AppLogger.log(
      event: "_checkAttendance() called",
      uid: user!.uid,
    );
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);

    DocumentSnapshot<Map<String, dynamic>>? doc =
        await AttendanceUtils.docRefForDay(
      FirebaseFirestore.instance,
      user!.uid,
      todayDate,
    ).get();

    if (!doc.exists) {
      final snap = await FirebaseFirestore.instance
          .collection("attendance")
          .where("userId", isEqualTo: user?.uid)
          .where("punchInDate", isEqualTo: todayDate)
          .limit(1)
          .get();
      if (snap.docs.isNotEmpty) {
        doc = snap.docs.first;
      }
    }

    if (doc != null && doc.exists) {
      final data = doc.data()!;
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
          _totalHours = "-";
          _storedTotalMinutes = null;
        } else {
          final mins = AttendanceUtils.parseStoredMinutes(data["totalHours"]);
          if (mins != null) {
            _storedTotalMinutes = mins;
            _totalHours = AttendanceUtils.formatMinutes(mins);
          } else {
            final duration = _punchOutTime!.difference(_submittedTime!);
            final roundedMins = (duration.inSeconds / 60).round();
            _storedTotalMinutes = roundedMins;
            _totalHours = AttendanceUtils.formatMinutes(roundedMins);
          }
        }

        // Exemption
        _exemptionRequested =
            (data["exemptionStatus"] == "requested" ||
            data["exemptionStatus"] == "approved");
      });
    }
    else {
      AppLogger.log(
        event: "_checkAttendance() No attendance record found for today",
        uid: user!.uid,
      );
    }
    await _checkClockHoursCompliance();
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

  Future<bool> validateDeviceTime() async {
    final ref = FirebaseFirestore.instance
        .collection("_server")
        .doc("time");

    await ref.set({
      "now": FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    final snap = await ref.get();
    final serverTime = (snap["now"] as Timestamp).toDate();
    final deviceTime = DateTime.now();

    return serverTime.difference(deviceTime).inSeconds.abs() <= 120; //2mins
  }

  Future<void> _punchIn() async {
    if (_submittingPunchIn || _loading || _alreadySubmitted) {
      return;
    }

    _submittingPunchIn = true;
    if (mounted) setState(() => _loading = true);

    try {
      AppLogger.log(
        event: "_punchIn() called",
        uid: user!.uid,
      );

      if (!await hasInternet()) {
        AppLogger.log(event: "Internet is required to punch in", uid: user?.uid);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Internet is required to punch in"),
          ),
        );
        return;
      }

      if (!await validateDeviceTime()) {
        AppLogger.log(
          event: "Incorrect date & time detected. Please enable Automatic Date & Time.",
          uid: user?.uid,
          data: {
            "currentTime": FieldValue.serverTimestamp(),
            "detectedDeviceTime": DateTime.now(),
          },
        );

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Incorrect date & time detected.\nPlease enable Automatic Date & Time.",
            ),
          ),
        );
        return;
      }

      if (_isClockHoursBlocking) {
        AppLogger.log(
          event: "PunchIn blocked — clock hours pending",
          uid: user?.uid,
          data: {"message": _clockHoursBlockMessage},
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _clockHoursBlockMessage ??
                  'Please log clock hours for your previous working day first.',
            ),
            action: SnackBarAction(
              label: 'Clock Hours',
              onPressed: () => _openClockHours(),
            ),
          ),
        );
        return;
      }

      if (!_isLocationValid ||
          (!kIsWeb && _punchInImage == null) ||
          (kIsWeb && _punchInImageBytes == null) ||
          _position == null) {
        AppLogger.log(
          event: "PunchIn failed - selfie or location missing",
          uid: user?.uid,
          data: {
            "hasImage": kIsWeb
                ? _punchInImageBytes != null
                : _punchInImage != null,
            "hasLocation": _position != null,
          },
        );

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Please take selfie & location")),
        );
        return;
      }

      if (_punchInAddress == null || _punchInAddress!.trim().isEmpty) {
        AppLogger.log(
          event: "Location not captured. Please retry with stable internet.",
          uid: user?.uid,
        );

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Location not captured.\nPlease retry with stable internet.",
            ),
          ),
        );
        return;
      }

      if (_punchInCaptureTime == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Please capture selfie first")),
        );
        return;
      }
      final captureTime = _punchInCaptureTime!;

      final punchInDate = DateTime(
        captureTime.year,
        captureTime.month,
        captureTime.day,
      );

      if (await AttendanceUtils.hasPunchInForDay(
        firestore: FirebaseFirestore.instance,
        userId: user!.uid,
        date: punchInDate,
      )) {
        await _checkAttendance();
        throw const AttendanceAlreadySubmittedException(
          'You have already punched in today.',
        );
      }

      DateTime allowedTime =
          DateTime(captureTime.year, captureTime.month, captureTime.day, 9, 0);
      if (captureTime.isBefore(allowedTime)) {
        AppLogger.log(
          event: "Punch In allowed only after 9:00 AM",
          uid: user?.uid,
          data: {
            "currentTime": captureTime.toString(),
            "allowedTime": allowedTime.toString(),
          },
        );

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Punch In allowed only after 9:00 AM")),
        );
        return;
      }

      final diff = DateTime.now().difference(captureTime).inSeconds;
      AppLogger.log(event: "punchin Diff in secs-> $diff", uid: user?.uid);
      if (diff > 120) {
        AppLogger.log(
          event:
              "Punch In must be done within 2 minutes of selfie capture. Please re-capture selfie",
          uid: user?.uid,
          data: {
            "currentTime": FieldValue.serverTimestamp(),
            "captureTime": captureTime.toString(),
          },
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Punch In must be done within 2 minutes of selfie capture.\nPlease re-capture selfie",
            ),
          ),
        );
        return;
      }

      String selfieUrl = "";
      final userName = await _getUserName();
      final formattedDate =
          "${captureTime.year}-${captureTime.month}-${captureTime.day}_${captureTime.hour}-${captureTime.minute}";

      final ref = FirebaseStorage.instance.ref().child(
        "selfies/${userName}_PunchIn_$formattedDate.jpg",
      );

      if (kIsWeb) {
        AppLogger.log(
          event: "Uploading punch-in selfie (web)",
          uid: user?.uid,
        );
        await ref.putData(_punchInImageBytes!);
        selfieUrl = await ref.getDownloadURL();
      } else {
        final compressedSelfie = await compressImage(_punchInImage!);
        if (compressedSelfie == null) {
          throw Exception("Image compression failed");
        }

        final file = File(compressedSelfie.path);
        await ref.putFile(file);
        selfieUrl = await ref.getDownloadURL();
      }
      AppLogger.log(
        event: "Selfie uploaded successfully",
        uid: user?.uid,
        data: {"selfieUrl": selfieUrl},
      );

      final cutoff = DateTime(
        captureTime.year,
        captureTime.month,
        captureTime.day,
        10,
        15,
      );
      final isLate = captureTime.isAfter(cutoff);
      final docRef = AttendanceUtils.docRefForDay(
        FirebaseFirestore.instance,
        user!.uid,
        punchInDate,
      );

      await FirebaseFirestore.instance.runTransaction((transaction) async {
        final existing = await transaction.get(docRef);
        if (existing.exists && existing.data()?['punchInTime'] != null) {
          throw const AttendanceAlreadySubmittedException(
            'You have already punched in today.',
          );
        }

        transaction.set(docRef, {
          "userId": user!.uid,
          "punchInLatitude": _position!.latitude,
          "punchInLongitude": _position!.longitude,
          "punchInAddress": _punchInAddress,
          "punchInTime": Timestamp.fromDate(captureTime),
          "punchInSubmittedAt": FieldValue.serverTimestamp(),
          "punchInDate": punchInDate,
          "punchInSelfieUrl": selfieUrl,
          "isLate": isLate,
          'punchOutTime': null,
        });
      });

      setState(() {
        _submittedTime = captureTime;
        _alreadySubmitted = true;
        _isLate = isLate;
      });

      AppLogger.log(
        event: "Punch In successful",
        uid: user!.uid,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Punch In successful ✅")),
      );
    } on AttendanceAlreadySubmittedException catch (e) {
      await _checkAttendance();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      AppLogger.log(
        event: "PunchIn ERROR",
        uid: user?.uid,
        data: {
          "error": e.toString(),
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: $e")),
      );
    } finally {
      _submittingPunchIn = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _punchOut() async {
    AppLogger.log(
      event: "_punchOut() called",
      uid: user?.uid,
    );

    if (_submittingPunchOut || _loading || _punchOutTime != null) {
      return;
    }

    if (!await hasInternet()) {
      AppLogger.log(
          event: "Internet is required to punch out",
          uid: user?.uid);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Internet is required to punch out"),
        ),
      );
      return;
    }
    if (!await validateDeviceTime()) {
      AppLogger.log(
        event: "Incorrect date & time detected. Please enable Automatic Date & Time.",
        uid: user?.uid,
        data: {
          "currentTime": FieldValue.serverTimestamp(),
          "detectedDeviceTime": DateTime.now(),
        },
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Incorrect date & time detected.\nPlease enable Automatic Date & Time.",
          ),
        ),
      );
      return;
    }
    if (_submittedTime == null) {
      await _checkAttendance();
      if (_submittedTime == null) {
        AppLogger.log(
          event: "Punch In missing. Cannot Punch Out.",
          uid: user?.uid,
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Punch In missing. Cannot Punch Out.")),
        );
        return;
      }
    }

    if ((!kIsWeb && _punchOutImage == null) ||
        (kIsWeb && _punchOutImageBytes == null) ||
        _position == null) {
      AppLogger.log(
        event: "PunchOut FAILED - missing selfie or location",
        uid: user?.uid,
        data: {
          "hasImage": kIsWeb
              ? _punchOutImageBytes != null
              : _punchOutImage != null,
          "hasLocation": _position != null,
        },
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please take selfie & location")),
      );
      return;
    }

    if (_punchOutAddress == null || _punchOutAddress!.trim().isEmpty) {
      AppLogger.log(
        event: "Location not captured. Please retry with stable internet.",
        uid: user?.uid,
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Location not captured.\nPlease retry with stable internet.",
          ),
        ),
      );
      return;
    }

    final captureTime = _punchOutCaptureTime!;

    final diff =
        DateTime.now().difference(captureTime).inSeconds;
    AppLogger.log(event: "punchout Diff in secs-> $diff", uid: user?.uid);
    if (diff > 120) {
      AppLogger.log(
        event: "Punch Out must be done within 2 minutes of selfie capture. Please re-capture selfie",
        uid: user?.uid,
        data: {
          "currentTime": FieldValue.serverTimestamp(),
          "captureTime": captureTime.toString(),
        },
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Punch Out must be done within 2 minutes of selfie capture.\nPlease re-capture selfie",
          ),
        ),
      );
      return;
    }

    _submittingPunchOut = true;
    setState(() => _loading = true);

    try {
      String selfieUrl = "";

      final userName = await _getUserName(); // Fetch name from Firestore
      final formattedDate =
          "${captureTime.year}-${captureTime.month}-${captureTime.day}_${captureTime.hour}-${captureTime.minute}";

      final ref = FirebaseStorage.instance.ref().child(
        "selfies/${userName}_PunchOut_$formattedDate.jpg",
      );

      if (kIsWeb) {
        AppLogger.log(
          event: "Uploading PunchOut selfie (web)",
          uid: user?.uid,
        );
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
      AppLogger.log(
        event: "PunchOut selfie uploaded",
        uid: user?.uid,
        data: {"selfieUrl": selfieUrl},
      );

      final todayDate = DateTime(
        captureTime.year,
        captureTime.month,
        captureTime.day,
      );
      final docRef = AttendanceUtils.docRefForDay(
        FirebaseFirestore.instance,
        user!.uid,
        todayDate,
      );

      DocumentReference<Map<String, dynamic>> targetRef = docRef;
      final preCheck = await docRef.get();
      if (!preCheck.exists) {
        final snap = await FirebaseFirestore.instance
            .collection("attendance")
            .where("userId", isEqualTo: user!.uid)
            .where("punchInDate", isEqualTo: todayDate)
            .limit(1)
            .get();
        if (snap.docs.isEmpty) {
          throw Exception('No punch-in record found for today.');
        }
        targetRef = snap.docs.first.reference;
      }

      final int minutes =
          (captureTime.difference(_submittedTime!).inSeconds / 60).round();

      await FirebaseFirestore.instance.runTransaction((transaction) async {
        final existing = await transaction.get(targetRef);
        if (!existing.exists) {
          throw Exception('No punch-in record found for today.');
        }
        if (existing.data()?['punchOutTime'] != null) {
          throw const AttendanceAlreadyPunchedOutException(
            'You have already punched out today.',
          );
        }

        transaction.update(targetRef, {
          "punchOutTime": Timestamp.fromDate(captureTime),
          "punchOutSubmittedAt": FieldValue.serverTimestamp(),
          "punchOutSelfieUrl": selfieUrl,
          "punchOutLatitude": _position!.latitude,
          "punchOutLongitude": _position!.longitude,
          "punchOutAddress": _punchOutAddress,
          "totalHours": minutes,
        });
      });

      setState(() {
        _punchOutTime = captureTime;
        _storedTotalMinutes = minutes;
        _totalHours = AttendanceUtils.formatMinutes(minutes);
      });
      AppLogger.log(
        event: "PunchOut SUCCESS",
        uid: user?.uid,
        data: {
          "totalHoursFormatted": _totalHours,
          "minutes": minutes,
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(
          content: const Text("Punch Out successful ✅"),
          action: SnackBarAction(
            label: 'Clock Hours',
            onPressed: () => _openClockHours(workDate: todayDate),
          ),
        ),
      );
      await _checkClockHoursCompliance();
    } on AttendanceAlreadyPunchedOutException catch (e) {
      await _checkAttendance();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      AppLogger.log(
        event: "PunchOut ERROR",
        uid: user?.uid,
        data: {"error": e.toString()},
      );

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Error: $e")));
    } finally {
      _submittingPunchOut = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showExemptionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text("Seek Exemption"),
          content: TextField(
            controller: _exemptionReasonController,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: "Enter reason for exemption",
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                _exemptionReasonController.clear();
                Navigator.pop(context);
              },
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () {
                final reason = _exemptionReasonController.text.trim();
                if (reason.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("Please enter exemption reason"),
                    ),
                  );
                  return;
                }

                Navigator.pop(context);
                _requestExemption(reason);
              },
              child: const Text("Submit"),
            ),
          ],
        );
      },
    );
  }


  Future<void> _requestExemption(String reason) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || _submittedTime == null || _punchOutTime == null)
        {
          AppLogger.log(
            event: "_requestExemption Exemption Request Failed - Missing user or times",
            uid: user?.uid,
          );
          return;
        }


      final todayDate = DateTime(
        _submittedTime!.year,
        _submittedTime!.month,
        _submittedTime!.day,
      );

      final attendanceSnap = await AttendanceUtils.docRefForDay(
        FirebaseFirestore.instance,
        user.uid,
        todayDate,
      ).get();

      DocumentReference<Map<String, dynamic>>? attendanceRef;
      if (attendanceSnap.exists) {
        attendanceRef = attendanceSnap.reference;
      } else {
        final legacySnap = await FirebaseFirestore.instance
            .collection("attendance")
            .where("userId", isEqualTo: user.uid)
            .where("punchInDate", isEqualTo: todayDate)
            .limit(1)
            .get();
        if (legacySnap.docs.isEmpty) {
          AppLogger.log(
            event: "Exemption Request Failed - No attendance record found for today",
            uid: user.uid,
          );
          return;
        }
        attendanceRef = legacySnap.docs.first.reference;
      }

      await attendanceRef.update({
            "exemptionStatus": "requested",
            "exemptionRequestedAt": Timestamp.now(),
            "exemptionReason": reason,
          });
      _exemptionReasonController.clear();
      AppLogger.log(
        event: "Exemption Request Updated Successfully",
        uid: user.uid,
      );

          setState(() {
            _exemptionRequested = true;
          });

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Exemption request sent to Admin ✅')),
          );

    } catch (e) {
      AppLogger.log(
        event: "Exemption Request Error: $e",
        uid: user!.uid,
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _checkForAutoLogout() async {
    try {
      if (user == null) {
        AppLogger.log(
          event: "_checkForAutoLogout(): No user logged in",
          uid: "NO_USER",
        );
        return;
      }
      AppLogger.log(
        event: "AutoLogout: Check started",
        uid: user!.uid,
      );

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      // 1️⃣ Find the most recent attendance without punch-out
      final query = await FirebaseFirestore.instance
          .collection('attendance')
          .where('userId', isEqualTo: user!.uid)
          .where('punchOutTime', isNull: true)
          .orderBy('punchInDate', descending: true)
          .limit(1)
          .get();

      if (query.docs.isEmpty) {
        AppLogger.log(
          event: "AutoLogout: No attendance found for autologout",
          uid: user!.uid,
        );
        return;
      }

      final doc = query.docs.first;
      final data = doc.data();

      final punchIn = (data['punchInTime'] as Timestamp?)?.toDate();
      if (punchIn == null) {
        AppLogger.log(
          event: "AutoLogout: punchIn is null",
          uid: user!.uid,
        );
        return;
      }

      final punchInDate = DateTime(punchIn.year, punchIn.month, punchIn.day);

      // 2️⃣ If punch-in is today → DO NOT auto logout
      if (punchInDate == today) {
        AppLogger.log(
          event: "AutoLogout: punchInDate: $punchInDate today: $today both are same so don't log out",
          uid: user!.uid,
        );
        return;
      }

      // 3️⃣ Auto punch-out time = 7:30 PM of punch-in day
      final autoPunchOut = DateTime(
        punchIn.year,
        punchIn.month,
        punchIn.day,
        19,
        30,
      );

      final int totalMinutes = (autoPunchOut.difference(punchIn).inSeconds / 60).round();
      await doc.reference.update({
            'punchOutTime': Timestamp.fromDate(autoPunchOut),
            'punchOutSelfieUrl': 'auto_punchout',
            'punchOutLatitude': 0.0,
            'punchOutLongitude': 0.0,
            'punchOutAddress': 'Auto punch-out',
            'totalHours': totalMinutes,
            'autoLogout': true,
          });

          if (mounted) {
            setState(() {
              _message = "⏰ Auto punch-out done at 7:30 PM (system generated)";
            });
          }
    }
    catch (e) {
      AppLogger.log(
        event: "AutoLogout ERROR: $e",
        uid: user?.uid,
      );
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

  Future<void> scheduleDailyAttendanceReminder() async {
    if (kIsWeb) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      AppLogger.log(event: "Reminder: No user logged in → Skipping", uid: "NO_USER");
      return;
    }
    AppLogger.log(event: "scheduleDailyAttendanceReminder(): Started", uid: uid);
    final today = DateTime.now();
    final dateStr =
        "${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}";

    final firestore = FirebaseFirestore.instance;

    // 1️⃣ Skip Sunday
    if (today.weekday == DateTime.sunday) {
      AppLogger.log(event: "Reminder: Sunday → Skipped", uid: uid);
      return;
    }

    // 2️⃣ Skip 2nd & 4th Saturday
   /* if (today.weekday == DateTime.saturday) {
      int count = 0;
      for (int i = 1; i <= today.day; i++) {
        if (DateTime(today.year, today.month, i).weekday == DateTime.saturday) {
          count++;
        }
      }
      if (count == 2 || count == 4) {
        AppLogger.log(
          event: "Reminder: ${count == 2 ? "2nd" : "4th"} Saturday → Skipped",
          uid: uid,
        );
        return;
      }
    }*/

    // 3️⃣ Holiday check
    final holidayDoc = await firestore.collection('holidays').doc(dateStr).get();
    if (holidayDoc.exists) {
      AppLogger.log(
        event: "Reminder: Today is a Holiday → Skipped",
        uid: uid,
      );
      return;
    }

    // 4️⃣ Leave check
    final leaves = await firestore
        .collection('leaves')
        .where('userId', isEqualTo: uid)
        .where('status', isEqualTo: 'Approved')
        .get();

    bool onLeaveToday = false;
    for (var doc in leaves.docs) {
      final start = (doc["startDate"] as Timestamp).toDate();
      final end = (doc["endDate"] as Timestamp).toDate();

      if (!today.isBefore(start) && !today.isAfter(end)) {
        onLeaveToday = true;
        AppLogger.log(
          event: "Reminder: User on leave today → Skipped",
          uid: uid,
        );
        break;
      }
    }

    if (onLeaveToday) return;

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
    //var scheduleTime = now.add(const Duration(minutes: 1));
    // If it's already past 10 AM: remind next day
    if (scheduleTime.isBefore(now)) {
      scheduleTime = scheduleTime.add(const Duration(days: 1));
    }
    AppLogger.log(
      event: "Reminder PASSED all checks — Now Scheduling",
      uid: uid,
    );

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
    AppLogger.log(
      event:
      "Reminder Scheduled for: ${scheduleTime.toString()}",
      uid: uid,
    );
  }

  @override
  void initState() {
    super.initState();
    AppLogger.log(event: "Attendance Form Opened", uid: user!.uid);
    _protect();

    if (!kIsWeb) {
      Future.microtask(() async {
        AppLogger.log(
          event: "AttendanceForm opened — Scheduling reminder",
          uid: FirebaseAuth.instance.currentUser?.uid ?? "NO_UID",
        );
        await scheduleDailyAttendanceReminder();
      });
    }
    _checkForAutoLogout();
    _checkAttendance();
    _checkExemptionStatus();
    _checkNoPunchInDay();
    _checkClockHoursCompliance();
    _loadVersion();
  }
  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    setState(() {
      _appVersion = "v${info.version}+${info.buildNumber}";
    });
  }
  Future<void> _protect() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    await user.reload();

    if (!user.emailVerified) {
      await FirebaseAuth.instance.signOut();
      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const AuthPage()),
            (_) => false,
      );
    }
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
      onPressed: disabled ? null : _showExemptionDialog,
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

    return AttendanceUtils.docRefForDay(
      FirebaseFirestore.instance,
      user!.uid,
      todayDate,
    ).snapshots().where((snap) => snap.exists);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _getUserName(),
      builder: (context, snapshot) {
        String title = "";
        if (snapshot.connectionState == ConnectionState.done &&
            snapshot.hasData) {
          title = "${snapshot.data}";
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
                ListTile(
                  leading: const Icon(
                    Icons.event_available,
                    color: Colors.orange,
                  ),
                  title: const Text("Leave Balance"),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const LeaveBalanceScreen(),
                      ),
                    );
                  },
                ),

                ListTile(
                  leading: const Icon(Icons.receipt_long, color: Colors.orange),
                  title: const Text("OPE Claims"),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const OpeClaimScreen(),
                      ),
                    );
                  },
                ),

                ListTile(
                  leading: const Icon(Icons.schedule, color: Colors.orange),
                  title: const Text("Clock Hours"),
                  onTap: () {
                    Navigator.pop(context);
                    _openClockHours();
                  },
                ),

                const Divider(),
                ListTile(
                  leading: const Icon(Icons.logout, color: Colors.red),
                  title: const Text("Logout"),
                  trailing: Text(
                    _appVersion,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                    ),
                  ),
                  onTap: () async {
                    final uid = FirebaseAuth.instance.currentUser?.uid;

                    AppLogger.log(
                      event: "User logged out",
                      uid: uid,
                    );

                    await FirebaseAuth.instance.signOut();

                    if (!context.mounted) return;

                    Navigator.pushAndRemoveUntil(
                      context,
                      MaterialPageRoute(builder: (_) => const AuthPage()),
                          (route) => false,
                    );
                  },
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

                      if (_isClockHoursBlocking && !_noPunchInNeeded)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Card(
                            color: Colors.red.shade50,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 2,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.schedule,
                                        color: Colors.red.shade700,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          _clockHoursBlockMessage ??
                                              'Log clock hours for your previous working day before punching in.',
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: Colors.red.shade800,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: () => _openClockHours(),
                                      icon: const Icon(Icons.schedule),
                                      label: const Text('Open Clock Hours'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.red.shade700,
                                        foregroundColor: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                      if (_isTodayClockPending &&
                          !_noPunchInNeeded &&
                          !_isClockHoursBlocking)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Card(
                            color: Colors.amber.shade50,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 2,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Row(
                                    children: [
                                      Icon(
                                        Icons.warning_amber,
                                        color: Colors.orange,
                                      ),
                                      SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          'You punched out today. Please log clock hours for today.',
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: () => _openClockHours(
                                        workDate: DateTime.now(),
                                      ),
                                      icon: const Icon(Icons.schedule),
                                      label: const Text('Log today\'s hours'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.orangeAccent,
                                        foregroundColor: Colors.black,
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
                                      if (_punchInAddress != null && _punchInAddress!.trim().isNotEmpty)
                                        Text(
                                          "📍 Address: $_punchInAddress",
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey,
                                          ),
                                          textAlign: TextAlign.center,
                                        )
                                      else
                                        const Text(
                                          "📍 Address: Location not captured, Please retry",
                                          style: TextStyle(color: Colors.red),
                                          textAlign: TextAlign.center,
                                        ),
                                    ],
                                  ),

                                const SizedBox(height: 12),

                                // Punch Out Row
                                Row( children:
                                [
                                  const Icon(Icons.logout, color: Colors.red),
                                  const SizedBox(width: 8),
                                  Text( _punchOutTime != null ? "Punch Out: ${DateFormat( 'dd MMM, hh:mm a').format( _punchOutTime!)}" : "Punch Out: Not yet",
                                  ), ], ),

                                Builder(
                                  builder: (context) {
                                    if (_submittedTime == null ||
                                        _punchOutTime == null ||
                                        _storedTotalMinutes == null) {
                                      return const SizedBox.shrink();
                                    }

                                    final totalMinutes = _storedTotalMinutes!;
                                    final totalHours =
                                        AttendanceUtils.formatMinutes(
                                      totalMinutes,
                                    );

                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(height: 8),
                                        FutureBuilder<DocumentSnapshot?>(
                                          future: AttendanceUtils.docRefForDay(
                                            FirebaseFirestore.instance,
                                            user!.uid,
                                            DateTime(
                                              _submittedTime!.year,
                                              _submittedTime!.month,
                                              _submittedTime!.day,
                                            ),
                                          ).get(),
                                          builder: (context, snapshot) {
                                            String exemptionStatus = "none";
                                            if (snapshot.hasData &&
                                                snapshot.data != null &&
                                                snapshot.data!.exists &&
                                                snapshot.data!.data() != null) {
                                              final docData = snapshot
                                                  .data!.data()
                                                  as Map<String, dynamic>;
                                              exemptionStatus =
                                                  docData["exemptionStatus"] ??
                                                      "none";
                                            }

                                            final bool isExemptApproved =
                                                exemptionStatus == "approved";
                                            final bool isShortDay =
                                                totalMinutes <
                                                    AttendanceUtils
                                                        .fullDayMinutes &&
                                                !isExemptApproved;

                                            final String displayText =
                                                isExemptApproved
                                                    ? totalHours
                                                    : (isShortDay
                                                        ? "$totalHours (Half Day)"
                                                        : totalHours);

                                            final Color textColor =
                                                isExemptApproved
                                                    ? Colors.green
                                                    : (isShortDay
                                                        ? Colors.red
                                                        : Colors.black);

                                            final Icon icon = Icon(
                                              isExemptApproved
                                                  ? Icons.verified_user
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
                                                    const Text(
                                                      "Total Hours: ",
                                                      style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                    if (isShortDay ||
                                                        isExemptApproved)
                                                      Padding(
                                                        padding:
                                                            const EdgeInsets
                                                                .only(
                                                          left: 6,
                                                        ),
                                                        child: icon,
                                                      ),
                                                    Text(
                                                      " $displayText",
                                                      style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold,
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
                                      if (_punchOutAddress != null && _punchOutAddress!.trim().isNotEmpty)
                                        Text(
                                          "📍 Address: $_punchOutAddress",
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey,
                                          ),
                                          textAlign: TextAlign.center,
                                        )
                                      else
                                        const Text(
                                          "📍 Address: Location not captured, Please retry",
                                          style: TextStyle(color: Colors.red),
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
                                      onPressed: (_loading ||
                                              _isPreviewLoading ||
                                              _isClockHoursBlocking ||
                                              _submittingPunchIn)
                                          ? null
                                          : _punchIn,
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
                                      onPressed: (_loading ||
                                              _isPreviewLoading ||
                                              _submittingPunchOut)
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
