import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'utils/attendance_utils.dart';
import 'utils/clock_time_utils.dart';

class ClockHoursScreen extends StatefulWidget {
  final DateTime? initialWorkDate;
  final int initialTabIndex;

  const ClockHoursScreen({
    super.key,
    this.initialWorkDate,
    this.initialTabIndex = 0,
  });

  @override
  State<ClockHoursScreen> createState() => _ClockHoursScreenState();
}

class _ClockHoursScreenState extends State<ClockHoursScreen>
    with SingleTickerProviderStateMixin {
  static const _accent = Colors.orangeAccent;
  static const _hourStep = 0.5;

  late TabController _tabController;

  final _formKey = GlobalKey<FormState>();
  final _hoursController = TextEditingController();
  final _notesController = TextEditingController();

  String? _selectedClient;
  String? _selectedTask;
  DateTime? _workDate;
  ClockDayStatus? _dayStatus;
  bool _isWorkDateLocked = false;
  bool _loadingDayStatus = false;
  bool _submitting = false;
  String? _processingEntryId;
  String _employeeName = 'User';
  List<DateTime> _eligibleDates = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTabIndex.clamp(0, 1),
    );
    _workDate = widget.initialWorkDate ?? DateTime.now();
    _loadEmployeeName();
    _loadEligibleDates();
    _refreshDayStatus();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _hoursController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadEmployeeName() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();

    if (!mounted) return;
    setState(() {
      _employeeName =
          doc.data()?['name']?.toString() ?? user.email ?? 'User';
    });
  }

  Future<void> _loadEligibleDates() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final dates = await fetchClockEligibleDates(employeeId: user.uid);
      if (!mounted) return;

      setState(() {
        _eligibleDates = dates;
        if (dates.isNotEmpty &&
            _workDate != null &&
            !dates.any((d) => isSameWorkDate(d, _workDate!))) {
          _workDate = dates.first;
        } else if (dates.isEmpty) {
          _workDate = null;
        }
      });
      await _refreshDayStatus();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load dates: $e')),
      );
    }
  }

  Future<void> _refreshDayStatus() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _workDate == null) return;

    setState(() => _loadingDayStatus = true);
    try {
      final status = await getClockDayStatus(
        employeeId: user.uid,
        date: _workDate!,
      );
      final locked = await isClockHoursDayLocked(
        employeeId: user.uid,
        workDate: _workDate!,
      );
      if (!mounted) return;
      setState(() {
        _dayStatus = status;
        _isWorkDateLocked = locked;
      });
    } finally {
      if (mounted) setState(() => _loadingDayStatus = false);
    }
  }

  Future<void> _pickWorkDate() async {
    if (!isClockHoursLiveYet) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Clock hours start from ${clockHoursGoLiveLabel()}.',
          ),
        ),
      );
      return;
    }

    if (_eligibleDates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No punched-out days available yet. Punch out first, then log hours.',
          ),
        ),
      );
      return;
    }

    final picked = await showDialog<DateTime>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select work date'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _eligibleDates.length,
            itemBuilder: (context, index) {
              final date = _eligibleDates[index];
              return ListTile(
                title: Text(DateFormat('dd MMM yyyy (EEE)').format(date)),
                onTap: () => Navigator.pop(context, date),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (picked != null) {
      setState(() => _workDate = picked);
      await _refreshDayStatus();
    }
  }

  Future<String?> _pickMasterItem({
    required String title,
    required String? currentValue,
    required List<ClockMasterItem> items,
  }) async {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final selected = item.name == currentValue;
              return ListTile(
                title: Text(item.displayName),
                subtitle: item.isPending
                    ? const Text(
                        'Waiting for admin approval',
                        style: TextStyle(fontSize: 12, color: Colors.orange),
                      )
                    : null,
                trailing: selected
                    ? const Icon(Icons.check, color: Colors.green)
                    : null,
                selected: selected,
                onTap: () => Navigator.pop(context, item.name),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _requestNewMaster({required bool isClient}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isClient ? 'Request new client' : 'Request new task'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: isClient ? 'Client name' : 'Task name',
            border: const OutlineInputBorder(),
            helperText: 'Admin will review and approve.',
          ),
          autofocus: true,
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.isEmpty) return;

    try {
      if (isClient) {
        await submitClockClientRequest(
          name: result,
          employeeId: user.uid,
          employeeName: _employeeName,
        );
      } else {
        await submitClockTaskRequest(
          name: result,
          employeeId: user.uid,
          employeeName: _employeeName,
        );
      }
      if (!mounted) return;
      setState(() {
        if (isClient) {
          _selectedClient = result;
        } else {
          _selectedTask = result;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isClient
                ? 'Client "$result" submitted for approval. You can use it while pending.'
                : 'Task "$result" submitted for approval. You can use it while pending.',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } on ClockHoursValidationException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Request failed: $e')),
      );
    }
  }

  void _clearForm() {
    _hoursController.clear();
    _notesController.clear();
    setState(() {
      _selectedClient = null;
      _selectedTask = null;
    });
  }

  double get _maxHoursForEntry {
    if (_dayStatus != null && _dayStatus!.hasPunchOut) {
      return _dayStatus!.remainingHours;
    }
    return 24;
  }

  void _adjustHours(double delta) {
    final current = double.tryParse(_hoursController.text.trim()) ?? 0;
    var next = double.parse((current + delta).toStringAsFixed(2));
    if (next < 0) next = 0;
    if (next > _maxHoursForEntry) next = _maxHoursForEntry;

    _hoursController.text = _formatHoursInput(next);
    setState(() {});
  }

  String _formatHoursInput(double hours) {
    if (hours <= 0) return '';
    if (hours == hours.roundToDouble()) {
      return hours.toInt().toString();
    }
    return hours.toStringAsFixed(1);
  }

  String? _validateHours(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Required';
    }
    final hours = double.tryParse(value.trim());
    if (hours == null || hours <= 0) {
      return 'Enter a valid number';
    }
    if (hours > 24) {
      return 'Max 24 hours per entry';
    }
    if (_dayStatus != null &&
        _dayStatus!.hasPunchOut &&
        decimalHoursToMinutes(hours) > _dayStatus!.remainingMinutes) {
      return 'Exceeds remaining '
          '${formatClockHoursFromMinutes(_dayStatus!.remainingMinutes)}';
    }
    return null;
  }

  Widget _masterPickerField({
    required String label,
    required String? value,
    required List<ClockMasterItem> items,
    required ValueChanged<String?> onChanged,
    required bool enabled,
    required bool isClient,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: enabled && items.isNotEmpty
              ? () async {
                  final picked = await _pickMasterItem(
                    title: 'Select $label',
                    currentValue: value,
                    items: items,
                  );
                  if (picked != null) {
                    onChanged(picked);
                  }
                }
              : null,
          borderRadius: BorderRadius.circular(4),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
              suffixIcon: const Icon(Icons.arrow_drop_down),
            ),
            child: Text(
              value ?? (items.isEmpty ? 'None yet — request below' : 'Tap to select'),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: value == null ? Colors.grey.shade600 : null,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: enabled ? () => _requestNewMaster(isClient: isClient) : null,
            icon: const Icon(Icons.add, size: 18),
            label: Text('Request new ${label.toLowerCase()}'),
          ),
        ),
      ],
    );
  }

  Widget _hoursStepperField() {
    final canEdit = !_isWorkDateLocked &&
        _dayStatus?.hasPunchOut == true &&
        _dayStatus?.isComplete != true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Hours',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Material(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                onTap: canEdit ? () => _adjustHours(-_hourStep) : null,
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Icon(
                    Icons.remove,
                    color: canEdit ? Colors.black87 : Colors.grey,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                controller: _hoursController,
                enabled: canEdit,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  hintText: '0',
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  helperText: _dayStatus != null &&
                          _dayStatus!.hasPunchOut &&
                          !_dayStatus!.isComplete
                      ? 'Max ${formatClockHoursFromMinutes(_dayStatus!.remainingMinutes)} · +/− = 30 min · or type (9, 1.5)'
                      : '+/− adjusts by 30 min · or type directly (9, 1.5)',
                  helperMaxLines: 2,
                ),
                validator: _validateHours,
              ),
            ),
            const SizedBox(width: 8),
            Material(
              color: canEdit ? _accent : Colors.grey.shade200,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                onTap: canEdit ? () => _adjustHours(_hourStep) : null,
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Icon(
                    Icons.add,
                    color: canEdit ? Colors.black87 : Colors.grey,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (!_formKey.currentState!.validate()) return;
    if (_selectedClient == null || _selectedTask == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select client and task')),
      );
      return;
    }
    if (_workDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select work date')),
      );
      return;
    }

    setState(() => _submitting = true);
    try {
      await submitClockHour(
        employeeId: user.uid,
        employeeName: _employeeName,
        clientName: _selectedClient!,
        taskName: _selectedTask!,
        workDate: _workDate!,
        hours: double.parse(_hoursController.text.trim()),
        notes: _notesController.text,
      );

      if (!mounted) return;
      _clearForm();
      await _refreshDayStatus();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Clock hours logged'),
          backgroundColor: Colors.green,
          action: SnackBarAction(
            label: 'History',
            textColor: Colors.white,
            onPressed: () => _tabController.animateTo(1),
          ),
        ),
      );
    } on ClockHoursValidationException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _confirmDelete(ClockHourEntry entry) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || entry.workDate == null) return;

    if (await isClockHoursDayLocked(
      employeeId: user.uid,
      workDate: entry.workDate!,
    )) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${DateFormat('dd MMM yyyy').format(entry.workDate!)} is locked. '
            'Past clock hours cannot be changed after a later punch in.',
          ),
        ),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete entry?'),
        content: Text(
          '${entry.clientName} · ${entry.taskName}\n'
          '${formatClockHours(entry.hours)}\n\n'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _processingEntryId = entry.id);
    try {
      await deleteClockHourEntry(employeeId: user.uid, entry: entry);
      if (!mounted) return;
      await _refreshDayStatus();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Entry deleted')),
      );
    } on ClockHoursValidationException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _processingEntryId = null);
    }
  }

  Widget _dayStatusBanner() {
    if (_loadingDayStatus) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: LinearProgressIndicator(color: _accent),
      );
    }

    final status = _dayStatus;
    if (status == null || _workDate == null) return const SizedBox.shrink();

    if (_isWorkDateLocked) {
      return _infoBanner(
        color: Colors.grey.shade200,
        icon: Icons.lock,
        iconColor: Colors.black54,
        text:
            '${DateFormat('dd MMM yyyy').format(_workDate!)} is locked. '
            'You punched in on a later day — past clock hours cannot be changed.',
      );
    }

    if (!status.hasAttendance) {
      return _infoBanner(
        color: Colors.red.shade50,
        icon: Icons.error_outline,
        iconColor: Colors.red,
        text: 'No attendance for this date.',
      );
    }

    if (!status.hasPunchOut) {
      return _infoBanner(
        color: Colors.orange.shade50,
        icon: Icons.info_outline,
        iconColor: Colors.orange,
        text: 'Punch out first, then log clock hours for this day.',
      );
    }

    final worked = AttendanceUtils.formatMinutes(status.attendanceMinutes);
    final logged = formatClockHoursFromMinutes(status.clockedMinutes);
    final remaining = formatClockHoursFromMinutes(status.remainingMinutes);

    return _infoBanner(
      color: status.isComplete ? Colors.green.shade50 : Colors.amber.shade50,
      icon: status.isComplete ? Icons.check_circle : Icons.schedule,
      iconColor: status.isComplete ? Colors.green : Colors.orange,
      text: status.isComplete
          ? 'Day complete — worked $worked, all hours logged.'
          : 'Worked $worked · Logged $logged · Remaining $remaining',
    );
  }

  Widget _infoBanner({
    required Color color,
    required IconData icon,
    required Color iconColor,
    required String text,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: iconColor.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Map<DateTime, List<ClockHourEntry>> _groupEntriesByDate(
    List<ClockHourEntry> entries,
  ) {
    final grouped = <DateTime, List<ClockHourEntry>>{};
    for (final entry in entries) {
      if (entry.workDate == null) continue;
      final day = normalizeWorkDate(entry.workDate!);
      grouped.putIfAbsent(day, () => []).add(entry);
    }
    return grouped;
  }

  Widget _buildLogTab({
    required List<ClockMasterItem> clients,
    required List<ClockMasterItem> tasks,
    required bool mastersLoading,
  }) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            color: Colors.blue.shade50,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                isClockHoursLiveYet
                    ? 'After punch out, log client and task hours here. '
                        'Missing a client or task? Use Request new — admin will approve. '
                        'Once you punch in on a later day, past days are locked.'
                    : 'Clock hours tracking starts from ${clockHoursGoLiveLabel()}. '
                        'Until then, punch in/out as usual — no client/task logging needed.',
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Log hours',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (mastersLoading)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else ...[
                      if (clients.isEmpty || tasks.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            clients.isEmpty && tasks.isEmpty
                                ? 'No clients or tasks yet. Request new ones below.'
                                : clients.isEmpty
                                    ? 'No clients yet. Request one below.'
                                    : 'No tasks yet. Request one below.',
                            style: TextStyle(color: Colors.grey.shade700),
                          ),
                        ),
                      OutlinedButton.icon(
                        onPressed: _submitting ? null : _pickWorkDate,
                        icon: const Icon(Icons.calendar_today),
                        label: Text(
                          _workDate == null
                              ? 'Select date'
                              : DateFormat('dd MMM yyyy').format(_workDate!),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _dayStatusBanner(),
                      _masterPickerField(
                        label: 'Client',
                        value: _selectedClient,
                        items: clients,
                        enabled: !_isWorkDateLocked,
                        isClient: true,
                        onChanged: (value) =>
                            setState(() => _selectedClient = value),
                      ),
                      const SizedBox(height: 16),
                      _masterPickerField(
                        label: 'Task',
                        value: _selectedTask,
                        items: tasks,
                        enabled: !_isWorkDateLocked,
                        isClient: false,
                        onChanged: (value) =>
                            setState(() => _selectedTask = value),
                      ),
                      const SizedBox(height: 16),
                      _hoursStepperField(),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _notesController,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'Notes (optional)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: (_submitting ||
                                _isWorkDateLocked ||
                                _dayStatus?.hasPunchOut != true ||
                                _dayStatus?.isComplete == true)
                            ? null
                            : _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: _submitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.add),
                        label: Text(
                          _submitting
                              ? 'Saving...'
                              : _dayStatus?.isComplete == true
                                  ? 'Day fully logged'
                                  : 'Log hours',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryTab(List<ClockHourEntry> entries) {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) {
      return const Center(child: Text('Please log in again'));
    }

    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'No clock hours logged yet.\nUse the Log Hours tab after punch out.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 15),
          ),
        ),
      );
    }

    final grouped = _groupEntriesByDate(entries);
    final sortedDays = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    final grandTotal = entries.fold<double>(0, (total, e) => total + e.hours);

    return FutureBuilder<Set<DateTime>>(
      future: lockedClockWorkDates(
        employeeId: userId,
        dates: sortedDays,
      ),
      builder: (context, lockedSnapshot) {
        final lockedDays = lockedSnapshot.data ?? {};

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: Colors.amberAccent.shade100,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${entries.length} entr${entries.length == 1 ? 'y' : 'ies'} · '
                      '${sortedDays.length} day${sortedDays.length == 1 ? '' : 's'}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'Total: ${formatClockHours(grandTotal)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Locked days (after a later punch in) cannot be edited or deleted.',
              style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
            ),
            const SizedBox(height: 12),
            ...sortedDays.map((day) {
              final dayEntries = grouped[day]!;
              final dayTotal =
                  dayEntries.fold<double>(0, (total, e) => total + e.hours);
              final dateLabel = DateFormat('dd MMM yyyy (EEE)').format(day);
              final isLocked = lockedDays.any((d) => isSameWorkDate(d, day));

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ExpansionTile(
                  initiallyExpanded:
                      isSameWorkDate(day, _workDate ?? DateTime(1970)),
                  leading: isLocked
                      ? const Icon(Icons.lock, size: 20, color: Colors.black54)
                      : null,
                  title: Text(
                    dateLabel,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    '${dayEntries.length} entr${dayEntries.length == 1 ? 'y' : 'ies'} · '
                    '${formatClockHours(dayTotal)} logged'
                    '${isLocked ? ' · Locked' : ''}',
                  ),
                  children: dayEntries.map((entry) {
                    final deleting = _processingEntryId == entry.id;
                    return ListTile(
                      title: Text(
                        '${entry.clientName} · ${entry.taskName}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: entry.notes.isNotEmpty ? Text(entry.notes) : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            formatClockHours(entry.hours),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          if (deleting)
                            const Padding(
                              padding: EdgeInsets.only(left: 8),
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          else if (!isLocked)
                            IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                color: Colors.red,
                                size: 20,
                              ),
                              tooltip: 'Delete',
                              onPressed: () => _confirmDelete(entry),
                            ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              );
            }),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final userId = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Clock Hours'),
        backgroundColor: _accent,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.black,
          labelColor: Colors.black,
          tabs: const [
            Tab(icon: Icon(Icons.add_circle_outline), text: 'Log Hours'),
            Tab(icon: Icon(Icons.history), text: 'History'),
          ],
        ),
      ),
      body: userId == null
          ? const Center(child: Text('Please log in again'))
          : StreamBuilder<List<ClockMasterItem>>(
              stream: watchSelectableClockClients(userId),
              builder: (context, clientsSnapshot) {
                if (clientsSnapshot.hasError) {
                  return Center(
                    child: Text('Could not load clients: ${clientsSnapshot.error}'),
                  );
                }
                return StreamBuilder<List<ClockMasterItem>>(
                  stream: watchSelectableClockTasks(userId),
                  builder: (context, tasksSnapshot) {
                    final clients = clientsSnapshot.data ?? [];
                    final tasks = tasksSnapshot.data ?? [];
                    final mastersLoading =
                        (clientsSnapshot.connectionState ==
                                ConnectionState.waiting &&
                            !clientsSnapshot.hasData) ||
                        (tasksSnapshot.connectionState ==
                                ConnectionState.waiting &&
                            !tasksSnapshot.hasData);

                    return StreamBuilder<List<ClockHourEntry>>(
                      stream: watchMyClockHours(userId),
                      builder: (context, hoursSnapshot) {
                        final entries = hoursSnapshot.data ?? [];

                        return TabBarView(
                          controller: _tabController,
                          children: [
                            _buildLogTab(
                              clients: clients,
                              tasks: tasks,
                              mastersLoading: mastersLoading,
                            ),
                            _buildHistoryTab(entries),
                          ],
                        );
                      },
                    );
                  },
                );
              },
            ),
    );
  }
}
