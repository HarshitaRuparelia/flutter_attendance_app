import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import 'attendance_utils.dart';
import 'employee_attendance_summary.dart';

const String clockClientsCollection = 'clock_clients';
const String clockTasksCollection = 'clock_tasks';
const String clockHoursCollection = 'clock_hours';

String normalizeClockName(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

String clockDocIdFromName(String name) {
  final normalized = normalizeClockName(name);
  final slug = normalized.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  return slug.isEmpty ? 'item' : slug;
}

String masterItemStatus(Map<String, dynamic> data) {
  final raw = data['status']?.toString().toLowerCase();
  if (raw == 'pending' || raw == 'approved' || raw == 'rejected') {
    return raw!;
  }
  return data['isActive'] != false ? 'approved' : 'rejected';
}

bool isApprovedMasterData(Map<String, dynamic> data) {
  return masterItemStatus(data) == 'approved' && data['isActive'] != false;
}

bool isPendingMasterForEmployee(
  Map<String, dynamic> data,
  String employeeId,
) {
  return masterItemStatus(data) == 'pending' &&
      data['requestedBy']?.toString() == employeeId;
}

class ClockMasterItem {
  final String id;
  final String name;
  final bool isPending;

  const ClockMasterItem({
    required this.id,
    required this.name,
    this.isPending = false,
  });

  String get displayName =>
      isPending ? '$name (pending approval)' : name;

  factory ClockMasterItem.fromDoc(
    DocumentSnapshot doc, {
    bool isPending = false,
  }) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return ClockMasterItem(
      id: doc.id,
      name: data['name']?.toString() ?? doc.id,
      isPending: isPending,
    );
  }
}

class ClockHourEntry {
  final String id;
  final String employeeId;
  final String employeeName;
  final String clientName;
  final String taskName;
  final double hours;
  final DateTime? workDate;
  final String notes;

  const ClockHourEntry({
    required this.id,
    required this.employeeId,
    required this.employeeName,
    required this.clientName,
    required this.taskName,
    required this.hours,
    required this.workDate,
    required this.notes,
  });

  factory ClockHourEntry.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    DateTime? workDate;
    final rawDate = data['workDate'];
    if (rawDate is Timestamp) {
      workDate = rawDate.toDate();
    } else if (rawDate is String) {
      workDate = DateTime.tryParse(rawDate);
    }

    return ClockHourEntry(
      id: doc.id,
      employeeId: data['employeeId']?.toString() ?? '',
      employeeName: data['employeeName']?.toString() ?? 'Unknown',
      clientName: data['clientName']?.toString() ?? '-',
      taskName: data['taskName']?.toString() ?? '-',
      hours: (data['hours'] as num?)?.toDouble() ?? 0,
      workDate: workDate,
      notes: data['notes']?.toString() ?? '',
    );
  }
}

class ClockDayStatus {
  final DateTime date;
  final bool hasAttendance;
  final bool hasPunchOut;
  final int attendanceMinutes;
  final int clockedMinutes;
  final int remainingMinutes;
  final bool isComplete;

  const ClockDayStatus({
    required this.date,
    required this.hasAttendance,
    required this.hasPunchOut,
    required this.attendanceMinutes,
    required this.clockedMinutes,
    required this.remainingMinutes,
    required this.isComplete,
  });

  double get attendanceHours => attendanceMinutes / 60.0;
  double get clockedHours => clockedMinutes / 60.0;
  double get remainingHours => remainingMinutes / 60.0;
}

class ClockComplianceResult {
  final bool canPunchIn;
  final DateTime? pendingDate;
  final int? pendingAttendanceMinutes;
  final int? pendingClockedMinutes;
  final String? message;

  const ClockComplianceResult({
    required this.canPunchIn,
    this.pendingDate,
    this.pendingAttendanceMinutes,
    this.pendingClockedMinutes,
    this.message,
  });
}

class ClockHoursValidationException implements Exception {
  final String message;

  const ClockHoursValidationException(this.message);

  @override
  String toString() => message;
}

DateTime normalizeWorkDate(DateTime date) {
  return DateTime(date.year, date.month, date.day);
}

/// App go-live: clock hours required from Mon 29 Jun 2026 onward only.
final DateTime clockHoursGoLiveDate = DateTime(2026, 6, 29);

bool isClockHoursTrackingActive(DateTime day) {
  return !normalizeWorkDate(day).isBefore(normalizeWorkDate(clockHoursGoLiveDate));
}

