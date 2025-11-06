import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';

class LeaveScreen extends StatefulWidget {
  const LeaveScreen({super.key});

  @override
  State<LeaveScreen> createState() => _LeaveScreenState();
}

class _LeaveScreenState extends State<LeaveScreen> {
  DateTimeRange? _selectedRange;
  String? _leaveType;
  final TextEditingController _reasonController = TextEditingController();
  bool _loading = false;

  bool _showAll = false;
  int _selectedYear = DateTime.now().year;
  final ScrollController _scrollController = ScrollController();

  final List<String> _leaveTypes = [
    "Casual Leave",
    "Sick Leave",
    "Paid Leave",
    "Emergency Leave",
  ];

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 1),
      initialDateRange: DateTimeRange(start: now, end: now),
    );

    if (picked != null) {
      setState(() {
        _selectedRange = picked;
      });
    }
  }

  Future<void> _applyLeave() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (_selectedRange == null ||
        _leaveType == null ||
        _reasonController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please fill all details.")),
      );
      return;
    }

    setState(() => _loading = true);

    final leaveRef = FirebaseFirestore.instance.collection("leaves");

    // Check for overlapping leave
    final overlap = await leaveRef
        .where("userId", isEqualTo: userId)
        .get();

    for (var doc in overlap.docs) {
      final data = doc.data();
      final existingStart = (data["startDate"] as Timestamp).toDate();
      final existingEnd = (data["endDate"] as Timestamp).toDate();

      if (_selectedRange!.start.isBefore(existingEnd.add(const Duration(days: 1))) &&
          _selectedRange!.end.isAfter(existingStart.subtract(const Duration(days: 1)))) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("Leave already applied for selected dates.")),
        );
        return;
      }
    }

    await leaveRef.add({
      "userId": userId,
      "startDate": _selectedRange!.start,
      "endDate": _selectedRange!.end,
      "reason": _reasonController.text.trim(),
      "type": _leaveType,
      "status": "Pending",
      "appliedOn": DateTime.now(),
    });

    setState(() => _loading = false);

    Navigator.pop(context);
    _reasonController.clear();
    _selectedRange = null;
    _leaveType = null;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Leave request submitted successfully!")),
    );
  }

  void _showApplyLeaveDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text("Apply for Leave"),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton.icon(
                    onPressed: () async {
                      await _pickDateRange();
                      setDialogState(() {});
                    },
                    icon: const Icon(Icons.date_range),
                    label: Text(
                      _selectedRange == null
                          ? "Select Date Range"
                          : "${DateFormat('dd MMM').format(_selectedRange!.start)} - ${DateFormat('dd MMM yyyy').format(_selectedRange!.end)}",
                    ),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orangeAccent),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: _leaveType,
                    decoration: const InputDecoration(
                      labelText: "Leave Type",
                      border: OutlineInputBorder(),
                    ),
                    items: _leaveTypes
                        .map((type) =>
                        DropdownMenuItem(value: type, child: Text(type)))
                        .toList(),
                    onChanged: (val) => setDialogState(() => _leaveType = val),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _reasonController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: "Reason",
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel"),
              ),
              ElevatedButton(
                onPressed: _loading ? null : _applyLeave,
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orangeAccent),
                child: _loading
                    ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2),
                )
                    : const Text("Submit"),
              ),
            ],
          );
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final userId = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(
        title: const Text("My Leave Requests"),
        backgroundColor: Colors.orangeAccent,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: "Apply Leave",
            onPressed: _showApplyLeaveDialog,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // 🔸 Top Controls
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Show All Toggle (Left)
                Row(
                  children: [
                    Switch(
                      value: _showAll,
                      activeColor: Colors.orangeAccent,
                      onChanged: (val) {
                        setState(() {
                          _showAll = val;
                          _selectedRange = null;
                        });
                      },
                    ),
                    const Text("Show All"),
                  ],
                ),

                // Center Filter or Year Picker
                if (!_showAll)
                  ElevatedButton.icon(
                    onPressed: () async {
                      final picked = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(DateTime.now().year - 1),
                        lastDate: DateTime(DateTime.now().year + 1),
                        initialDateRange: _selectedRange ??
                            DateTimeRange(
                              start: DateTime(DateTime.now().year, DateTime.now().month, 1),
                              end: DateTime(DateTime.now().year, DateTime.now().month + 1, 0),
                            ),
                      );
                      if (picked != null) {
                        setState(() {
                          _selectedRange = picked;
                        });
                      }
                    },
                    icon: const Icon(Icons.filter_alt_outlined),
                    label: const Text("Filter"),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orangeAccent),
                  )
                else
                  DropdownButton<int>(
                    value: _selectedYear,
                    items: List.generate(5, (i) {
                      int year = DateTime.now().year - i;
                      return DropdownMenuItem(value: year, child: Text("$year"));
                    }),
                    onChanged: (val) {
                      setState(() => _selectedYear = val!);
                    },
                  ),
              ],
            ),

            const SizedBox(height: 8),

            // 🔸 Dynamic Label
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _showAll
                    ? "Showing Year: $_selectedYear"
                    : _selectedRange != null
                    ? "Showing ${DateFormat('dd MMM').format(_selectedRange!.start)} - ${DateFormat('dd MMM yyyy').format(_selectedRange!.end)}"
                    : "Showing ${DateFormat('dd MMM').format(DateTime(DateTime.now().year, DateTime.now().month, 1))} - ${DateFormat('dd MMM yyyy').format(DateTime(DateTime.now().year, DateTime.now().month + 1, 0))}",
                style: const TextStyle(
                    fontWeight: FontWeight.w600, color: Colors.black54),
              ),
            ),

            const Divider(),

            // 🔸 Leave List
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection("leaves")
                    .where("userId", isEqualTo: userId)
                    .orderBy("startDate", descending: true)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final docs = snapshot.data!.docs;
                  if (docs.isEmpty) {
                    return const Center(child: Text("No leave requests yet."));
                  }

                  final now = DateTime.now();

                  // Apply filter logic
                  final filtered = docs.where((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    final start = (data["startDate"] as Timestamp).toDate();

                    if (_showAll) return start.year == _selectedYear;

                    if (_selectedRange != null) {
                      return start.isAfter(
                          _selectedRange!.start.subtract(const Duration(days: 1))) &&
                          start.isBefore(
                              _selectedRange!.end.add(const Duration(days: 1)));
                    }

                    return start.month == now.month && start.year == now.year;
                  }).toList();

                  // Count total leave days
                  int totalLeaves = 0;
                  for (var doc in filtered) {
                    final data = doc.data() as Map<String, dynamic>;
                    final start = (data["startDate"] as Timestamp).toDate();
                    final end = (data["endDate"] as Timestamp).toDate();
                    totalLeaves += end.difference(start).inDays + 1;
                  }

                  return Column(
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Row(
                          children: [
                            const Icon(Icons.calendar_today, color: Colors.orange, size: 18),
                            const SizedBox(width: 6),
                            Text(
                              "${filtered.length} Requests • $totalLeaves Day(s)",
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.orange,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                  child: Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: true, // 👈 Always show scrollbar
                  radius: const Radius.circular(6),
                  thickness: 6,
                        child: ListView.builder(
                  controller: _scrollController,
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final data = filtered[index].data() as Map<String, dynamic>;
                            final start = (data["startDate"] as Timestamp).toDate();
                            final end = (data["endDate"] as Timestamp).toDate();
                            final status = data["status"] ?? "Pending";
                            final reason = data["reason"] ?? "No reason provided";
                            final type = data["type"] ?? "Leave";

                            Color statusColor = Colors.orange;
                            if (status.toLowerCase() == "approved") statusColor = Colors.green;
                            if (status.toLowerCase() == "rejected") statusColor = Colors.red;

                            return Card(
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              elevation: 2,
                              margin: const EdgeInsets.symmetric(vertical: 6),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          start == end
                                              ? DateFormat('dd MMM yyyy').format(start)
                                              : "${DateFormat('dd MMM').format(start)} - ${DateFormat('dd MMM yyyy').format(end)}",
                                          style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold),
                                        ),
                                        Chip(
                                          label: Text(status,
                                              style: const TextStyle(
                                                  color: Colors.white)),
                                          backgroundColor: statusColor,
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text("Type: $type",
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w500)),
                                    const SizedBox(height: 4),
                                    Text("Reason: $reason",
                                        style: const TextStyle(
                                            color: Colors.black87)),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

}
