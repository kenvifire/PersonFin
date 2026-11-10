import 'package:flutter_test/flutter_test.dart';
import 'package:personfin/api/accounts_api.dart';
import 'package:personfin/api/api_client.dart';
import 'package:personfin/api/uploads_api.dart';
import 'package:personfin/models/account.dart';
import 'package:personfin/models/extraction.dart';
import 'package:personfin/models/holding.dart';
import 'package:personfin/models/upload.dart';
import 'package:personfin/providers/upload_flow_provider.dart';

/// Hand-written fake for `UploadsApiBase`. `createUpload`/`extractUpload`
/// each either return a fixed result or throw [error] (when set);
/// `confirmUpload`/`discardUpload` throw [confirmError]/[discardError]
/// when set, so both halves of the upload lifecycle can be made to fail
/// independently in a single test.
class FakeUploadsApi implements UploadsApiBase {
  final int uploadId;
  final UploadRecord? extractResult;
  final Object? startError;
  final Object? confirmError;
  final Object? discardError;

  int? capturedAccountId;
  ({String name, String institution, String accountType})? capturedNewAccount;
  DateTime? capturedTakenAt;
  List<HoldingIn>? capturedHoldings;
  int? capturedDiscardUploadId;

  FakeUploadsApi({
    this.uploadId = 1,
    this.extractResult,
    this.startError,
    this.confirmError,
    this.discardError,
  });

  @override
  Future<int> createUpload({
    required List<int> bytes,
    required String filename,
    required String mimeType,
  }) async {
    if (startError != null) throw startError!;
    return uploadId;
  }

  @override
  Future<UploadRecord> extractUpload(int uploadId) async {
    if (startError != null) throw startError!;
    return extractResult!;
  }

  @override
  Future<void> confirmUpload({
    required int uploadId,
    required int? accountId,
    required ({String name, String institution, String accountType})? newAccount,
    required DateTime takenAt,
    required List<HoldingIn> holdings,
  }) async {
    capturedAccountId = accountId;
    capturedNewAccount = newAccount;
    capturedTakenAt = takenAt;
    capturedHoldings = holdings;
    if (confirmError != null) throw confirmError!;
  }

  @override
  Future<void> discardUpload(int uploadId) async {
    capturedDiscardUploadId = uploadId;
    if (discardError != null) throw discardError!;
  }
}

class FakeAccountsApi implements AccountsApiBase {
  final List<AccountSummaryLite> accounts;

  FakeAccountsApi({this.accounts = const []});

  @override
  Future<List<AccountSummaryLite>> listAccounts() async => accounts;
}

UploadRecord extractedRecord({int id = 1}) => UploadRecord(
      id: id,
      status: 'extracted',
      extractedPayload: ExtractionResult(
        institution: 'Big Bank',
        accountLabel: 'Investing',
        accountTypeGuess: 'brokerage',
        takenAtGuess: DateTime(2026, 11, 1),
        holdings: [
          DraftHolding(
            label: 'AAPL',
            assetClassGuess: 'equity',
            quantity: 10,
            value: 2000.0,
            currencyGuess: 'USD',
            countryGuess: 'US',
          ),
        ],
      ),
      extractionError: null,
      suggestedAccountId: 5,
    );

UploadRecord failedRecord({int id = 1}) => UploadRecord(
      id: id,
      status: 'failed',
      extractedPayload: null,
      extractionError: 'Vision service could not read the image',
      suggestedAccountId: null,
    );

