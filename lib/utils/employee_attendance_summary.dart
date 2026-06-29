import 'package:cloud_firestore/cloud_firestore.dart';

import 'attendance_utils.dart';

DateTime normalizeDate(DateTime date) {
  return DateTime(date.year, date.month, date.day);
}

DateTime? _readTimestamp(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return null;
}

DateTime? parseCreatedAt(Map<String, dynamic> data) {
  return _readTimestamp(data['createdAt']);
}

DateTime? parseResignedDate(Map<String, dynamic> data) {
  final value =
      data['resignedDate'] ?? data['resignationDate'] ?? data['resignDate'];
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return null;
}

Map<String, dynamic> employeeProfileFromUserDoc(
  DocumentSnapshot<Map<String, dynamic>> doc,
) {
  final data = doc.data() ?? {};
  return {
    'uid': doc.id,
    'isActive': data['isActive'] ?? true,
    'resignedDate': parseResignedDate(data),
    'createdAt': parseCreatedAt(data),
    'clientSiteSchedule': data['clientSiteSchedule'] == true ||
        data['offFirstThirdSaturday'] == true,
  };
}

bool isEmployeeVisibleOnDate(Map<String, dynamic> emp, DateTime date) {
  final resignedDate = emp['resignedDate'] as DateTime?;

  if (emp['isActive'] == false && resignedDate == null) {
    return false;
  }

  if (resignedDate != null) {
    final recordDay = normalizeDate(date);
    final resignedDay = normalizeDate(resignedDate);
    return !recordDay.isAfter(resignedDay);
  }

  return true;
}

bool isEmployeeActiveForSummaryDay(Map<String, dynamic> emp, DateTime day) {
  final dayNorm = normalizeDate(day);

  final createdAt = emp['createdAt'] as DateTime?;
  if (createdAt != null && dayNorm.isBefore(normalizeDate(createdAt))) {
    return false;
  }

  return isEmployeeVisibleOnDate(emp, day);
}

bool isWeekendDayForEmployee(Map<String, dynamic> emp, DateTime day) {
  if (day.weekday == DateTime.sunday) return true;
  if (day.weekday == DateTime.saturday) {
    final saturdayCount = ((day.day - 1) ~/ 7) + 1;

    if (emp['clientSiteSchedule'] == true) {
      return saturdayCount == 1 || saturdayCount == 3;
    }

    return saturdayCount == 2 || saturdayCount == 4;
  }
  return false;
}

String attendanceDateKey(DateTime date) {
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

Set<String> buildHolidayDateKeys(List<Map<String, dynamic>> holidays) {
  final keys = <String>{};
  for (final holiday in holidays) {
    final value = holiday['date'];
    if (value is! Timestamp) continue;
    keys.add(attendanceDateKey(value.toDate()));
  }
  return keys;
}

bool isApprovedLeaveOnDay(
  String userId,
  DateTime day,
  List<Map<String, dynamic>> leaves,
) {
  for (final leave in leaves) {
    if (leave['userId']?.toString() != userId) continue;
    if (leave['status']?.toString() == 'Rejected') continue;

    final startTs = leave['startDate'];
    final endTs = leave['endDate'];
    if (startTs is! Timestamp || endTs is! Timestamp) continue;

    final start = normalizeDate(startTs.toDate());
    final end = normalizeDate(endTs.toDate());
    final dayNorm = normalizeDate(day);

    if (!dayNorm.isBefore(start) && !dayNorm.isAfter(end)) {
      return true;
    }
  }
  return false;
}

Map<String, Map<String, dynamic>> buildAttendanceByDayMap(
  List<Map<String, dynamic>> attendanceRecords,
  String userId,
) {
  final map = <String, Map<String, dynamic>>{};
  for (final record in attendanceRecords) {
    if (record['userId']?.toString() != userId) continue;

    final punchDay = AttendanceUtils.parseRecordDate(record);
    if (punchDay == null) continue;

    map['${userId}_${attendanceDateKey(punchDay)}'] = record;
  }
  return map;
}

/// Same rules as admin dashboard `calculateWorkedMinutesInRange`.
int calculateWorkedMinutesInRange({
  required String userId,
  required Map<String, dynamic> employee,
  required DateTime rangeStart,
  required DateTime rangeEnd,
  required List<Map<String, dynamic>> attendanceRecords,
  required List<Map<String, dynamic>> leaveRecords,
  required Set<String> holidayDateKeys,
}) {
  final firstDay = normalizeDate(rangeStart);
  final lastDay = normalizeDate(rangeEnd);
  final attendanceByDay = buildAttendanceByDayMap(attendanceRecords, userId);

  var totalMinutes = 0;

  for (var day = firstDay;
      !day.isAfter(lastDay);
      day = day.add(const Duration(days: 1))) {
    final dayKey = attendanceDateKey(day);

    if (holidayDateKeys.contains(dayKey)) continue;
    if (!isEmployeeActiveForSummaryDay(employee, day)) continue;
    if (isWeekendDayForEmployee(employee, day)) continue;
    if (isApprovedLeaveOnDay(userId, day, leaveRecords)) continue;

    final record = attendanceByDay['${userId}_$dayKey'];
    if (record == null || record['punchOutTime'] == null) continue;

    totalMinutes += AttendanceUtils.parseStoredMinutes(record['totalHours']) ?? 0;
  }

  return totalMinutes;
}

List<Map<String, dynamic>> attendanceRecordsFromSnapshot(
  QuerySnapshot<Map<String, dynamic>> snap,
) {
  return snap.docs.map((doc) {
    final data = Map<String, dynamic>.from(doc.data());
    data['id'] = doc.id;
    return data;
  }).toList();
}

List<Map<String, dynamic>> leaveRecordsFromSnapshot(
  QuerySnapshot<Map<String, dynamic>> snap,
) {
  return snap.docs.map((doc) => Map<String, dynamic>.from(doc.data())).toList();
}

List<Map<String, dynamic>> holidayRecordsFromSnapshot(
  QuerySnapshot<Map<String, dynamic>> snap,
) {
  return snap.docs.map((doc) => Map<String, dynamic>.from(doc.data())).toList();
}

bool attendanceOverlapsRange(
  Map<String, dynamic> record,
  DateTime rangeStart,
  DateTime rangeEnd,
) {
  final punchIn = _readTimestamp(record['punchInTime']);
  if (punchIn == null) return false;

  final punchOut = _readTimestamp(record['punchOutTime']) ?? punchIn;
  return punchIn.isBefore(rangeEnd.add(const Duration(seconds: 1))) &&
      punchOut.isAfter(rangeStart.subtract(const Duration(seconds: 1)));
}
