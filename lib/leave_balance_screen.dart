import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'utils/leave_utils.dart';

class LeaveBalanceScreen extends StatefulWidget {
  const LeaveBalanceScreen({super.key});

  @override
  State<LeaveBalanceScreen> createState() => _LeaveBalanceScreenState();
}

class _LeaveBalanceScreenState extends State<LeaveBalanceScreen> {
  static const _accent = Colors.orangeAccent;

  LeaveCycle _selectedCycle = LeaveCycle.containing(DateTime.now());
  EmployeeLeaveStats? _stats;
  bool _loading = true;

  String get _accrualHelpText {
    final cycleLabel = _selectedCycle.label;
    final range =
        '${DateFormat('dd MMM yyyy').format(_selectedCycle.start)} – '
        '${DateFormat('dd MMM yyyy').format(_selectedCycle.end)}';
    return 'Leave year $cycleLabel ($range). '
        'Accrued = 1 leave per eligible month (max 12). '
        'New joiners get the join month only if they join on or before the 5th. '
        'Total = Opening + Accrued. Balance = Total − Taken.';
  }

  Future<void> _loadData() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) {
      setState(() {
        _loading = false;
        _stats = null;
      });
      return;
    }

    setState(() => _loading = true);

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      final employee = employeeProfileFromFirestore(userDoc);
      final stats = await buildLeaveStatsForEmployee(
        employee: employee,
        cycle: _selectedCycle,
      );

      if (!mounted) return;
      setState(() {
        _stats = stats;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading leave data: $e')),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _pickCycle() async {
    final cycles = LeaveCycle.recentCycles(count: 6);
    final picked = await showDialog<LeaveCycle>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select leave year (Apr–Mar)'),
        content: SizedBox(
          width: 280,
          child: ListView(
            shrinkWrap: true,
            children: cycles.map((cycle) {
              return ListTile(
                title: Text(cycle.label),
                subtitle: Text(
                  '${DateFormat('MMM yyyy').format(cycle.start)} – '
                  '${DateFormat('MMM yyyy').format(cycle.end)}',
                ),
                selected: cycle.startYear == _selectedCycle.startYear,
                onTap: () => Navigator.pop(context, cycle),
              );
            }).toList(),
          ),
        ),
      ),
    );

    if (picked != null && picked.startYear != _selectedCycle.startYear) {
      setState(() => _selectedCycle = picked);
      await _loadData();
    }
  }

  Widget _buildStatTile(String label, String value, Color color) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Colors.black87,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    final stat = _stats;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          stat != null
              ? '${stat.name} · Leave ${_selectedCycle.label}'
              : 'Leave Balance',
        ),
        backgroundColor: _accent,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadData,
          ),
        ],
      ),
      body: userId == null
          ? const Center(child: Text('Please log in to view leave balance.'))
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _loadData,
                  child: stat == null
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 120),
                            Center(child: Text('No leave data found')),
                          ],
                        )
                      : ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(16),
                          children: [
                            ElevatedButton.icon(
                              onPressed: _pickCycle,
                              icon: const Icon(Icons.calendar_today),
                              label: Text('Year: ${_selectedCycle.label}'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _accent,
                                foregroundColor: Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              '${stat.name} · Leave ${_selectedCycle.label}',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            _buildStatTile(
                              'Opening',
                              stat.openingBalance.toStringAsFixed(1),
                              Colors.blueGrey,
                            ),
                            _buildStatTile(
                              'Total',
                              stat.total.toStringAsFixed(1),
                              Colors.blue,
                            ),
                            _buildStatTile(
                              'Accrued',
                              stat.accrued.toStringAsFixed(1),
                              Colors.orange,
                            ),
                            _buildStatTile(
                              'Taken',
                              stat.taken.toStringAsFixed(1),
                              Colors.deepPurple,
                            ),
                            _buildStatTile(
                              'Balance',
                              stat.balance.toStringAsFixed(1),
                              stat.balance < 0 ? Colors.red : Colors.green,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _accrualHelpText,
                              style: const TextStyle(
                                color: Colors.black54,
                                fontSize: 12,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                ),
    );
  }
}
