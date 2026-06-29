import 'dart:io';

import 'package:intl/intl.dart';
import 'package:media_store_plus/media_store_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

typedef ExcelSaveResult = ({String fileName, String displayPath});

Future<String> _uniqueFileName(String fileName, Directory dir) async {
  var target = File('${dir.path}/$fileName');
  if (!await target.exists()) return fileName;

  final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
  final baseName = fileName.replaceAll('.xlsx', '');
  return '${baseName}_$stamp.xlsx';
}

Future<void> _requestLegacyStorageIfNeeded() async {
  if (!Platform.isAndroid) return;

  final sdk = await MediaStore().getPlatformSDKInt();
  if (sdk <= 29) {
    await Permission.storage.request();
  }
}

Future<ExcelSaveResult> saveExcelFile(List<int> bytes, String fileName) async {
  await _requestLegacyStorageIfNeeded();

  if (Platform.isAndroid) {
    final tempDir = await getTemporaryDirectory();
    final tempFile = File('${tempDir.path}/$fileName');
    await tempFile.writeAsBytes(bytes, flush: true);

    final saveInfo = await MediaStore().saveFile(
      tempFilePath: tempFile.path,
      dirType: DirType.download,
      dirName: DirName.download,
      relativePath: FilePath.root,
    );

    if (saveInfo == null) {
      throw Exception('Could not save file to Downloads');
    }

    final savedPath = await MediaStore().getFilePathFromUri(
      uriString: saveInfo.uri.toString(),
    );

    return (
      fileName: saveInfo.name,
      displayPath: savedPath ?? 'Downloads/${saveInfo.name}',
    );
  }

  Directory? dir = await getDownloadsDirectory();
  dir ??= await getApplicationDocumentsDirectory();

  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }

  final uniqueName = await _uniqueFileName(fileName, dir);
  final target = File('${dir.path}/$uniqueName');
  await target.writeAsBytes(bytes, flush: true);

  return (fileName: uniqueName, displayPath: target.path);
}
