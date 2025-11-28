// ignore_for_file: avoid_web_libraries_in_flutter

// THIS FILE IS ONLY IMPORTED ON WEB.
// SAFE because conditional import prevents mobile build from seeing it.

import 'dart:typed_data';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui;

import 'package:flutter/material.dart';

class CameraScreen extends StatefulWidget {
  final Function(Uint8List) onCapture;

  const CameraScreen({required this.onCapture, super.key});

  @override
  _CameraScreenState createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  html.VideoElement? video;
  bool ready = false;
  late final String viewId;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    viewId = "webcam_${DateTime.now().millisecondsSinceEpoch}";

    video = html.VideoElement()
      ..autoplay = true
      ..muted = true
      ..style.width = '100%';

    // Register view
    ui.platformViewRegistry.registerViewFactory(
      viewId,
          (int _) => video!,
    );

    final stream = await html.window.navigator.mediaDevices!
        .getUserMedia({'video': true});

    video!.srcObject = stream;

    setState(() => ready = true);
  }

  void _capture() {
    if (!mounted) return;
    final canvas = html.CanvasElement(
      width: video!.videoWidth,
      height: video!.videoHeight,
    );

    canvas.context2D.drawImage(video!, 0, 0);

    final dataUrl = canvas.toDataUrl("image/jpeg");
    final bytes = base64.decode(dataUrl.split(',').last);

    widget.onCapture(bytes);
    /*if (!mounted) return;*/
    //Navigator.pop(context, bytes);
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text("Take Selfie")),
      body: Center(
        child: Column(
          children: [
            SizedBox(
              width: 350,
              height: 450,
              child: HtmlElementView(viewType: viewId),
            ),
            FloatingActionButton(
              onPressed: _capture,
              child: const Icon(Icons.camera_alt),
            ),
           /* ElevatedButton(
              onPressed: _capture,
              child: const Text("Capture"),
            ),*/
          ],
        ),
      ),
    );
  }
}
