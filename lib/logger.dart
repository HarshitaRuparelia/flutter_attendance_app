import 'package:cloud_firestore/cloud_firestore.dart';

class AppLogger {
  static final _logsCollection = FirebaseFirestore.instance.collection('logs');

  /// Logs an event to Firestore
  /// event: Short string describing action
  /// uid: optional user ID
  /// data: optional extra data
  static Future<void> log({
    required String event,
    String? uid,
    Map<String, dynamic>? data,
  }) async {
    try {
      await _logsCollection.add({
        'event': event,
        'uid': uid,
        'data': data ?? {},
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print("Failed to log event: $e");
    }
  }
}
