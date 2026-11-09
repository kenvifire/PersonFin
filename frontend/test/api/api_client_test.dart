import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personfin/api/api_client.dart';

void main() {
  group('ApiClient', () {
    test('get() returns decoded JSON on 200', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({'hello': 'world'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );

      final result = await client.get('/things');

      expect(result, {'hello': 'world'});
    });

    test('get() sends Authorization header when getToken returns a token',
        () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode({}), 200);
      });
      final client = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => 'abc123',
        onUnauthorized: () {},
      );

      await client.get('/things');

      expect(capturedRequest!.headers['Authorization'], 'Bearer abc123');
    });

    test('get() sends no Authorization header when getToken returns null',
        () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode({}), 200);
      });
      final client = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );

      await client.get('/things');

      expect(capturedRequest!.headers.containsKey('Authorization'), isFalse);
    });

    test('post() JSON-encodes the body and sets Content-Type', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode({'ok': true}), 200);
      });
      final client = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );

      final result = await client.post('/things', body: {'name': 'test'});

      expect(capturedRequest!.headers['Content-Type'], 'application/json');
      expect(capturedRequest!.body, jsonEncode({'name': 'test'}));
      expect(result, {'ok': true});
    });

    test(
        'post() lets a body-encoding error propagate as itself, not as ApiException(0, ...)',
        () async {
      var handlerCalled = false;
      final mockClient = MockClient((request) async {
        handlerCalled = true;
        return http.Response(jsonEncode({}), 200);
      });
      final client = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );

      // A closure (not a Function literal reference) is not JSON-encodable,
      // so jsonEncode throws before any HTTP call is made. That is a caller
      // bug, not a network failure, so it must surface as itself.
      expect(
        () => client.post('/things', body: {'fn': () {}}),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      expect(handlerCalled, isFalse);
    });

    test(
        'postMultipart() lets an invalid content-type string propagate as itself, not as ApiException(0, ...)',
        () async {
      var handlerCalled = false;
      final mockClient = MockClient((request) async {
        handlerCalled = true;
        return http.Response(jsonEncode({}), 200);
      });
      final client = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );

      // "not-a-valid-media-type" has no "/" separator, so MediaType.parse
      // throws before any HTTP call is made. That is a caller bug, not a
      // network failure, so it must surface as itself.
      expect(
        () => client.postMultipart(
          '/uploads',
          bytes: utf8.encode('data'),
          filename: 'f.png',
          fieldName: 'file',
          contentType: 'not-a-valid-media-type',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(handlerCalled, isFalse);
    });

    test('delete() returns null on 204 with empty body', () async {
      final mockClient = MockClient((request) async {
        return http.Response('', 204);
      });
      final client = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );

      final result = await client.delete('/things/1');

      expect(result, isNull);
    });

    test(
        'any 401 response calls onUnauthorized exactly once and throws ApiException(401, ...)',
        () async {
      var unauthorizedCallCount = 0;
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({'detail': 'Not authenticated'}),
          401,
        );
      });
      final client = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {
          unauthorizedCallCount++;
        },
      );

      await expectLater(
        client.get('/things'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.message, 'message', 'Not authenticated'),
        ),
      );
      expect(unauthorizedCallCount, 1);
    });

    test(
        'a 422 with a list-shaped detail joins the validation messages into one string',
        () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'detail': [
              {
                'loc': ['body', 'amount'],
                'msg': 'field required',
                'type': 'value_error.missing',
              },
              {
                'loc': ['body', 'date'],
                'msg': 'invalid date format',
                'type': 'value_error',
              },
            ],
          }),
          422,
        );
      });
      final client = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );

      await expectLater(
        client.post('/things', body: {}),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 422)
              .having(
                (e) => e.message,
                'message',
                'field required; invalid date format',
              ),
        ),
      );
    });

    test('a 503 throws ApiException(503, <detail string>)', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({'detail': 'Service unavailable'}),
          503,
        );
      });
      final client = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );

      await expectLater(
        client.get('/things'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', 'Service unavailable'),
        ),
      );
    });

    test('a client-level exception (no response) throws ApiException(0, ...)',
        () async {
      final mockClient = MockClient((request) async {
        throw http.ClientException('Connection failed');
      });
      final client = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );

      await expectLater(
        client.get('/things'),
        throwsA(
          isA<ApiException>().having((e) => e.statusCode, 'statusCode', 0),
        ),
      );
    });

    test(
        'postMultipart() builds a multipart request with the given field name and content type',
        () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode({'uploaded': true}), 200);
      });
      final client = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => 'tok',
        onUnauthorized: () {},
      );

      final result = await client.postMultipart(
        '/uploads',
        bytes: utf8.encode('fake file contents'),
        filename: 'receipt.png',
        fieldName: 'file',
        contentType: 'image/png',
      );

      expect(result, {'uploaded': true});
      final contentTypeHeader = capturedRequest!.headers['content-type']!;
      expect(contentTypeHeader, startsWith('multipart/form-data'));
      final bodyText = utf8.decode(capturedRequest!.bodyBytes);
      expect(bodyText, contains('name="file"'));
      expect(bodyText, contains('filename="receipt.png"'));
      expect(bodyText.toLowerCase(), contains('content-type: image/png'));
      expect(bodyText, contains('fake file contents'));
      expect(capturedRequest!.headers['Authorization'], 'Bearer tok');
    });
  });
}
