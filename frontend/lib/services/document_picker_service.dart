import 'package:file_picker/file_picker.dart';

/// Wraps `file_picker` behind an interface callers can take as a
/// constructor parameter, so widget tests can fake it instead of
/// touching the real SDK (which isn't available in the test
/// environment). `pickDocument` returns `null` when the user cancels
/// the picker.
abstract class DocumentPickerService {
  Future<({List<int> bytes, String filename, String mimeType})?> pickDocument();
}

/// Real implementation backed by `file_picker`.
///
/// Deliberately uses `FileType.any` rather than
/// `FileType.custom`/`allowedExtensions: ['pdf']`: `file_picker` 8.3.7
/// builds the native dialog's extension filter by folding each allowed
/// extension into a string starting with `''`, which for a single
/// extension produces `" .pdf"` — a leading space. Desktop Chrome on
/// macOS parses that filter strictly enough that it matches nothing at
/// all, graying out every file (PDFs included) and disabling "Open"
/// entirely, rather than just not filtering. Picking with no filter and
/// checking the extension ourselves afterward sidesteps the bug.
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
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null) return null;
    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) return null;
    if (!file.name.toLowerCase().endsWith('.pdf')) return null;
    return (bytes: bytes, filename: file.name, mimeType: 'application/pdf');
  }
}
