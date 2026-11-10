import 'extraction.dart';

/// Mirrors the fields of `UploadOut`/`UploadExtractOut`/`UploadDetailOut`
/// this app actually uses. `status` is one of `"pending"`, `"extracted"`,
/// `"failed"`, `"confirming"`, `"confirmed"`, `"discarded"`.
class UploadRecord {
  final int id;
  final String status;
  final ExtractionResult? extractedPayload;
  final String? extractionError;
  final int? suggestedAccountId;

  UploadRecord({
    required this.id,
    required this.status,
    required this.extractedPayload,
    required this.extractionError,
    required this.suggestedAccountId,
  });

  factory UploadRecord.fromJson(Map<String, dynamic> json) => UploadRecord(
        id: json['id'] as int,
        status: json['status'] as String,
        extractedPayload: json['extracted_payload'] == null
            ? null
            : ExtractionResult.fromJson(json['extracted_payload'] as Map<String, dynamic>),
        extractionError: json['extraction_error'] as String?,
        suggestedAccountId: json['suggested_account_id'] as int?,
      );
}
