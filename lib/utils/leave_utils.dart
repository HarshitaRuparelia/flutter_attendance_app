import 'package:cloud_firestore/cloud_firestore.dart';

import 'employee_attendance_summary.dart';

/// Leave accrues at 1 day per eligible calendar month (max 12 per Apr–Mar cycle).
const double leaveAccrualPerMonth = 1.0;

/// Join on or before this day of the month → that month accrues 1 leave.
const int leaveJoinAccrualCutoffDay = 5;

int countLeaveDays(DateTime start, DateTime end) {
  final s = normalizeDate(start);
  final e = normalizeDate(end);
  return e.difference(s).inDays + 1;
}

/// Leave year starting April [startYear] → March [startYear + 1].
class LeaveCycle {
  final int startYear;

  const LeaveCycle(this.startYear);

  DateTime get start => DateTime(startYear, 4, 1);

  DateTime get end => DateTime(startYear + 1, 3, 31);

  String get label => '$startYear-${(startYear + 1) % 100}';

  bool contains(DateTime date) {
    final d = normalizeDate(date);
    return !d.isBefore(start) && !d.isAfter(end);
  }

  static LeaveCycle containing(DateTime date) {
    if (date.month >= 4) return LeaveCycle(date.year);
    return LeaveCycle(date.year - 1);
  }

  static List<LeaveCycle> recentCycles({int count = 5}) {
    final current = LeaveCycle.containing(DateTime.now());
    return List.generate(
      count,
      (index) => LeaveCycle(current.startYear - index),
    );
  }
}

DateTime _monthEnd(int year, int month) => DateTime(year, month + 1, 0);

DateTime _nextMonthStart(DateTime monthStart) =>
    DateTime(monthStart.year, monthStart.month + 1, 1);

int countAccruedLeaveMonths({
  required LeaveCycle cycle,
  required DateTime? joinDate,
  required DateTime? resignedDate,
  required DateTime asOf,
}) {
  final effectiveAsOf = normalizeDate(
    asOf.isAfter(cycle.end) ? cycle.end : asOf,
  );
  if (effectiveAsOf.isBefore(cycle.start)) return 0;

  var monthCursor = cycle.start;
  var count = 0;

  while (!monthCursor.isAfter(
    DateTime(effectiveAsOf.year, effectiveAsOf.month, 1),
  )) {
    if (_isMonthEligibleForAccrual(
      monthCursor,
      joinDate: joinDate,
      resignedDate: resignedDate,
    )) {
      count++;
    }
    if (monthCursor.month == 3 && monthCursor.year == cycle.end.year) {
      break;
    }
    monthCursor = _nextMonthStart(monthCursor);
  }

  return count;
}

bool _isMonthEligibleForAccrual(
  DateTime monthStart, {
  required DateTime? joinDate,
  required DateTime? resignedDate,
}) {
  final monthEnd = _monthEnd(monthStart.year, monthStart.month);

  if (joinDate != null) {
    final join = normalizeDate(joinDate);
    if (join.isAfter(monthEnd)) return false;
    if (join.year == monthStart.year && join.month == monthStart.month) {
      return join.day <= leaveJoinAccrualCutoffDay;
    }
  }

  if (resignedDate != null) {
    final resigned = normalizeDate(resignedDate);
    if (resigned.isBefore(monthStart)) {
      return false;
    }
  }

  return true;
}

double accruedLeaveDays({
  required LeaveCycle cycle,
  required DateTime? joinDate,
  required DateTime? resignedDate,
  required DateTime asOf,
}) {
  final months = countAccruedLeaveMonths(
    cycle: cycle,
    joinDate: joinDate,
    resignedDate: resignedDate,
    asOf: asOf,
  );
  return double.parse((months * leaveAccrualPerMonth).toStringAsFixed(1));
}

double openingBalanceForCycle(
  Map<String, dynamic> employee,
  LeaveCycle cycle,
) {
  final balances = employee['leaveOpeningBalances'];
  if (balances is Map) {
    final raw = balances[cycle.startYear.toString()] ??
        balances[cycle.startYear];
    if (raw is num) return raw.toDouble();
  }
  final legacy = employee['leaveOpeningBalance'];
  if (legacy is num) return legacy.toDouble();
  return 0;
}

