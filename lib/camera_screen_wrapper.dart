import 'package:flutter/material.dart';

import 'camera/camera_screen_mobile.dart'
  if (dart.library.html) 'camera/camera_screen_web.dart';

class CameraScreenWrapper extends StatelessWidget {
  const CameraScreenWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return CameraScreen(
      onCapture: (bytes)
      {
         Navigator.pop(context, bytes);
      },
    );
  }
}