String clockHoursGoLiveLabel() =>
    DateFormat('dd MMM yyyy (EEE)').format(clockHoursGoLiveDate);

bool get isClockHoursLiveYet => isClockHoursTrackingActive(DateTime.now());

bool isSameWorkDate(DateTime? a, DateTime b) {
  if (a == null) return false;
  final left = normalizeWorkDate(a);
  final right = normalizeWorkDate(b);
  return left == right;
}

int decimalHoursToMinutes(double hours) {
  return (hours * 60).round();
}

bool isClockDayComplete({
  required int clockedMinutes,
  required int attendanceMinutes,
}) {
  if (attendanceMinutes <= 0) return false;
  return clockedMinutes >= attendanceMinutes - 1;
}

String formatClockHours(double hours) {
  if (hours <= 0) return '0 h';
  final whole = hours.truncate();
  final minutes = ((hours - whole) * 60).round();
  if (minutes == 0) return '$whole h';
  return '$whole h ${minutes.toString().padLeft(2, '0')} m';
}

String formatClockHoursFromMinutes(int minutes) {
  return formatClockHours(minutes / 60.0);
}

Stream<List<ClockMasterItem>> watchSelectableClockClients(String employeeId) {
  return FirebaseFirestore.instance
      .collection(clockClientsCollection)
      .snapshots()
      .map((snapshot) => _selectableMasterItems(snapshot.docs, employeeId));
}

Stream<List<ClockMasterItem>> watchSelectableClockTasks(String employeeId) {
  return FirebaseFirestore.instance
      .collection(clockTasksCollection)
      .snapshots()
      .map((snapshot) => _selectableMasterItems(snapshot.docs, employeeId));
}

List<ClockMasterItem> _selectableMasterItems(
  List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  String employeeId,
) {
  final items = <ClockMasterItem>[];
  for (final doc in docs) {
    final data = doc.data();
    if (isApprovedMasterData(data)) {
      items.add(ClockMasterItem.fromDoc(doc));
    } else if (isPendingMasterForEmployee(data, employeeId)) {
      items.add(ClockMasterItem.fromDoc(doc, isPending: true));
    }
  }
  items.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return items;
}

Future<void> submitMasterItemRequest({
  required String collection,
  required String name,
  required String employeeId,
  required String employeeName,
}) async {
  final trimmed = name.trim();
  if (trimmed.isEmpty) {
    throw const ClockHoursValidationException('Name cannot be empty.');
  }

  final docId = clockDocIdFromName(trimmed);
  final ref = FirebaseFirestore.instance.collection(collection).doc(docId);
  final existing = await ref.get();

  if (existing.exists) {
    final data = existing.data() ?? {};
    final status = masterItemStatus(data);
    if (status == 'approved') {
      throw ClockHoursValidationException('"$trimmed" already exists.');
    }
    if (status == 'pending') {
      if (data['requestedBy']?.toString() == employeeId) {
        throw ClockHoursValidationException(
          'You already requested "$trimmed". Waiting for admin approval.',
        );
      }
      throw ClockHoursValidationException(
        '"$trimmed" is already pending admin review.',
      );
    }
  }

  await ref.set(
    {
      'name': trimmed,
      'normalizedName': normalizeClockName(trimmed),
      'isActive': false,
      'status': 'pending',
      'source': 'employee',
      'requestedBy': employeeId,
      'requestedByName': employeeName,
      'requestedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      if (!existing.exists) 'createdAt': FieldValue.serverTimestamp(),
    },
    SetOptions(merge: true),
  );
}

Future<void> submitClockClientRequest({
  required String name,
  required String employeeId,
  required String employeeName,
}) {
  return submitMasterItemRequest(
    collection: clockClientsCollection,
    name: name,
    employeeId: employeeId,
    employeeName: employeeName,
  );
}

Future<void> submitClockTaskRequest({
  required String name,
  required String employeeId,
  required String employeeName,
}) {
  return submitMasterItemRequest(
    collection: clockTasksCollection,
    name: name,
    employeeId: employeeId,
    employeeName: employeeName,
  );
}


Stream<List<ClockHourEntry>> watchMyClockHours(String employeeId) {
  return FirebaseFirestore.instance
      .collection(clockHoursCollection)
      .where('employeeId', isEqualTo: employeeId)
      .snapshots()
      .map((snapshot) {
        final entries = snapshot.docs.map(ClockHourEntry.fromDoc).toList();
        entries.sort((a, b) {
          final ad = a.workDate ?? DateTime(1970);
          final bd = b.workDate ?? DateTime(1970);
          return bd.compareTo(ad);
        });
        return entries;
      });
}

