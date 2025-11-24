import 'dart:typed_data';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class CameraScreen extends StatefulWidget {
  final Function(File) onCapture;

  const CameraScreen({required this.onCapture, super.key});

  @override
  _CameraScreenState createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  late Future<void> _initController;

  @override
  void initState() {
    super.initState();
    _initController = _initMobileCamera();
  }

  Future<void> _initMobileCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw Exception("No camera found");
    }
    final frontCamera = cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    _controller = CameraController(frontCamera, ResolutionPreset.medium);
    await _controller!.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _capturePhoto() async {
    if (!mounted) return;

    try {

      final XFile xfile = await _controller!.takePicture();
      final File file = File(xfile.path); // Convert XFile to File
      widget.onCapture(file);
      // Return only bytes
      //Navigator.pop(context, file);
    } catch (e) {
      debugPrint("Error capturing photo: $e");
    }
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Take Selfie")),
      body: FutureBuilder(
        future: _initController,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          return CameraPreview(_controller!);
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _capturePhoto,
        child: const Icon(Icons.camera_alt),
      ),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}
