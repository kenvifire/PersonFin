import 'package:image_picker/image_picker.dart';

/// Wraps `image_picker`'s `ImagePicker` behind an interface callers can take
/// as a constructor parameter, so widget tests can fake it instead of
/// touching the real SDK (which isn't available in the test environment).
/// `pickImage` returns `null` when the user cancels the picker.
abstract class ImagePickerService {
  Future<({List<int> bytes, String filename, String mimeType})?> pickImage();
}

/// Real implementation backed by `image_picker`. Uses `ImageSource.gallery`
/// rather than `ImageSource.camera`: the latter sets the browser's
/// `capture` attribute, which on mobile skips straight to the live camera
/// with no way to pick an existing photo — wrong for this app's actual use
/// (uploading an existing screenshot of a statement, not photographing
/// one). `gallery` opens the platform's normal picker, which on mobile
/// still offers "take a photo" as one of its options.
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
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    return (bytes: bytes, filename: file.name, mimeType: file.mimeType ?? 'image/jpeg');
  }
}