Future<Map<String, dynamic>?> fetchAttendanceForDate({
  required String employeeId,
  required DateTime date,
}) async {
  final day = normalizeWorkDate(date);
  final snap = await FirebaseFirestore.instance
      .collection('attendance')
      .where('userId', isEqualTo: employeeId)
      .where('punchInDate', isEqualTo: day)
      .limit(1)
      .get();

  if (snap.docs.isEmpty) return null;
  return snap.docs.first.data();
}

Future<double> fetchClockedHoursForDate({
  required String employeeId,
  required DateTime date,
  String? excludeEntryId,
}) async {
  final day = normalizeWorkDate(date);
  final snap = await FirebaseFirestore.instance
      .collection(clockHoursCollection)
      .where('employeeId', isEqualTo: employeeId)
      .get();

  var total = 0.0;
  for (final doc in snap.docs) {
    if (excludeEntryId != null && doc.id == excludeEntryId) continue;
    final entry = ClockHourEntry.fromDoc(doc);
    if (isSameWorkDate(entry.workDate, day)) {
      total += entry.hours;
    }
  }
  return total;
}

Future<ClockDayStatus> getClockDayStatus({
  required String employeeId,
  required DateTime date,
  String? excludeEntryId,
  double additionalHours = 0,
}) async {
  final day = normalizeWorkDate(date);
  final attendance = await fetchAttendanceForDate(
    employeeId: employeeId,
    date: day,
  );
  final hasAttendance = attendance != null;
  final hasPunchOut = attendance?['punchOutTime'] != null;
  final attendanceMinutes = hasPunchOut
      ? (AttendanceUtils.parseStoredMinutes(attendance!['totalHours']) ?? 0)
      : 0;

  final existingHours = await fetchClockedHoursForDate(
    employeeId: employeeId,
    date: day,
    excludeEntryId: excludeEntryId,
  );
  final clockedMinutes =
      decimalHoursToMinutes(existingHours + additionalHours);
  final remainingMinutes =
      (attendanceMinutes - clockedMinutes).clamp(0, attendanceMinutes);
  final isComplete = hasPunchOut &&
      attendanceMinutes > 0 &&
      isClockDayComplete(
        clockedMinutes: clockedMinutes,
        attendanceMinutes: attendanceMinutes,
      );

  return ClockDayStatus(
    date: day,
    hasAttendance: hasAttendance,
    hasPunchOut: hasPunchOut,
    attendanceMinutes: attendanceMinutes,
    clockedMinutes: clockedMinutes,
    remainingMinutes: remainingMinutes,
    isComplete: isComplete,
  );
}

bool shouldSkipClockDay({
  required String employeeId,
  required DateTime day,
  required Map<String, dynamic> employee,
  required Set<String> holidayDateKeys,
  required List<Map<String, dynamic>> leaveRecords,
}) {
  if (!isEmployeeActiveForSummaryDay(employee, day)) return true;
  if (isWeekendDayForEmployee(employee, day)) return true;
  if (holidayDateKeys.contains(attendanceDateKey(day))) return true;
  if (isApprovedLeaveOnDay(employeeId, day, leaveRecords)) return true;
  return false;
}

Future<DateTime?> findLastPendingClockDay({
  required String employeeId,
  required Map<String, dynamic> employee,
  required Set<String> holidayDateKeys,
  required List<Map<String, dynamic>> leaveRecords,
  DateTime? beforeDate,
}) async {
  final before = normalizeWorkDate(beforeDate ?? DateTime.now());
  final goLive = normalizeWorkDate(clockHoursGoLiveDate);
  if (before.isBefore(goLive)) {
    return null;
  }

  var day = before.subtract(const Duration(days: 1));

  final joinDate = employee['createdAt'] as DateTime?;
  final earliest = joinDate != null
      ? normalizeWorkDate(joinDate)
      : DateTime(2020, 1, 1);

  for (var i = 0; i < 90 && !day.isBefore(earliest); i++) {
    if (normalizeWorkDate(day).isBefore(goLive)) {
      return null;
    }
    if (!shouldSkipClockDay(
      employeeId: employeeId,
      day: day,
      employee: employee,
      holidayDateKeys: holidayDateKeys,
      leaveRecords: leaveRecords,
    )) {
      final attendance = await fetchAttendanceForDate(
        employeeId: employeeId,
        date: day,
      );
      if (attendance != null && attendance['punchOutTime'] != null) {
        final attendanceMinutes =
            AttendanceUtils.parseStoredMinutes(attendance['totalHours']) ?? 0;
        if (attendanceMinutes <= 0) {
          day = day.subtract(const Duration(days: 1));
          continue;
        }

        final clockedHours = await fetchClockedHoursForDate(
          employeeId: employeeId,
          date: day,
        );
        final clockedMinutes = decimalHoursToMinutes(clockedHours);
        if (!isClockDayComplete(
          clockedMinutes: clockedMinutes,
          attendanceMinutes: attendanceMinutes,
        )) {
          return day;
        }
        return null;
      }
    }
    day = day.subtract(const Duration(days: 1));
  }

  return null;
}