void main() {
  group('EditableHolding', () {
    test('isComplete is false when any required field is missing, true when all are set', () {
      final holding = EditableHolding();
      expect(holding.isComplete, isFalse);

      holding.label = 'AAPL';
      expect(holding.isComplete, isFalse);

      holding.assetClass = 'equity';
      expect(holding.isComplete, isFalse);

      holding.value = 2000.0;
      expect(holding.isComplete, isFalse);

      holding.currency = 'USD';
      expect(holding.isComplete, isFalse);

      holding.country = 'US';
      expect(holding.isComplete, isTrue);
    });

    test('fromDraft seeds fields from a DraftHolding, leaving assetClass/currency null when the '
        'guess was null', () {
      final draft = DraftHolding(
        label: 'Mystery Asset',
        assetClassGuess: null,
        quantity: 3.0,
        value: 500.0,
        currencyGuess: null,
        countryGuess: null,
      );

      final holding = EditableHolding.fromDraft(draft);

      expect(holding.label, 'Mystery Asset');
      expect(holding.assetClass, isNull);
      expect(holding.quantity, 3.0);
      expect(holding.value, 500.0);
      expect(holding.currency, isNull);
      expect(holding.country, '');
      expect(holding.isComplete, isFalse);
    });

    test('fromDraft case-folds and trims an asset-class/currency guess that matches the fixed '
        'lists once normalized', () {
      final holding = EditableHolding.fromDraft(DraftHolding(
        label: 'AAPL',
        assetClassGuess: ' Equity ',
        quantity: null,
        value: 100.0,
        currencyGuess: 'usd',
        countryGuess: 'US',
      ));

      expect(holding.assetClass, 'equity');
      expect(holding.currency, 'USD');
      expect(holding.isComplete, isTrue);
    });

    test('fromDraft nulls out an asset-class/currency guess that is not in the fixed lists even '
        'after normalizing', () {
      final holding = EditableHolding.fromDraft(DraftHolding(
        label: 'VTI',
        assetClassGuess: 'Stocks',
        quantity: null,
        value: 100.0,
        currencyGuess: 'US Dollar',
        countryGuess: 'US',
      ));

      expect(holding.assetClass, isNull);
      expect(holding.currency, isNull);
      expect(holding.isComplete, isFalse);

      final etf = EditableHolding.fromDraft(DraftHolding(
        label: 'XEQT',
        assetClassGuess: 'ETF',
        quantity: null,
        value: 100.0,
        currencyGuess: 'crypto',
        countryGuess: 'CA',
      ));
      expect(etf.assetClass, isNull);
      expect(etf.currency, 'CRYPTO');
    });
  });

  group('UploadFlowProvider', () {
    test('startUpload on a successful extraction seeds holdings/institution/takenAt/'
        'suggestedAccountId and sets state to ready', () async {
      final uploadsApi = FakeUploadsApi(extractResult: extractedRecord());
      final provider =
          UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());

      await provider.startUpload(bytes: [1, 2, 3], filename: 'shot.png', mimeType: 'image/png');

      expect(provider.state, UploadFlowState.ready);
      expect(provider.holdings, hasLength(1));
      expect(provider.holdings.first.label, 'AAPL');
      expect(provider.institution, 'Big Bank');
      expect(provider.takenAt, DateTime(2026, 11, 1));
      expect(provider.suggestedAccountId, 5);
    });

    // Review Focus: extraction failure is HTTP 200, not an exception —
    // startUpload must branch on record.status, landing in `failed` with
    // the extraction_error surfaced, not `error`.
    test('startUpload on a failed extraction sets state to failed, holdings stays empty, and '
        'errorMessage is the extraction_error', () async {
      final uploadsApi = FakeUploadsApi(extractResult: failedRecord());
      final provider =
          UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());

      await provider.startUpload(bytes: [1, 2, 3], filename: 'shot.png', mimeType: 'image/png');

      expect(provider.state, UploadFlowState.failed);
      expect(provider.holdings, isEmpty);
      expect(provider.errorMessage, 'Vision service could not read the image');
    });

    test('startUpload surfaces a thrown ApiException as state=error with errorMessage',
        () async {
      final uploadsApi = FakeUploadsApi(startError: ApiException(500, 'Server exploded'));
      final provider =
          UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());

      await provider.startUpload(bytes: [1, 2, 3], filename: 'shot.png', mimeType: 'image/png');

      expect(provider.state, UploadFlowState.error);
      expect(provider.errorMessage, 'Server exploded');
    });

    test('confirm with an accountId calls confirmUpload with that accountId and newAccount '
        'null, and sets state to confirmed on success', () async {
      final uploadsApi = FakeUploadsApi(extractResult: extractedRecord());
      final provider =
          UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());
      await provider.startUpload(bytes: [1, 2, 3], filename: 'shot.png', mimeType: 'image/png');

      await provider.confirm(accountId: 7, newAccount: null);

      expect(provider.state, UploadFlowState.confirmed);
      expect(uploadsApi.capturedAccountId, 7);
      expect(uploadsApi.capturedNewAccount, isNull);
    });

    // Review Focus: confirm racing an already-finalized upload is a 409,
    // and must land on `alreadyFinalized`, distinct from the generic
    // `error` state other ApiExceptions produce.
    test('confirm surfaces a 409 ApiException as state=alreadyFinalized, not state=error',
        () async {
      final uploadsApi = FakeUploadsApi(
        extractResult: extractedRecord(),
        confirmError: ApiException(409, 'Upload is already finalized'),
      );
      final provider =
          UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());
      await provider.startUpload(bytes: [1, 2, 3], filename: 'shot.png', mimeType: 'image/png');

      await provider.confirm(accountId: 7, newAccount: null);

      expect(provider.state, UploadFlowState.alreadyFinalized);
      expect(provider.errorMessage, 'Upload is already finalized');
    });

    test('confirm surfaces a non-409 ApiException as state=error with errorMessage', () async {
      final uploadsApi = FakeUploadsApi(
        extractResult: extractedRecord(),
        confirmError: ApiException(500, 'Server exploded'),
      );
      final provider =
          UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());
      await provider.startUpload(bytes: [1, 2, 3], filename: 'shot.png', mimeType: 'image/png');

      await provider.confirm(accountId: 7, newAccount: null);

      expect(provider.state, UploadFlowState.error);
      expect(provider.errorMessage, 'Server exploded');
    });

    test('discard calls discardUpload and sets state to confirmed on success', () async {
      final uploadsApi = FakeUploadsApi(extractResult: extractedRecord());
      final provider =
          UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());
      await provider.startUpload(bytes: [1, 2, 3], filename: 'shot.png', mimeType: 'image/png');

      await provider.discard();

      expect(provider.state, UploadFlowState.confirmed);
      expect(uploadsApi.capturedDiscardUploadId, 1);
    });

    // Review Focus: discard racing an already-finalized upload is a 409,
    // and must land on `alreadyFinalized`.
    test('discard surfaces a 409 ApiException as state=alreadyFinalized', () async {
      final uploadsApi = FakeUploadsApi(
        extractResult: extractedRecord(),
        discardError: ApiException(409, 'Upload is already finalized'),
      );
      final provider =
          UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());
      await provider.startUpload(bytes: [1, 2, 3], filename: 'shot.png', mimeType: 'image/png');

      await provider.discard();

      expect(provider.state, UploadFlowState.alreadyFinalized);
      expect(provider.errorMessage, 'Upload is already finalized');
    });

    test('loadAccounts calls accountsApi.listAccounts() and fills accounts', () async {
      final accountsApi = FakeAccountsApi(accounts: [
        AccountSummaryLite(id: 1, name: 'Checking', institution: 'Big Bank', accountType: 'bank'),
      ]);
      final provider = UploadFlowProvider(uploadsApi: FakeUploadsApi(), accountsApi: accountsApi);

      await provider.loadAccounts();

      expect(provider.accounts, hasLength(1));
      expect(provider.accounts.first.name, 'Checking');
    });
      test('an upload completing after the provider is disposed (route popped mid-upload) does '
        'not throw', () async {
      final uploadsApi = FakeUploadsApi(extractResult: extractedRecord());
      final provider =
          UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());

      final pending =
          provider.startUpload(bytes: [1, 2, 3], filename: 'shot.png', mimeType: 'image/png');
      provider.dispose();

      await expectLater(pending, completes);
    });
  });
}
