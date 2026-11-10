import '../models/holding.dart';
import '../models/upload.dart';
import 'api_client.dart';

abstract class UploadsApiBase {
  /// Uploads a screenshot as multipart form data and returns its new
  /// upload id.
  Future<int> createUpload({required List<int> bytes, required String filename, required String mimeType});

  /// Runs (or re-reads the already-run result of) vision extraction for
  /// [uploadId]. Always returns a normal [UploadRecord] — extraction
  /// failure is recorded as `status: "failed"` in a 200 response, not an
  /// HTTP error.
  Future<UploadRecord> extractUpload(int uploadId);

  /// Confirms [uploadId] into a real snapshot. Exactly one of [accountId]
  /// or [newAccount] must be non-null. Throws `ApiException(409, ...)` if
  /// the upload was already confirmed or discarded by another request.
  Future<void> confirmUpload({
    required int uploadId,
    required int? accountId,
    required ({String name, String institution, String accountType})? newAccount,
    required DateTime takenAt,
    required List<HoldingIn> holdings,
  });

  /// Discards [uploadId]. Throws `ApiException(409, ...)` if the upload
  /// was already confirmed or discarded by another request.
  Future<void> discardUpload(int uploadId);
}

/// Wraps the backend's `/uploads` endpoints.
class UploadsApi implements UploadsApiBase {
  final ApiClient _client;

  UploadsApi(this._client);

  @override
  Future<int> createUpload({
    required List<int> bytes,
    required String filename,
    required String mimeType,
  }) async {
    final body = await _client.postMultipart(
      '/uploads',
      bytes: bytes,
      filename: filename,
      fieldName: 'file',
      contentType: mimeType,
    );
    return (body as Map<String, dynamic>)['id'] as int;
  }

  @override
  Future<UploadRecord> extractUpload(int uploadId) async {
    final body = await _client.post('/uploads/$uploadId/extract');
    return UploadRecord.fromJson(body as Map<String, dynamic>);
  }

  @override
  Future<void> confirmUpload({
    required int uploadId,
    required int? accountId,
    required ({String name, String institution, String accountType})? newAccount,
    required DateTime takenAt,
    required List<HoldingIn> holdings,
  }) async {
    await _client.post('/uploads/$uploadId/confirm', body: {
      'account_id': accountId,
      'new_account': newAccount == null
          ? null
          : {
              'name': newAccount.name,
              'institution': newAccount.institution,
              'account_type': newAccount.accountType,
            },
      'taken_at': _formatDate(takenAt),
      'holdings': holdings.map((holding) => holding.toJson()).toList(),
    });
  }

  @override
  Future<void> discardUpload(int uploadId) async {
    await _client.post('/uploads/$uploadId/discard');
  }

  /// Formats [date] as a plain `YYYY-MM-DD` string, matching the backend's
  /// `date`-typed `taken_at` field (no time component).
  String _formatDate(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }
}