Future<ClockComplianceResult> checkPunchInClockCompliance(
  String employeeId,
) async {
  final userDoc = await FirebaseFirestore.instance
      .collection('users')
      .doc(employeeId)
      .get();
  if (!userDoc.exists) {
    return const ClockComplianceResult(canPunchIn: true);
  }
  final employee = employeeProfileFromUserDoc(
    userDoc as DocumentSnapshot<Map<String, dynamic>>,
  );

  final holidaysSnap =
      await FirebaseFirestore.instance.collection('holidays').get();
  final holidayKeys = buildHolidayDateKeys(
    holidayRecordsFromSnapshot(holidaysSnap),
  );

  final leavesSnap = await FirebaseFirestore.instance
      .collection('leaves')
      .where('userId', isEqualTo: employeeId)
      .get();
  final leaves = leaveRecordsFromSnapshot(leavesSnap);

  final pendingDate = await findLastPendingClockDay(
    employeeId: employeeId,
    employee: employee,
    holidayDateKeys: holidayKeys,
    leaveRecords: leaves,
  );

  if (pendingDate == null) {
    return const ClockComplianceResult(canPunchIn: true);
  }

  final attendance = await fetchAttendanceForDate(
    employeeId: employeeId,
    date: pendingDate,
  );
  final attendanceMinutes =
      AttendanceUtils.parseStoredMinutes(attendance?['totalHours']) ?? 0;
  final clockedHours = await fetchClockedHoursForDate(
    employeeId: employeeId,
    date: pendingDate,
  );
  final clockedMinutes = decimalHoursToMinutes(clockedHours);
  final remainingMinutes = (attendanceMinutes - clockedMinutes).clamp(0, 99999);
  final dateLabel =
      '${pendingDate.day.toString().padLeft(2, '0')}/${pendingDate.month.toString().padLeft(2, '0')}/${pendingDate.year}';

  return ClockComplianceResult(
    canPunchIn: false,
    pendingDate: pendingDate,
    pendingAttendanceMinutes: attendanceMinutes,
    pendingClockedMinutes: clockedMinutes,
    message:
        'Log clock hours for $dateLabel before punching in today. '
        'Worked ${AttendanceUtils.formatMinutes(attendanceMinutes)}, '
        'logged ${formatClockHoursFromMinutes(clockedMinutes)}, '
        'remaining ${formatClockHoursFromMinutes(remainingMinutes)}.',
  );
}

Future<bool> isClockHoursDayLocked({
  required String employeeId,
  required DateTime workDate,
}) {
  return hasAttendancePunchInAfterDate(
    employeeId: employeeId,
    date: workDate,
  );
}

Future<void> assertClockHoursDayEditable({
  required String employeeId,
  required DateTime workDate,
}) async {
  if (await isClockHoursDayLocked(
    employeeId: employeeId,
    workDate: workDate,
  )) {
    final dayLabel = DateFormat('dd MMM yyyy').format(normalizeWorkDate(workDate));
    throw ClockHoursValidationException(
      '$dayLabel is locked. You punched in on a later day, '
      'so past clock hours cannot be changed.',
    );
  }
}

Future<Set<DateTime>> lockedClockWorkDates({
  required String employeeId,
  required Iterable<DateTime> dates,
}) async {
  final locked = <DateTime>{};
  for (final date in dates) {
    final day = normalizeWorkDate(date);
    if (await isClockHoursDayLocked(employeeId: employeeId, workDate: day)) {
      locked.add(day);
    }
  }
  return locked;
}

