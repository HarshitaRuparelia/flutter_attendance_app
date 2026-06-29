import 'dart:convert';
import 'dart:typed_data';

import 'package:attendance_app_new/services/excel_save_helper.dart';
import 'package:attendance_app_new/services/file_bytes_helper.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

class OpeClaimScreen extends StatefulWidget {
  const OpeClaimScreen({super.key});

  @override
  State<OpeClaimScreen> createState() => _OpeClaimScreenState();
}

class _OpeClaimScreenState extends State<OpeClaimScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _clientController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _descController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();

  DateTime? _selectedDate;
  Uint8List? _proofBytes;
  String? _proofFileName;
  String? _processingClaimId;
  bool _loading = false;
  bool _excelLoading = false;
  bool _showAll = false;
  int _selectedYear = DateTime.now().year;
  DateTimeRange? _selectedRange;

  static const _accent = Colors.orangeAccent;
  final NumberFormat _currency =
      NumberFormat.currency(symbol: '₹', decimalDigits: 2);

  @override
  void dispose() {
    _clientController.dispose();
    _amountController.dispose();
    _descController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<String> _getUserName() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return 'User';

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();

    if (doc.exists && doc.data() != null) {
      return doc.data()!['name']?.toString() ?? user.email ?? 'User';
    }
    return user.email ?? 'User';
  }

  Future<void> _pickDate({VoidCallback? onChanged}) async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );

    if (date != null) {
      setState(() => _selectedDate = date);
      onChanged?.call();
    }
  }

  Future<void> _pickFromCamera({VoidCallback? onChanged}) async {
    final image = await _picker.pickImage(
      source: kIsWeb ? ImageSource.gallery : ImageSource.camera,
    );
    if (image != null) {
      final bytes = await image.readAsBytes();
      setState(() {
        _proofBytes = bytes;
        _proofFileName = image.name;
      });
      onChanged?.call();
    }
  }

  Future<void> _pickFile({VoidCallback? onChanged}) async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    final file = result?.files.single;
    if (file == null) return;

    final bytes = await readPickedFileBytes(file);
    if (bytes == null) return;

    setState(() {
      _proofBytes = Uint8List.fromList(bytes);
      _proofFileName = file.name;
    });
    onChanged?.call();
  }

  Future<String?> _uploadProof() async {
    if (_proofBytes == null) return null;

    final ext = _proofFileName != null && _proofFileName!.contains('.')
        ? _proofFileName!.substring(_proofFileName!.lastIndexOf('.'))
        : '.jpg';
    final storageName =
        '${DateTime.now().millisecondsSinceEpoch}${ext.toLowerCase()}';
    final ref = FirebaseStorage.instance.ref().child('ope_proofs/$storageName');
    await ref.putData(
      _proofBytes!,
      SettableMetadata(
        contentType: _mimeTypeForProof(_proofFileName),
      ),
    );
    return ref.getDownloadURL();
  }

  String _mimeTypeForProof(String? name) {
    final lower = name?.toLowerCase() ?? '';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    return 'image/jpeg';
  }

  void _clearForm() {
    _clientController.clear();
    _amountController.clear();
    _descController.clear();
    setState(() {
      _selectedDate = null;
      _proofBytes = null;
      _proofFileName = null;
    });
  }

  bool _isPending(String status) => status.toLowerCase() == 'pending';

  String _formatStatus(String status) {
    final normalized = status.trim().toLowerCase();
    switch (normalized) {
      case 'approved':
        return 'Approved';
      case 'rejected':
        return 'Rejected';
      case 'pending':
        return 'Pending';
      default:
        if (status.trim().isEmpty) return 'Pending';
        return status.trim()[0].toUpperCase() +
            status.trim().substring(1).toLowerCase();
    }
  }

  void _setLoading(bool value, {void Function(VoidCallback)? onDialogRebuild}) {
    setState(() => _loading = value);
    onDialogRebuild?.call(() {});
  }

  Future<void> _submitClaim({
    bool closeDialog = false,
    void Function(VoidCallback)? onDialogRebuild,
  }) async {
    if (_loading) return;

    if (!_formKey.currentState!.validate() || _selectedDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all required fields')),
      );
      return;
    }

    _setLoading(true, onDialogRebuild: onDialogRebuild);

    try {
      final user = FirebaseAuth.instance.currentUser;
      final employeeName = await _getUserName();
      final newProofUrl = await _uploadProof();
      final proofUrl = newProofUrl ?? '';

      await FirebaseFirestore.instance.collection('ope_claims').add({
        'employeeId': user?.uid,
        'employeeName': employeeName,
        'clientName': _clientController.text.trim(),
        'amount': double.parse(_amountController.text.trim()),
        'description': _descController.text.trim(),
        'date': DateFormat('yyyy-MM-dd').format(_selectedDate!),
        'proofUrl': proofUrl,
        'status': 'pending',
        'adminRemark': '',
        'source': 'manual',
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;

      if (closeDialog) Navigator.pop(context);
      _clearForm();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Claim submitted successfully')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      if (mounted) {
        _setLoading(false, onDialogRebuild: onDialogRebuild);
      }
    }
  }

  String _cellText(CellValue? value) {
    if (value == null) return '';

    return switch (value) {
      TextCellValue() => value.value.text?.trim() ?? '',
      IntCellValue() => value.value.toString(),
      DoubleCellValue() => value.value.toString(),
      DateCellValue() =>
        DateFormat('yyyy-MM-dd').format(value.asDateTimeLocal()),
      BoolCellValue() => value.value.toString(),
      FormulaCellValue() => value.formula.trim(),
      _ => value.toString().trim(),
    };
  }

  DateTime? _parseClaimDate(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    final parsed = DateTime.tryParse(trimmed);
    if (parsed != null) return parsed;

    final formats = [
      DateFormat('dd/MM/yyyy'),
      DateFormat('dd-MM-yyyy'),
      DateFormat('MM/dd/yyyy'),
    ];

    for (final format in formats) {
      try {
        return format.parse(trimmed);
      } catch (_) {}
    }
    return null;
  }

  Excel _createNamedSheet(String sheetName) {
    final excel = Excel.createExcel();
    final defaultName = excel.sheets.keys.first;
    excel.rename(defaultName, sheetName);
    excel.setDefaultSheet(sheetName);
    return excel;
  }

  void _writeSheetRow(Sheet sheet, int rowIndex, List<CellValue?> values) {
    for (var col = 0; col < values.length; col++) {
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: rowIndex))
          .value = values[col];
    }
  }

  List<int> _buildTemplateBytes() {
    const sheetName = 'OPE Claims Template';
    final excel = _createNamedSheet(sheetName);
    final sheet = excel[sheetName];

    _writeSheetRow(sheet, 0, [
      TextCellValue('Client Name'),
      TextCellValue('Date (YYYY-MM-DD)'),
      TextCellValue('Amount'),
      TextCellValue('Description'),
    ]);

    final bytes = excel.encode();
    if (bytes == null) {
      throw Exception('Could not create Excel template');
    }
    return bytes;
  }

  void _showSavedSnackBar(String displayPath) {
    final message = kIsWeb
        ? 'Downloaded $displayPath (check your browser downloads folder)'
        : 'Saved to $displayPath';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  Future<void> _downloadTemplate() async {
    setState(() => _excelLoading = true);
    try {
      final saved = await saveExcelFile(
        _buildTemplateBytes(),
        'ope_claims_template.xlsx',
      );
      if (!mounted) return;
      _showSavedSnackBar(saved.displayPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Template download failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _excelLoading = false);
    }
  }

  ({List<Map<String, dynamic>> claims, int skipped}) _parseExcelClaims(
    List<int> bytes,
  ) {
    final excel = Excel.decodeBytes(bytes);
    final claims = <Map<String, dynamic>>[];
    var skipped = 0;

    for (final sheetName in excel.tables.keys) {
      final sheet = excel.tables[sheetName];
      if (sheet == null) continue;

      for (var i = 0; i < sheet.rows.length; i++) {
        if (i == 0) continue;

        final row = sheet.rows[i];
        if (row.isEmpty ||
            row.every((cell) => _cellText(cell?.value).isEmpty)) {
          continue;
        }

        final clientName = _cellText(row.elementAtOrNull(0)?.value);
        final dateRaw = _cellText(row.elementAtOrNull(1)?.value);
        final amountRaw = _cellText(row.elementAtOrNull(2)?.value);
        final description = _cellText(row.elementAtOrNull(3)?.value);

        final claimDate = _parseClaimDate(dateRaw);
        final amount = double.tryParse(amountRaw.replaceAll(',', ''));

        if (clientName.isEmpty ||
            claimDate == null ||
            amount == null ||
            amount <= 0 ||
            description.isEmpty) {
          skipped++;
          continue;
        }

        claims.add({
          'clientName': clientName,
          'amount': amount,
          'description': description,
          'date': DateFormat('yyyy-MM-dd').format(claimDate),
        });
      }
    }

    return (claims: claims, skipped: skipped);
  }

  String _excelFileHash(List<int> bytes) {
    return sha256.convert(bytes).toString();
  }

  String _claimRowHash(String employeeId, Map<String, dynamic> claim) {
    final client =
        (claim['clientName'] ?? '').toString().trim().toLowerCase();
    final date = (claim['date'] ?? '').toString().trim();
    final amount = (claim['amount'] as num?)?.toDouble() ?? 0;
    final amountKey = amount == amount.truncateToDouble()
        ? amount.toInt().toString()
        : amount.toStringAsFixed(2);
    final description =
        (claim['description'] ?? '').toString().trim().toLowerCase();
    final key = '$employeeId|$client|$date|$amountKey|$description';
    return sha256.convert(utf8.encode(key)).toString();
  }

  Future<Set<String>> _existingClaimRowHashes(String employeeId) async {
    final hashes = <String>{};

    // Only active claims count — deleted rows can be uploaded again.
    final claimsSnap = await FirebaseFirestore.instance
        .collection('ope_claims')
        .where('employeeId', isEqualTo: employeeId)
        .get();
    for (final doc in claimsSnap.docs) {
      final data = doc.data();
      if ((data['source'] ?? '').toString().toLowerCase() != 'excel') {
        continue;
      }
      final stored = data['rowHash']?.toString();
      hashes.add(
        stored != null ? stored : _claimRowHash(employeeId, data),
      );
    }

    return hashes;
  }

  Future<({List<Map<String, dynamic>> newClaims, int alreadyUploaded})>
      _splitNewClaims(
    String employeeId,
    List<Map<String, dynamic>> claims,
  ) async {
    final existing = await _existingClaimRowHashes(employeeId);
    final newClaims = <Map<String, dynamic>>[];
    var alreadyUploaded = 0;

    for (final claim in claims) {
      final hash = _claimRowHash(employeeId, claim);
      if (existing.contains(hash)) {
        alreadyUploaded++;
      } else {
        newClaims.add({...claim, 'rowHash': hash});
      }
    }

    return (newClaims: newClaims, alreadyUploaded: alreadyUploaded);
  }

  Future<void> _recordExcelRowHashes({
    required String employeeId,
    required List<Map<String, dynamic>> claims,
    required String batchId,
  }) async {
    const chunkSize = 400;
    for (var start = 0; start < claims.length; start += chunkSize) {
      final end = (start + chunkSize > claims.length)
          ? claims.length
          : start + chunkSize;
      final chunk = claims.sublist(start, end);
      final batch = FirebaseFirestore.instance.batch();

      for (final claim in chunk) {
        final rowHash = claim['rowHash']?.toString();
        if (rowHash == null) continue;

        final docRef = FirebaseFirestore.instance
            .collection('ope_excel_row_hashes')
            .doc('${employeeId}_$rowHash');
        batch.set(docRef, {
          'employeeId': employeeId,
          'rowHash': rowHash,
          'batchId': batchId,
          'recordedAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();
    }
  }

  Future<void> _recordExcelUpload({
    required String employeeId,
    required String fileHash,
    required String batchId,
    required int claimCount,
  }) async {
    await FirebaseFirestore.instance.collection('ope_excel_uploads').add({
      'employeeId': employeeId,
      'fileHash': fileHash,
      'batchId': batchId,
      'claimCount': claimCount,
      'uploadedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<bool> _confirmBulkUpload(
    int claimCount,
    int skipped, {
    int alreadyUploaded = 0,
  }) async {
    final skippedNote = skipped > 0
        ? '\n\n$skipped row(s) with missing or invalid data will be skipped.'
        : '';
    final alreadyNote = alreadyUploaded > 0
        ? '\n\n$alreadyUploaded row(s) already submitted earlier will be skipped.'
        : '';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Submit Excel claims?'),
        content: Text(
          'This will create $claimCount new claim(s) — one row in Excel = one claim.$alreadyNote$skippedNote\n\n'
          'Proof/receipt is not attached for Excel uploads. Use + for single claims with photo proof.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: _accent),
            child: const Text('Submit all'),
          ),
        ],
      ),
    );

    return confirmed ?? false;
  }

  Future<void> _commitClaimsInBatches(
    List<Map<String, dynamic>> claims, {
    required String employeeId,
    required String employeeName,
    required String batchId,
  }) async {
    const batchLimit = 500;

    for (var start = 0; start < claims.length; start += batchLimit) {
      final end = (start + batchLimit > claims.length)
          ? claims.length
          : start + batchLimit;
      final chunk = claims.sublist(start, end);
      final batch = FirebaseFirestore.instance.batch();

      for (final claim in chunk) {
        final docRef = FirebaseFirestore.instance.collection('ope_claims').doc();
        batch.set(docRef, {
          'employeeId': employeeId,
          'employeeName': employeeName,
          'clientName': claim['clientName'],
          'amount': claim['amount'],
          'description': claim['description'],
          'date': claim['date'],
          'proofUrl': '',
          'status': 'pending',
          'adminRemark': '',
          'source': 'excel',
          'batchId': batchId,
          'rowHash': claim['rowHash'],
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();
    }
  }

  Future<void> _uploadExcel() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      withData: true,
    );

    if (result == null || result.files.isEmpty) return;

    setState(() => _excelLoading = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in');

      final picked = result.files.single;
      final bytesList = await readPickedFileBytes(picked);
      if (bytesList == null) {
        throw Exception('Could not read the selected Excel file');
      }
      final bytes = Uint8List.fromList(bytesList);
      final fileHash = _excelFileHash(bytes);
      final parsed = _parseExcelClaims(bytes);

      if (parsed.claims.isEmpty) {
        throw Exception(
          'No valid rows found. Keep the header row and fill: Client Name, Date, Amount, Description.',
        );
      }

      if (!mounted) return;
      setState(() => _excelLoading = false);

      final split = await _splitNewClaims(user.uid, parsed.claims);
      final newClaims = split.newClaims;
      final alreadyUploaded = split.alreadyUploaded;

      if (newClaims.isEmpty) {
        throw Exception(
          alreadyUploaded > 0
              ? 'All ${parsed.claims.length} row(s) in this file were already submitted. Add only new rows and upload again.'
              : 'No new claims to submit.',
        );
      }

      final confirmed = await _confirmBulkUpload(
        newClaims.length,
        parsed.skipped,
        alreadyUploaded: alreadyUploaded,
      );
      if (!confirmed || !mounted) return;

      setState(() => _excelLoading = true);

      final employeeName = await _getUserName();
      final batchId = DateTime.now().millisecondsSinceEpoch.toString();

      await _commitClaimsInBatches(
        newClaims,
        employeeId: user.uid,
        employeeName: employeeName,
        batchId: batchId,
      );

      await _recordExcelRowHashes(
        employeeId: user.uid,
        claims: newClaims,
        batchId: batchId,
      );

      await _recordExcelUpload(
        employeeId: user.uid,
        fileHash: fileHash,
        batchId: batchId,
        claimCount: newClaims.length,
      );

      if (!mounted) return;
      final alreadyNote = alreadyUploaded > 0
          ? ', skipped $alreadyUploaded already submitted row(s)'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Submitted ${newClaims.length} new claim(s) from Excel'
            '$alreadyNote'
            '${parsed.skipped > 0 ? ', skipped ${parsed.skipped} invalid row(s)' : ''}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Excel upload failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _excelLoading = false);
    }
  }

  bool _matchesFilter(Map<String, dynamic> data) {
    final dateStr = data['date']?.toString();
    if (dateStr == null || dateStr.isEmpty) return false;

    final claimDate = DateTime.tryParse(dateStr);
    if (claimDate == null) return false;

    if (_showAll) {
      return claimDate.year == _selectedYear;
    }

    if (_selectedRange != null) {
      final start = DateTime(
        _selectedRange!.start.year,
        _selectedRange!.start.month,
        _selectedRange!.start.day,
      );
      final end = DateTime(
        _selectedRange!.end.year,
        _selectedRange!.end.month,
        _selectedRange!.end.day,
      );
      final normalized = DateTime(
        claimDate.year,
        claimDate.month,
        claimDate.day,
      );
      return !normalized.isBefore(start) && !normalized.isAfter(end);
    }

    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month, 1);
    final monthEnd = DateTime(now.year, now.month + 1, 0);
    final normalized = DateTime(claimDate.year, claimDate.month, claimDate.day);
    return !normalized.isBefore(monthStart) && !normalized.isAfter(monthEnd);
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'approved':
        return Colors.green;
      case 'rejected':
        return Colors.red;
      default:
        return Colors.orange;
    }
  }

  void _showFullImage(String url) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        child: InteractiveViewer(
          child: Image.network(
            url,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Center(
              child: Icon(Icons.image_not_supported, size: 48),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openProof(String url) async {
    if (url.isEmpty) return;

    final lower = url.toLowerCase();
    if (lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp')) {
      _showFullImage(url);
      return;
    }

    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _releaseExcelRowHash(
    String employeeId,
    Map<String, dynamic> data,
  ) async {
    if ((data['source'] ?? '').toString().toLowerCase() != 'excel') return;

    final rowHash =
        data['rowHash']?.toString() ?? _claimRowHash(employeeId, data);

    try {
      await FirebaseFirestore.instance
          .collection('ope_excel_row_hashes')
          .doc('${employeeId}_$rowHash')
          .delete();
    } catch (_) {}
  }

  Future<void> _deleteClaim(
    String docId,
    Map<String, dynamic> data,
  ) async {
    final status = (data['status'] ?? 'pending').toString();
    if (!_isPending(status)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only pending claims can be deleted'),
        ),
      );
      return;
    }

    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (data['employeeId'] != userId) return;

    final client = data['clientName']?.toString() ?? 'this claim';
    final amount = (data['amount'] as num?)?.toDouble() ?? 0;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete claim?'),
        content: Text(
          'Delete claim for $client (${_currency.format(amount)})?\n\nThis cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _processingClaimId = docId);

    try {
      await FirebaseFirestore.instance
          .collection('ope_claims')
          .doc(docId)
          .delete();

      if (userId != null) {
        await _releaseExcelRowHash(userId, data);
      }

      final proofUrl = data['proofUrl']?.toString() ?? '';
      if (proofUrl.isNotEmpty) {
        try {
          await FirebaseStorage.instance.refFromURL(proofUrl).delete();
        } catch (_) {}
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Claim deleted')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _processingClaimId = null);
    }
  }

  void _showAddClaimDialog() {
    _clearForm();
    _showClaimFormDialog();
  }

  void _showClaimFormDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return PopScope(
              canPop: !_loading,
              child: AlertDialog(
                title: const Text('Submit OPE Claim'),
                content: SingleChildScrollView(
                  child: AbsorbPointer(
                    absorbing: _loading,
                    child: Form(
                      key: _formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_loading) ...[
                            const LinearProgressIndicator(color: _accent),
                            const SizedBox(height: 12),
                            const Text(
                              'Uploading proof and submitting claim...',
                              style: TextStyle(
                                color: Colors.black54,
                                fontSize: 13,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                          ],
                          TextFormField(
                            controller: _clientController,
                            decoration: const InputDecoration(
                              labelText: 'Client Name',
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) =>
                                v == null || v.trim().isEmpty ? 'Required' : null,
                          ),
                          const SizedBox(height: 10),
                          ElevatedButton.icon(
                            onPressed: _loading
                                ? null
                                : () async {
                                    await _pickDate(
                                      onChanged: () => setDialogState(() {}),
                                    );
                                  },
                            icon: const Icon(Icons.calendar_today),
                            label: Text(
                              _selectedDate == null
                                  ? 'Select Date'
                                  : DateFormat('dd MMM yyyy')
                                      .format(_selectedDate!),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _accent,
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: _amountController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Amount',
                              border: OutlineInputBorder(),
                              prefixText: '₹ ',
                            ),
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) return 'Required';
                              if (double.tryParse(v.trim()) == null) {
                                return 'Enter a valid amount';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: _descController,
                            maxLines: 3,
                            decoration: const InputDecoration(
                              labelText: 'Description',
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) =>
                                v == null || v.trim().isEmpty ? 'Required' : null,
                          ),
                          const SizedBox(height: 10),
                          if (kIsWeb)
                            OutlinedButton.icon(
                              onPressed: _loading
                                  ? null
                                  : () async {
                                      await _pickFile(
                                        onChanged: () => setDialogState(() {}),
                                      );
                                    },
                              icon: const Icon(Icons.upload_file),
                              label: const Text('Choose proof file'),
                            )
                          else
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _loading
                                        ? null
                                        : () async {
                                            await _pickFromCamera(
                                              onChanged: () =>
                                                  setDialogState(() {}),
                                            );
                                          },
                                    icon: const Icon(Icons.camera_alt),
                                    label: const Text('Camera'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _loading
                                        ? null
                                        : () async {
                                            await _pickFile(
                                              onChanged: () =>
                                                  setDialogState(() {}),
                                            );
                                          },
                                    icon: const Icon(Icons.attach_file),
                                    label: const Text('Proof'),
                                  ),
                                ),
                              ],
                            ),
                          if (_proofFileName != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                'Selected: $_proofFileName',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () {
                            _clearForm();
                            Navigator.pop(context);
                          },
                    child: const Text('Cancel'),
                  ),
                  ElevatedButton(
                    onPressed: _loading
                        ? null
                        : () => _submitClaim(
                              closeDialog: true,
                              onDialogRebuild: setDialogState,
                            ),
                    style: ElevatedButton.styleFrom(backgroundColor: _accent),
                    child: _loading
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Text('Submitting...'),
                            ],
                          )
                        : const Text('Submit'),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).whenComplete(_clearForm);
  }

  @override
  Widget build(BuildContext context) {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    final now = DateTime.now();
    final defaultMonthStart = DateTime(now.year, now.month, 1);
    final defaultMonthEnd = DateTime(now.year, now.month + 1, 0);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My OPE Claims'),
        backgroundColor: _accent,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Submit Claim',
            onPressed: _showAddClaimDialog,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _excelLoading ? null : _downloadTemplate,
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Download template'),
                ),
                OutlinedButton.icon(
                  onPressed: _excelLoading ? null : _uploadExcel,
                  icon: const Icon(Icons.upload_file, size: 18),
                  label: const Text('Upload Excel'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: const Text(
                'Bulk upload: download the template, add one claim per row, then tap Upload Excel. '
                'If you add more rows to the same file later, only new rows are submitted — already uploaded rows are skipped automatically. '
                'For a single claim, use + instead.',
                style: TextStyle(fontSize: 12.5, color: Colors.black87),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Switch(
                      value: _showAll,
                      activeColor: _accent,
                      onChanged: (val) => setState(() => _showAll = val),
                    ),
                    const Text('Show All'),
                  ],
                ),
                if (!_showAll)
                  ElevatedButton.icon(
                    onPressed: () async {
                      final picked = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(now.year - 1),
                        lastDate: DateTime(now.year + 1),
                        initialDateRange: _selectedRange ??
                            DateTimeRange(
                              start: defaultMonthStart,
                              end: defaultMonthEnd,
                            ),
                      );
                      if (picked != null) {
                        setState(() => _selectedRange = picked);
                      }
                    },
                    icon: const Icon(Icons.filter_alt_outlined),
                    label: const Text('Filter'),
                    style: ElevatedButton.styleFrom(backgroundColor: _accent),
                  )
                else
                  DropdownButton<int>(
                    value: _selectedYear,
                    items: List.generate(
                      5,
                      (i) => DropdownMenuItem(
                        value: now.year - i,
                        child: Text('${now.year - i}'),
                      ),
                    ),
                    onChanged: (val) =>
                        setState(() => _selectedYear = val ?? now.year),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _showAll
                    ? 'Showing Year: $_selectedYear'
                    : _selectedRange != null
                        ? 'Showing ${DateFormat('dd MMM').format(_selectedRange!.start)} - ${DateFormat('dd MMM yyyy').format(_selectedRange!.end)}'
                        : 'Showing ${DateFormat('dd MMM').format(defaultMonthStart)} - ${DateFormat('dd MMM yyyy').format(defaultMonthEnd)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Colors.black54,
                ),
              ),
            ),
            const Divider(),
            if (_excelLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(color: _accent),
              ),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('ope_claims')
                    .where('employeeId', isEqualTo: userId)
                    .orderBy('date', descending: true)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  if (snapshot.hasError) {
                    return Center(
                      child: Text('Error loading claims: ${snapshot.error}'),
                    );
                  }

                  if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                    return const Center(child: Text('No OPE claims yet.'));
                  }

                  final filtered = snapshot.data!.docs.where((doc) {
                    return _matchesFilter(doc.data() as Map<String, dynamic>);
                  }).toList();

                  if (filtered.isEmpty) {
                    return const Center(
                      child: Text('No claims found for selected period.'),
                    );
                  }

                  final totalAmount = filtered.fold<double>(0, (total, doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    return total + ((data['amount'] as num?)?.toDouble() ?? 0);
                  });

                  return Column(
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.receipt_long,
                            color: Colors.orange,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${filtered.length} Claim(s) • ${_currency.format(totalAmount)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.orange,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: Scrollbar(
                          controller: _scrollController,
                          thumbVisibility: true,
                          child: ListView.builder(
                            controller: _scrollController,
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final doc = filtered[index];
                              final data = doc.data() as Map<String, dynamic>;
                              final docId = doc.id;
                              final date = data['date']?.toString() ?? '-';
                              final client =
                                  data['clientName']?.toString() ?? '-';
                              final amount =
                                  (data['amount'] as num?)?.toDouble() ?? 0;
                              final description =
                                  data['description']?.toString() ??
                                      'No description';
                              final status =
                                  (data['status'] ?? 'pending').toString();
                              final adminRemark =
                                  data['adminRemark']?.toString() ?? '';
                              final proofUrl =
                                  data['proofUrl']?.toString() ?? '';
                              final source =
                                  data['source']?.toString() ?? 'manual';
                              final canModify = _isPending(status);
                              final isProcessing = _processingClaimId == docId;

                              return Card(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                elevation: 2,
                                margin: const EdgeInsets.symmetric(vertical: 6),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Expanded(
                                            child: Text(
                                              client,
                                              style: const TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                          Chip(
                                            label: Text(
                                              _formatStatus(status),
                                              style: const TextStyle(
                                                color: Colors.white,
                                              ),
                                            ),
                                            backgroundColor:
                                                _statusColor(status),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        DateFormat('dd MMM yyyy').format(
                                          DateTime.tryParse(date) ??
                                              DateTime.now(),
                                        ),
                                        style: const TextStyle(
                                          color: Colors.black54,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _currency.format(amount),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 15,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        description,
                                        style: const TextStyle(
                                          color: Colors.black87,
                                        ),
                                      ),
                                      if (adminRemark.isNotEmpty) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          'Admin: $adminRemark',
                                          style: const TextStyle(
                                            color: Colors.blueGrey,
                                            fontStyle: FontStyle.italic,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          Chip(
                                            label: Text(
                                              source == 'excel'
                                                  ? 'Excel upload'
                                                  : 'Manual',
                                              style: const TextStyle(
                                                fontSize: 11,
                                              ),
                                            ),
                                            visualDensity: VisualDensity.compact,
                                          ),
                                          if (proofUrl.isNotEmpty)
                                            TextButton.icon(
                                              onPressed: isProcessing
                                                  ? null
                                                  : () => _openProof(proofUrl),
                                              icon: const Icon(
                                                Icons.attachment,
                                                size: 16,
                                              ),
                                              label: const Text('View Proof'),
                                            ),
                                          const Spacer(),
                                          if (isProcessing)
                                            const SizedBox(
                                              width: 20,
                                              height: 20,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          else if (canModify)
                                            IconButton(
                                              icon: const Icon(
                                                Icons.delete_outline,
                                                size: 20,
                                                color: Colors.red,
                                              ),
                                              tooltip: 'Delete',
                                              onPressed: () => _deleteClaim(
                                                docId,
                                                data,
                                              ),
                                            ),
                                        ],
                                      ),
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

extension _ListSafeAccess<T> on List<T> {
  T? elementAtOrNull(int index) {
    if (index < 0 || index >= length) return null;
    return this[index];
  }
}
