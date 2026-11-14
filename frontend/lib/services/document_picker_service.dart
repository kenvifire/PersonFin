import 'package:file_picker/file_picker.dart';

/// Wraps `file_picker` behind an interface callers can take as a
/// constructor parameter, so widget tests can fake it instead of
/// touching the real SDK (which isn't available in the test
/// environment). `pickDocument` returns `null` when the user cancels
/// the picker.
abstract class DocumentPickerService {
  Future<({List<int> bytes, String filename, String mimeType})?> pickDocument();
}

/// Real implementation backed by `file_picker`, restricted to PDF.
///
/// Must be called synchronously from within the user-gesture handler
/// that triggers it — the same requirement documented on
/// `RealImagePickerService`, and for the same reason: on the web, this
/// opens a native `<input type="file">` dialog via a synthetic
/// `element.click()`, which browsers (iOS WebKit in particular) only
/// honor within an unbroken user-gesture call stack.
class RealDocumentPickerService implements DocumentPickerService {
  @override
  Future<({List<int> bytes, String filename, String mimeType})?> pickDocument() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      withData: true,
    );
    if (result == null) return null;
    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) return null;
    return (bytes: bytes, filename: file.name, mimeType: 'application/pdf');
  }
}