class EmployeeLeaveStats {
  final String userId;
  final String name;
  final LeaveCycle cycle;
  final double openingBalance;
  final double accrued;
  final double taken;
  final double total;
  final double balance;

  const EmployeeLeaveStats({
    required this.userId,
    required this.name,
    required this.cycle,
    required this.openingBalance,
    required this.accrued,
    required this.taken,
    required this.total,
    required this.balance,
  });
}

Future<double> fetchApprovedLeaveDaysForUser({
  required String userId,
  required LeaveCycle cycle,
}) async {
  final snapshot = await FirebaseFirestore.instance
      .collection('leaves')
      .where('userId', isEqualTo: userId)
      .where('status', isEqualTo: 'Approved')
      .get();

  var taken = 0.0;

  for (final doc in snapshot.docs) {
    final data = doc.data();
    final start = (data['startDate'] as Timestamp?)?.toDate();
    final end = (data['endDate'] as Timestamp?)?.toDate();
    if (start == null || end == null) continue;

    if (end.isBefore(cycle.start) || start.isAfter(cycle.end)) continue;

    final clampedStart = start.isBefore(cycle.start) ? cycle.start : start;
    final clampedEnd = end.isAfter(cycle.end) ? cycle.end : end;
    taken += countLeaveDays(clampedStart, clampedEnd).toDouble();
  }

  return taken;
}

Future<Map<String, double>> fetchApprovedLeaveDaysByUserForCycle(
  LeaveCycle cycle,
) async {
  final snapshot = await FirebaseFirestore.instance
      .collection('leaves')
      .where('status', isEqualTo: 'Approved')
      .get();

  final takenByUser = <String, double>{};

  for (final doc in snapshot.docs) {
    final data = doc.data();
    final userId = data['userId']?.toString();
    if (userId == null || userId.isEmpty) continue;

    final start = (data['startDate'] as Timestamp?)?.toDate();
    final end = (data['endDate'] as Timestamp?)?.toDate();
    if (start == null || end == null) continue;

    if (end.isBefore(cycle.start) || start.isAfter(cycle.end)) continue;

    final clampedStart = start.isBefore(cycle.start) ? cycle.start : start;
    final clampedEnd = end.isAfter(cycle.end) ? cycle.end : end;
    final days = countLeaveDays(clampedStart, clampedEnd).toDouble();

    takenByUser[userId] = (takenByUser[userId] ?? 0) + days;
  }

  return takenByUser;
}

Future<EmployeeLeaveStats?> buildLeaveStatsForEmployee({
  required Map<String, dynamic> employee,
  required LeaveCycle cycle,
}) async {
  final userId = employee['uid']?.toString() ?? '';
  if (userId.isEmpty) return null;

  final taken = await fetchApprovedLeaveDaysForUser(
    userId: userId,
    cycle: cycle,
  );
  final now = DateTime.now();
  final asOf = cycle.contains(now) ? now : cycle.end;

  final joinDate = employee['createdAt'] as DateTime?;
  final resignedDate = employee['resignedDate'] as DateTime?;
  final opening = openingBalanceForCycle(employee, cycle);
  final accrued = accruedLeaveDays(
    cycle: cycle,
    joinDate: joinDate,
    resignedDate: resignedDate,
    asOf: asOf,
  );
  final total = double.parse((opening + accrued).toStringAsFixed(1));
  final balance = double.parse((total - taken).toStringAsFixed(1));

  return EmployeeLeaveStats(
    userId: userId,
    name: employee['name']?.toString() ?? 'Unknown',
    cycle: cycle,
    openingBalance: opening,
    accrued: accrued,
    taken: taken,
    total: total,
    balance: balance,
  );
}

Map<String, dynamic> employeeProfileFromFirestore(
  DocumentSnapshot<Map<String, dynamic>> doc,
) {
  final data = doc.data() ?? {};
  return {
    'uid': doc.id,
    'name': data['name']?.toString() ?? 'User',
    'createdAt': parseCreatedAt(data),
    'resignedDate': parseResignedDate(data),
    'leaveOpeningBalances': data['leaveOpeningBalances'],
    'leaveOpeningBalance': data['leaveOpeningBalance'],
  };
}
