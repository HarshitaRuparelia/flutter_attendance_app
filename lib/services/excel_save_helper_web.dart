import 'dart:typed_data';

// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

typedef ExcelSaveResult = ({String fileName, String displayPath});

Future<ExcelSaveResult> saveExcelFile(List<int> bytes, String fileName) async {
  final blob = html.Blob(
    [Uint8List.fromList(bytes)],
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  );
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', fileName)
    ..click();
  html.Url.revokeObjectUrl(url);

  return (fileName: fileName, displayPath: fileName);
}
