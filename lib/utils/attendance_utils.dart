import 'package:cloud_firestore/cloud_firestore.dart';

class AttendanceAlreadySubmittedException implements Exception {
  final String message;
  const AttendanceAlreadySubmittedException(this.message);

  @override
  String toString() => message;
}

class AttendanceAlreadyPunchedOutException implements Exception {
  final String message;
  const AttendanceAlreadyPunchedOutException(this.message);

  @override
  String toString() => message;
}

class AttendanceUtils {
  /// Standard working day (9 hours) — half-day labels only.
  static const int fullDayMinutes = 540;

  /// One attendance document per employee per calendar day.
  static String docIdForDay(String userId, DateTime date) {
    final day = DateTime(date.year, date.month, date.day);
    final ymd =
        '${day.year}${day.month.toString().padLeft(2, '0')}${day.day.toString().padLeft(2, '0')}';
    return '${userId}_$ymd';
  }

  static DocumentReference<Map<String, dynamic>> docRefForDay(
    FirebaseFirestore firestore,
    String userId,
    DateTime date,
  ) {
    return firestore
        .collection('attendance')
        .doc(docIdForDay(userId, date));
  }

  static bool _hasPunchInData(Map<String, dynamic>? data) {
    if (data == null) return false;
    return data['punchInTime'] != null;
  }

  /// True if this employee already has a punch-in for the calendar day.
  static Future<bool> hasPunchInForDay({
    required FirebaseFirestore firestore,
    required String userId,
    required DateTime date,
  }) async {
    final day = DateTime(date.year, date.month, date.day);

    final canonical = await docRefForDay(firestore, userId, day).get();
    if (_hasPunchInData(canonical.data())) {
      return true;
    }

    final legacy = await firestore
        .collection('attendance')
        .where('userId', isEqualTo: userId)
        .where('punchInDate', isEqualTo: day)
        .limit(1)
        .get();

    if (legacy.docs.isEmpty) return false;
    return _hasPunchInData(legacy.docs.first.data());
  }

  /// Reads `totalHours` from Firestore (stored as total minutes).
  static int? parseStoredMinutes(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static DateTime? parseRecordDate(Map<String, dynamic> data) {
    final punchInDate = data['punchInDate'];
    if (punchInDate is Timestamp) {
      final d = punchInDate.toDate();
      return DateTime(d.year, d.month, d.day);
    }
    if (punchInDate is DateTime) {
      return DateTime(
        punchInDate.year,
        punchInDate.month,
        punchInDate.day,
      );
    }

    final punchInTs = data['punchInTime'];
    if (punchInTs is Timestamp) {
      final punchIn = punchInTs.toDate();
      return DateTime(punchIn.year, punchIn.month, punchIn.day);
    }
    if (punchInTs is DateTime) {
      return DateTime(punchInTs.year, punchInTs.month, punchInTs.day);
    }

    return null;
  }

  static bool isDateInInclusiveRange(
    DateTime date,
    DateTime rangeStart,
    DateTime rangeEnd,
  ) {
    final normalized = DateTime(date.year, date.month, date.day);
    final start = DateTime(rangeStart.year, rangeStart.month, rangeStart.day);
    final end = DateTime(rangeEnd.year, rangeEnd.month, rangeEnd.day);
    return !normalized.isBefore(start) && !normalized.isAfter(end);
  }

  static bool isExemptionApproved(Map<String, dynamic> data) {
    return (data['exemptionStatus'] ?? '').toString().toLowerCase() ==
        'approved';
  }

  static String formatMinutes(int? totalMinutes) {
    if (totalMinutes == null) return '-';

    final mins = totalMinutes < 0 ? 0 : totalMinutes;
    final hrs = mins ~/ 60;
    final remMins = mins % 60;
    return '$hrs h ${remMins.toString().padLeft(2, '0')} m';
  }
}
