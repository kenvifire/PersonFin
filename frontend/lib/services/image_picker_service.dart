import 'package:image_picker/image_picker.dart';

/// Wraps `image_picker`'s `ImagePicker` behind an interface callers can take
/// as a constructor parameter, so widget tests can fake it instead of
/// touching the real SDK (which isn't available in the test environment).
/// `pickImage` returns `null` when the user cancels the picker.
abstract class ImagePickerService {
  Future<({List<int> bytes, String filename, String mimeType})?> pickImage();
}

/// Real implementation backed by `image_picker`. `ImageSource.camera` adds
/// the browser's `capture` attribute: mobile browsers honor it and open the
/// camera directly (matching "snap a screenshot"), while desktop browsers
/// ignore it and fall back to a normal file dialog — so one source works
/// for both.
///
/// Must be called synchronously from within the user-gesture handler that
/// triggers it (e.g. a `FloatingActionButton`'s `onPressed`) — not from a
/// screen's `initState` reached via navigation. On the web, picking opens a
/// native `<input type="file">` dialog via a synthetic `element.click()`,
/// and browsers (iOS WebKit in particular) only honor that synthetic click
/// within an unbroken user-gesture call stack. Call it even one async hop
/// removed from the real tap — e.g. after a route push — and the browser
/// silently ignores the click: no dialog opens, and since `image_picker`'s
/// web implementation only resolves its result on the dialog's own
/// change/cancel/error events, the returned future then never completes.
class RealImagePickerService implements ImagePickerService {
  @override
  Future<({List<int> bytes, String filename, String mimeType})?> pickImage() async {
    final file = await ImagePicker().pickImage(source: ImageSource.camera);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    return (bytes: bytes, filename: file.name, mimeType: file.mimeType ?? 'image/jpeg');
  }
}