Future<void> validateClockHourSubmission({
  required String employeeId,
  required DateTime workDate,
  required double hours,
  String? excludeEntryId,
}) async {
  final day = normalizeWorkDate(workDate);
  final today = normalizeWorkDate(DateTime.now());

  await assertClockHoursDayEditable(employeeId: employeeId, workDate: day);

  if (!isClockHoursTrackingActive(day)) {
    throw ClockHoursValidationException(
      'Clock hours tracking starts from ${clockHoursGoLiveLabel()}.',
    );
  }

  if (day.isAfter(today)) {
    throw const ClockHoursValidationException(
      'You cannot log clock hours for a future date.',
    );
  }

  if (hours <= 0) {
    throw const ClockHoursValidationException('Enter a valid number of hours.');
  }

  final status = await getClockDayStatus(
    employeeId: employeeId,
    date: day,
    excludeEntryId: excludeEntryId,
    additionalHours: hours,
  );

  if (!status.hasAttendance) {
    throw ClockHoursValidationException(
      'No attendance found for ${day.day}/${day.month}/${day.year}. '
      'You can only log clock hours on days you punched in.',
    );
  }

  if (!status.hasPunchOut) {
    throw const ClockHoursValidationException(
      'Please punch out first, then log clock hours for that day.',
    );
  }

  if (status.attendanceMinutes <= 0) {
    throw const ClockHoursValidationException(
      'No worked hours recorded for this day.',
    );
  }

  if (status.clockedMinutes > status.attendanceMinutes) {
    throw ClockHoursValidationException(
      'Total clock hours cannot exceed worked hours '
      '(${AttendanceUtils.formatMinutes(status.attendanceMinutes)}). '
      'You can log up to ${formatClockHoursFromMinutes(status.remainingMinutes)} more.',
    );
  }
}

Future<void> submitClockHour({
  required String employeeId,
  required String employeeName,
  required String clientName,
  required String taskName,
  required DateTime workDate,
  required double hours,
  String notes = '',
}) async {
  await validateClockHourSubmission(
    employeeId: employeeId,
    workDate: workDate,
    hours: hours,
  );

  final day = normalizeWorkDate(workDate);

  await FirebaseFirestore.instance.collection(clockHoursCollection).add({
    'employeeId': employeeId,
    'employeeName': employeeName,
    'clientName': clientName.trim(),
    'taskName': taskName.trim(),
    'hours': double.parse(hours.toStringAsFixed(2)),
    'workDate': Timestamp.fromDate(day),
    'notes': notes.trim(),
    'createdAt': FieldValue.serverTimestamp(),
  });
}

Future<bool> hasAttendancePunchInAfterDate({
  required String employeeId,
  required DateTime date,
}) async {
  final cutoff = normalizeWorkDate(date);
  final snap = await FirebaseFirestore.instance
      .collection('attendance')
      .where('userId', isEqualTo: employeeId)
      .get();

  for (final doc in snap.docs) {
    final data = doc.data();
    if (data['punchInTime'] == null) continue;
    final day = AttendanceUtils.parseRecordDate(data);
    if (day != null && day.isAfter(cutoff)) {
      return true;
    }
  }
  return false;
}

Future<void> deleteClockHourEntry({
  required String employeeId,
  required ClockHourEntry entry,
}) async {
  final day = entry.workDate;
  if (day == null) {
    throw const ClockHoursValidationException('Invalid entry date.');
  }

  await assertClockHoursDayEditable(employeeId: employeeId, workDate: day);

  await FirebaseFirestore.instance
      .collection(clockHoursCollection)
      .doc(entry.id)
      .delete();
}

Future<List<DateTime>> fetchClockEligibleDates({
  required String employeeId,
  int lookbackDays = 60,
}) async {
  final today = normalizeWorkDate(DateTime.now());
  final start = today.subtract(Duration(days: lookbackDays));

  final snap = await FirebaseFirestore.instance
      .collection('attendance')
      .where('userId', isEqualTo: employeeId)
      .get();

  final dates = <DateTime>[];
  for (final doc in snap.docs) {
    final data = doc.data();
    if (data['punchOutTime'] == null) continue;
    final day = AttendanceUtils.parseRecordDate(data);
    if (day == null || day.isBefore(start) || day.isAfter(today)) continue;
    if (!isClockHoursTrackingActive(day)) continue;
    if (dates.any((existing) => isSameWorkDate(existing, day))) continue;
    if (await isClockHoursDayLocked(employeeId: employeeId, workDate: day)) {
      continue;
    }
    dates.add(day);
  }

  dates.sort((a, b) => b.compareTo(a));
  return dates;
}
