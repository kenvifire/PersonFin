import 'package:flutter/foundation.dart';

import '../api/accounts_api.dart';
import '../api/api_client.dart';
import '../api/uploads_api.dart';
import '../models/account.dart';
import '../models/holding.dart';

enum UploadFlowState {
  picking,
  uploading,
  extracting,
  failed,
  ready,
  confirming,
  confirmed,
  alreadyFinalized,
  error,
}

/// Drives the upload -> review -> confirm/discard flow as a state
/// machine, from picking a screenshot through to a finalized snapshot.
///
/// Scoped to a single visit to `/upload`: `buildRouter` creates a fresh
/// instance (starting in [UploadFlowState.picking]) every time that route
/// is pushed, so a previous upload's terminal state never leaks into the
/// next one.
///
/// Extraction failure (the vision call couldn't read the screenshot) is a
/// normal, successful HTTP response whose *business* result is a
/// failure: [startUpload] lands on [UploadFlowState.failed], not
/// [UploadFlowState.error], and still shows the editable review form so
/// the user can enter holdings by hand. A 409 from [confirm]/[discard] —
/// the upload was already confirmed or discarded by another in-flight
/// request — is a genuine HTTP error, but is surfaced as the distinct
/// [UploadFlowState.alreadyFinalized] rather than the generic
/// [UploadFlowState.error], so the screen can tell the user what actually
/// happened instead of offering to retry.
class UploadFlowProvider extends ChangeNotifier {
  final UploadsApiBase _uploadsApi;
  final AccountsApiBase _accountsApi;

  UploadFlowProvider({required UploadsApiBase uploadsApi, required AccountsApiBase accountsApi})
      : _uploadsApi = uploadsApi,
        _accountsApi = accountsApi;

  UploadFlowState state = UploadFlowState.picking;
  List<EditableHolding> holdings = [];
  String institution = '';
  String accountLabel = '';
  DateTime takenAt = DateTime.now();
  int? suggestedAccountId;
  List<AccountSummaryLite> accounts = [];
  String? errorMessage;
  int? _uploadId;
  bool _disposed = false;

  // One instance is created per visit to `/upload` (see `buildRouter`) and
  // disposed when that route is popped — possibly while an upload/extract/
  // confirm call is still in flight (back button, or a 401 sign-out
  // redirecting to /login). Notifying after dispose would throw, so late
  // completions are silently dropped instead.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> loadAccounts() async {
    accounts = await _accountsApi.listAccounts();
    notifyListeners();
  }

  /// Uploads [bytes] and runs extraction on it. On success, branches on
  /// the resulting [UploadRecord.status] — never on a thrown exception,
  /// since a failed extraction is still a 200 — seeding the review form's
  /// fields when extraction succeeded, or clearing [holdings] and setting
  /// [errorMessage] when it didn't. A thrown [ApiException] (the upload
  /// or extract call itself failed) lands on [UploadFlowState.error].
  Future<void> startUpload({
    required List<int> bytes,
    required String filename,
    required String mimeType,
  }) async {
    state = UploadFlowState.uploading;
    notifyListeners();
    try {
      _uploadId = await _uploadsApi.createUpload(bytes: bytes, filename: filename, mimeType: mimeType);

      state = UploadFlowState.extracting;
      notifyListeners();
      final record = await _uploadsApi.extractUpload(_uploadId!);

      if (record.status == 'extracted') {
        final payload = record.extractedPayload!;
        holdings = payload.holdings.map(EditableHolding.fromDraft).toList();
        institution = payload.institution ?? '';
        accountLabel = payload.accountLabel ?? '';
        if (payload.takenAtGuess != null) {
          takenAt = payload.takenAtGuess!;
        }
        suggestedAccountId = record.suggestedAccountId;
        state = UploadFlowState.ready;
      } else {
        // status == 'failed': a normal 200 whose business result is a
        // failure. Still shows the editable form, per Review Focus.
        holdings = [];
        errorMessage = record.extractionError;
        state = UploadFlowState.failed;
      }
    } on ApiException catch (e) {
      errorMessage = e.message;
      state = UploadFlowState.error;
    }
    notifyListeners();
  }

  /// Confirms the upload into a real snapshot with the current
  /// [holdings]/[takenAt], under either an existing account ([accountId])
  /// or a brand-new one ([newAccount]).
  Future<void> confirm({
    required int? accountId,
    required ({String name, String institution, String accountType})? newAccount,
  }) async {
    state = UploadFlowState.confirming;
    notifyListeners();
    try {
      await _uploadsApi.confirmUpload(
        uploadId: _uploadId!,
        accountId: accountId,
        newAccount: newAccount,
        takenAt: takenAt,
        holdings: holdings.map((holding) => holding.toHoldingIn()).toList(),
      );
      state = UploadFlowState.confirmed;
    } on ApiException catch (e) {
      errorMessage = e.message;
      // Review Focus: confirm/discard race — a 409 here means another
      // in-flight request already confirmed or discarded this upload, a
      // distinct outcome from a generic failure.
      state = e.statusCode == 409 ? UploadFlowState.alreadyFinalized : UploadFlowState.error;
    }
    notifyListeners();
  }

  /// Discards the upload. On success, reuses [UploadFlowState.confirmed]
  /// to mean "done, leave screen" — there's no separate "discarded" state
  /// to show, since the screen's job is finished either way.
  Future<void> discard() async {
    try {
      await _uploadsApi.discardUpload(_uploadId!);
      state = UploadFlowState.confirmed;
    } on ApiException catch (e) {
      errorMessage = e.message;
      state = e.statusCode == 409 ? UploadFlowState.alreadyFinalized : UploadFlowState.error;
    }
    notifyListeners();
  }
}
