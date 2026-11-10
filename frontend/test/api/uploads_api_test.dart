import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personfin/api/api_client.dart';
import 'package:personfin/api/uploads_api.dart';
import 'package:personfin/models/holding.dart';

void main() {
  group('UploadsApi', () {
    test('createUpload posts multipart and returns the new id', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({'id': 42, 'status': 'pending'}),
          201,
          headers: {'content-type': 'application/json'},
        );
      });
      final apiClient = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );
      final uploadsApi = UploadsApi(apiClient);

      final id = await uploadsApi.createUpload(
        bytes: [1, 2, 3],
        filename: 'receipt.png',
        mimeType: 'image/png',
      );

      expect(id, 42);
      expect(capturedRequest!.url.path, '/uploads');
      final contentTypeHeader = capturedRequest!.headers['content-type']!;
      expect(contentTypeHeader, startsWith('multipart/form-data'));
      final bodyText = utf8.decode(capturedRequest!.bodyBytes);
      expect(bodyText, contains('name="file"'));
      expect(bodyText, contains('filename="receipt.png"'));
    });

    test('extractUpload parses a status:"extracted" response with a populated extractedPayload',
        () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, '/uploads/7/extract');
        return http.Response(
          jsonEncode({
            'id': 7,
            'status': 'extracted',
            'extracted_payload': {
              'institution': 'Big Bank',
              'account_label': 'Investing',
              'account_type_guess': 'brokerage',
              'taken_at_guess': '2026-11-01',
              'holdings': [
                {
                  'label': 'AAPL',
                  'asset_class_guess': 'equity',
                  'quantity': 10.0,
                  'value': 2000.0,
                  'currency_guess': 'USD',
                  'country_guess': 'US',
                },
              ],
            },
            'extraction_error': null,
            'suggested_account_id': 3,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final apiClient = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );
      final uploadsApi = UploadsApi(apiClient);

      final record = await uploadsApi.extractUpload(7);

      expect(record.id, 7);
      expect(record.status, 'extracted');
      expect(record.extractionError, isNull);
      expect(record.suggestedAccountId, 3);
      expect(record.extractedPayload, isNotNull);
      expect(record.extractedPayload!.institution, 'Big Bank');
      expect(record.extractedPayload!.holdings, hasLength(1));
      expect(record.extractedPayload!.holdings.first.label, 'AAPL');
    });

    // Review Focus: extraction failure is HTTP 200, not an ApiException —
    // the response body carries status:"failed" and extraction_error, and
    // extractUpload must return a normal UploadRecord, not throw.
    test('extractUpload parses a status:"failed" response with extractedPayload null and '
        'extraction_error set, without throwing', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'id': 8,
            'status': 'failed',
            'extracted_payload': null,
            'extraction_error': 'Vision service could not read the image',
            'suggested_account_id': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final apiClient = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );
      final uploadsApi = UploadsApi(apiClient);

      final record = await uploadsApi.extractUpload(8);

      expect(record.id, 8);
      expect(record.status, 'failed');
      expect(record.extractedPayload, isNull);
      expect(record.extractionError, 'Vision service could not read the image');
    });

    test('confirmUpload posts the exact JSON shape with accountId set and newAccount null',
        () async {
      Map<String, dynamic>? capturedBody;
      final mockClient = MockClient((request) async {
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('', 204);
      });
      final apiClient = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );
      final uploadsApi = UploadsApi(apiClient);

      await uploadsApi.confirmUpload(
        uploadId: 9,
        accountId: 5,
        newAccount: null,
        takenAt: DateTime(2026, 11, 1),
        holdings: [
          HoldingIn(
            label: 'AAPL',
            assetClass: 'equity',
            quantity: 10,
            value: 2000.0,
            currency: 'USD',
            country: 'US',
          ),
        ],
      );

      expect(capturedBody!['account_id'], 5);
      expect(capturedBody!['new_account'], isNull);
      expect(capturedBody!['taken_at'], '2026-11-01');
      expect(capturedBody!['holdings'], [
        {
          'label': 'AAPL',
          'asset_class': 'equity',
          'quantity': 10.0,
          'value': 2000.0,
          'currency': 'USD',
          'country': 'US',
        },
      ]);
    });

    test('confirmUpload posts the exact JSON shape with newAccount set and accountId null',
        () async {
      Map<String, dynamic>? capturedBody;
      final mockClient = MockClient((request) async {
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('', 204);
      });
      final apiClient = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );
      final uploadsApi = UploadsApi(apiClient);

      await uploadsApi.confirmUpload(
        uploadId: 9,
        accountId: null,
        newAccount: (name: 'New Account', institution: 'Big Bank', accountType: 'brokerage'),
        takenAt: DateTime(2026, 11, 1),
        holdings: [],
      );

      expect(capturedBody!['account_id'], isNull);
      expect(capturedBody!['new_account'], {
        'name': 'New Account',
        'institution': 'Big Bank',
        'account_type': 'brokerage',
      });
      expect(capturedBody!['holdings'], []);
    });

    test('discardUpload posts with no body and tolerates a 204 empty response', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response('', 204);
      });
      final apiClient = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );
      final uploadsApi = UploadsApi(apiClient);

      await uploadsApi.discardUpload(10);

      expect(capturedRequest!.url.path, '/uploads/10/discard');
      expect(capturedRequest!.body, isEmpty);
    });
  });
}
