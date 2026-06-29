import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'utils/attendance_utils.dart';
import 'utils/employee_attendance_summary.dart';

class AttendanceHistoryScreen extends StatefulWidget {
  const AttendanceHistoryScreen({super.key});

  @override
  State<AttendanceHistoryScreen> createState() =>
      _AttendanceHistoryScreenState();
}

class _AttendanceHistoryScreenState extends State<AttendanceHistoryScreen> {
  DateTime? _startDate;
  DateTime? _endDate;
  bool _loading = false;
  List<Map<String, dynamic>> _attendanceList = [];
  int _totalMinutesWorked = 0;
  final ScrollController _verticalController = ScrollController();
  final ScrollController _horizontalController = ScrollController();
  @override
  void dispose() {
    _verticalController.dispose();
    _horizontalController.dispose();
    super.dispose();
  }
  @override
  void initState() {
    super.initState();
    // Default to today
    final today = DateTime.now();
    _startDate = DateTime(today.year, today.month, today.day);
    _endDate = DateTime(today.year, today.month, today.day);

    // Fetch today's attendance immediately
    _fetchAttendanceData();
  }

  // Pick date range
  Future<void> _pickDateRange() async {
    final now = DateTime.now();

    // Use previously selected range, else default to today
    final initialRange = (_startDate != null && _endDate != null)
        ? DateTimeRange(start: _startDate!, end: _endDate!)
        : DateTimeRange(
      start: DateTime(now.year, now.month, now.day),
      end: DateTime(now.year, now.month, now.day),
    );

    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: now,
      initialDateRange: initialRange,
    );

    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
      _fetchAttendanceData();
    }
  }


  // Fetch attendance from Firestore
  Future<void> _fetchAttendanceData() async {
    if (_startDate == null || _endDate == null) return;

    setState(() {
      _loading = true;
      _attendanceList = [];
      _totalMinutesWorked = 0;
    });

    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) {
      setState(() => _loading = false);
      return;
    }

    final rangeStart = DateTime(
      _startDate!.year,
      _startDate!.month,
      _startDate!.day,
    );
    final rangeEnd = DateTime(
      _endDate!.year,
      _endDate!.month,
      _endDate!.day,
      23,
      59,
      59,
    );

    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .get();
    final employee = employeeProfileFromUserDoc(userDoc);

    final attSnap = await FirebaseFirestore.instance
        .collection('attendance')
        .where('userId', isEqualTo: userId)
        .where('punchInTime', isLessThanOrEqualTo: Timestamp.fromDate(rangeEnd))
        .where(
          'punchInTime',
          isGreaterThanOrEqualTo: Timestamp.fromDate(rangeStart),
        )
        .get();

    final leaveSnap = await FirebaseFirestore.instance
        .collection('leaves')
        .where('userId', isEqualTo: userId)
        .where('startDate', isLessThanOrEqualTo: Timestamp.fromDate(rangeEnd))
        .where(
          'endDate',
          isGreaterThanOrEqualTo: Timestamp.fromDate(rangeStart),
        )
        .get();

    final holidaySnap = await FirebaseFirestore.instance
        .collection('holidays')
        .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(rangeStart))
        .where('date', isLessThanOrEqualTo: Timestamp.fromDate(rangeEnd))
        .get();

    final attendanceRecords = attendanceRecordsFromSnapshot(attSnap);
    final leaveRecords = leaveRecordsFromSnapshot(leaveSnap);
    final holidayRecords = holidayRecordsFromSnapshot(holidaySnap);
    final holidayDateKeys = buildHolidayDateKeys(holidayRecords);

    final totalMins = calculateWorkedMinutesInRange(
      userId: userId,
      employee: employee,
      rangeStart: rangeStart,
      rangeEnd: _endDate!,
      attendanceRecords: attendanceRecords,
      leaveRecords: leaveRecords,
      holidayDateKeys: holidayDateKeys,
    );

    final List<Map<String, dynamic>> combined = [];

    for (final data in attendanceRecords) {
      if (!attendanceOverlapsRange(data, rangeStart, rangeEnd)) continue;
      if (!isEmployeeVisibleOnDate(employee, 
          AttendanceUtils.parseRecordDate(data) ?? rangeStart)) {
        continue;
      }

      final row = Map<String, dynamic>.from(data);
      row['type'] = 'Attendance';

      final punchOut = row['punchOutTime'];
      final rawMins = AttendanceUtils.parseStoredMinutes(row['totalHours']) ?? 0;
      row['totalHours'] = punchOut != null ? rawMins : 0;

      combined.add(row);
    }

    for (var doc in leaveSnap.docs) {
      final data = Map<String, dynamic>.from(doc.data());
      data['type'] = 'Leave';
      // map Firestore 'status' -> leaveStatus so UI shows correct field
      data['leaveStatus'] = (data['status'] ?? 'Pending').toString();
      // For sorting/display pick startDate as the date anchor
      combined.add(data);
    }

    // Sort combined by date descending (use punchInTime for attendance, startDate for leave)
    combined.sort((a, b) {
      DateTime dateA;
      if (a['type'] == 'Leave') {
        final ts = a['startDate'] as Timestamp?;
        dateA = ts?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
      } else {
        final ts = a['punchInTime'] as Timestamp?;
        dateA = ts?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
      }

      DateTime dateB;
      if (b['type'] == 'Leave') {
        final ts = b['startDate'] as Timestamp?;
        dateB = ts?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
      } else {
        final ts = b['punchInTime'] as Timestamp?;
        dateB = ts?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
      }

      return dateB.compareTo(dateA);
    });

    setState(() {
      _attendanceList = combined;
      _totalMinutesWorked = totalMins;
      _loading = false;
    });
  }

  void _showFullImage(String url) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        child: InteractiveViewer(
          child: Image.network(
            url,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return SizedBox(
                height: 200,
                child: const Center(
                  child: CircularProgressIndicator(),
                ),
              );
            },
            errorBuilder: (context, error, stackTrace) {
              return SizedBox(
                height: 200,
                child: const Center(
                  child: Icon(
                    Icons.image_not_supported,
                    size: 50,
                    //color: Colors.grey,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }


  // Convert minutes to “X hr Y min” format
  String _formatTotalHours(dynamic totalMinutes) {
    return AttendanceUtils.formatMinutes(
      AttendanceUtils.parseStoredMinutes(totalMinutes),
    );
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Attendance History"),
        backgroundColor: Colors.orangeAccent,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Date range picker
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _pickDateRange,
                    icon: const Icon(Icons.date_range),
                    label: Text(
                      _startDate == null || _endDate == null
                          ? "Select Date Range"
                          : (_startDate!.isAtSameMomentAs(_endDate!)
                          ? DateFormat('dd MMM yyyy').format(_startDate!)
                          : "${DateFormat('dd MMM yyyy').format(_startDate!)} - ${DateFormat('dd MMM yyyy').format(_endDate!)}"),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orangeAccent,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Summary row
            if (_attendanceList.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orangeAccent),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "Total Hours Worked:",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      _formatTotalHours(_totalMinutesWorked),
                      style: const TextStyle(
                        color: Colors.black87,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 16),

            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_attendanceList.isEmpty && _startDate != null)
              const Center(
                child: Text("No attendance data found for selected range."),
              )
            else if (_attendanceList.isNotEmpty)
              Expanded(
                child: Scrollbar(
                  controller: _verticalController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _verticalController,
                    child: Column(
                      children: [
                        Scrollbar(
                          controller: _horizontalController,
                          thumbVisibility: true,
                          notificationPredicate: (notif) =>
                              notif.metrics.axis == Axis.horizontal,
                          child: SingleChildScrollView(
                            controller: _horizontalController,
                            scrollDirection: Axis.horizontal,
                            child: Padding(
                              padding: const EdgeInsets.only(
                                bottom: 40,
                              ), // ✅ space for horizontal scrollbar
                              child: DataTable(
                                dataRowMaxHeight: 90,
                                columns: const [
                                  DataColumn(
                                    label: Text(
                                      "Date",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  DataColumn(
                                    label: Text(
                                      "Type",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  DataColumn(
                                    label: Text(
                                      "Punch In",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  DataColumn(
                                    label: Text(
                                      "Punch Out",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  DataColumn(
                                    label: Text(
                                      "Total Hrs",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  DataColumn(
                                    label: Text(
                                      "Exempt",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  DataColumn(
                                    label: Text(
                                      "Leave Status",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  DataColumn(
                                    label: Text(
                                      "In Selfie",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  DataColumn(
                                    label: Text(
                                      "Out Selfie",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                                rows: _attendanceList.map((data) {
                                  final type = (data['type'] ?? 'Attendance')
                                      .toString();

                                  if (type == 'Leave') {
                                    final start =
                                        (data['startDate'] as Timestamp?)
                                            ?.toDate();
                                    final end = (data['endDate'] as Timestamp?)
                                        ?.toDate();
                                    final leaveStatus =
                                        (data['leaveStatus'] ?? 'Pending')
                                            .toString();
                                    final statusColor =
                                        leaveStatus.toLowerCase() == 'approved'
                                        ? Colors.green
                                        : (leaveStatus.toLowerCase() ==
                                                  'rejected'
                                              ? Colors.red
                                              : Colors.orange);

                                    return DataRow(
                                      color: MaterialStateProperty.all(
                                        Colors.yellow.shade100,
                                      ),
                                      cells: [
                                        DataCell(
                                          Text(
                                            start != null
                                                ? (start == end
                                                      ? DateFormat(
                                                          'dd MMM yyyy',
                                                        ).format(start)
                                                      : "${DateFormat('dd MMM').format(start)} - ${DateFormat('dd MMM yyyy').format(end!)}")
                                                : '-',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        const DataCell(
                                          Text(
                                            'Leave',
                                            style: TextStyle(
                                              color: Colors.blue,
                                            ),
                                          ),
                                        ),
                                        const DataCell(Text('—')),
                                        const DataCell(Text('—')),
                                        const DataCell(Text('—')),
                                        const DataCell(Text('—')),
                                        DataCell(
                                          Text(
                                            leaveStatus,
                                            style: TextStyle(
                                              color: statusColor,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        const DataCell(Text('—')),
                                        const DataCell(Text('—')),
                                      ],
                                    );
                                  } else {
                                    final punchIn = (data['punchInTime'] as Timestamp?)?.toDate();
                                    final punchOut = (data['punchOutTime'] as Timestamp?)?.toDate();
                                    final isLate = data['isLate'] == true;
                                    final exemptionStatus = data['exemptionStatus'] ;
                                    final punchInUrl = data['punchInSelfieUrl'];
                                    final punchOutUrl = data['punchOutSelfieUrl'];
                                    bool isAutoLogout = data['autoLogout']== true;

                                    // 👉 CORRECT: Use "-" when no punch out
                                    String totalHoursStr;
                                    bool isHalfDay = false;

                                    if (punchOut == null) {
                                      totalHoursStr = "-";
                                    } else {
                                      final mins =
                                          AttendanceUtils.parseStoredMinutes(
                                                data['totalHours'],
                                              ) ??
                                              0;
                                      totalHoursStr = _formatTotalHours(mins);
                                      isHalfDay = mins < AttendanceUtils.fullDayMinutes;
                                    }


                                    return DataRow(
                                      color: MaterialStateProperty.all(
                                        Colors.white,
                                      ),
                                      cells: [
                                        DataCell(
                                          Text(
                                            punchIn != null
                                                ? DateFormat(
                                                    'dd MMM yyyy',
                                                  ).format(punchIn)
                                                : '-',
                                          ),
                                        ),
                                        const DataCell(Text('Attendance')),
                                        DataCell(
                                          Text(
                                            punchIn != null
                                                ? DateFormat(
                                                    'hh:mm a',
                                                  ).format(punchIn)
                                                : '-',
                                            style: TextStyle(
                                              color: isLate
                                                  ? Colors.red
                                                  : Colors.black,
                                              fontWeight: isLate ? FontWeight.bold : FontWeight.normal,
                                            ),
                                          ),
                                        ),
                                  DataCell(
                                  Container(
                                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                                  decoration: BoxDecoration(
                                  color: isAutoLogout ? Colors.red.withOpacity(0.15) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                  punchOut != null
                                      ? "${DateFormat('hh:mm a').format(punchOut)}${isAutoLogout ? ' \n(Auto punch-out)' : ''}"
                                      : '-',
                                  style: TextStyle(
                                 // color: isAutoLogout ? Colors.red : Colors.black,
                                  fontWeight: isAutoLogout ? FontWeight.bold : FontWeight.normal,
                                  ),
                                  ),
                                  ),
                                  ),


                                  // ✅ Total Hours Column with Half-Day logic
                                  DataCell(
                                  isHalfDay
                                  ? (exemptionStatus == "approved"
                                  // ⭐ Approved → Green + no half-day label + verified icon
                                  ? Row(
                                  children: [
                                  const Icon(
                                  Icons.verified_user,
                                  color: Colors.green,
                                  size: 18,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                  totalHoursStr,
                                  style: const TextStyle(
                                  color: Colors.green,
                                  fontWeight: FontWeight.bold,
                                  ),
                                  ),
                                  ],
                                  )

                                  // ❌ Not approved → Red + Half Day label + red clock icon
                                      : Row(
                                  children: [
                                  const Icon(
                                  Icons.access_time_filled,
                                  color: Colors.red,
                                  size: 18,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                  "$totalHoursStr (Half Day)",
                                  style: const TextStyle(
                                  color: Colors.red,
                                  fontWeight: FontWeight.bold,
                                  ),
                                  ),
                                  ],
                                  ))

                                  // Normal day → no icon, black text
                                      : Text(
                                  totalHoursStr,
                                  style: const TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                  ),
                                  ),
                                  ),


                                  DataCell(
                                          Builder(
                                            builder: (_) {
                                              String text = "Seek Exemption";
                                              Color color = Colors.orange;

                                             // final punchOutTime = data["punchOutTime"];
                                              final exemptionStatus = data["exemptionStatus"];

                                              // ➤ User has not punched out
                                              if (punchOut == null) {
                                                text = "Not punched out yet";
                                                color = Colors.black;
                                              }
                                              // ➤ Exemption Requested
                                              else if (exemptionStatus == "requested") {
                                                text = "Exemption Requested";
                                                color = Colors.grey;
                                              }
                                              // ➤ Exemption Approved
                                              else if (exemptionStatus == "approved") {
                                                text = "Exempted ✅";
                                                color = Colors.grey;
                                              }

                                              return Text(
                                                text,
                                                style: TextStyle(
                                                  color: color,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              );
                                            },
                                          ),
                                        ),

                                        const DataCell(Text('—')),
                                        DataCell(
                                          punchInUrl != null
                                              ? InkWell(
                                            onTap: () => _showFullImage(punchInUrl),
                                            child: Container(
                                              height: 40,
                                              width: 40,
                                              decoration: BoxDecoration(
                                                border: Border.all(color: Colors.grey.shade300),
                                              ),
                                              child: Image.network(
                                                punchInUrl,
                                                fit: BoxFit.cover,
                                                errorBuilder: (context, error, stackTrace) => const Icon(
                                                  Icons.image_not_supported,
                                                  size: 40,
                                                ),
                                              ),
                                            ),
                                          )
                                              : const Text('-'),
                                        ),

                                        DataCell(
                                          punchOutUrl != null
                                              ? InkWell(
                                            onTap: () => _showFullImage(punchOutUrl),
                                            child: Container(
                                              height: 40,
                                              width: 40,
                                              decoration: BoxDecoration(
                                                border: Border.all(color: Colors.grey.shade300),
                                              ),
                                              child: Image.network(
                                                punchOutUrl,
                                                fit: BoxFit.cover,
                                                errorBuilder: (context, error, stackTrace) => const Icon(
                                                  Icons.image_not_supported,
                                                  size: 40,
                                                ),
                                              ),
                                            ),
                                          )
                                              : const Text('-'),
                                        ),

                                      ],
                                    );
                                  }
                                }).toList(),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
