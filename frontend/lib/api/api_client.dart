import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

/// Thrown by [ApiClient] whenever a request fails, whether the server
/// returned an error status or the request never reached the network at
/// all.
class ApiException implements Exception {
  /// The HTTP status code returned by the server, or `0` when there was no
  /// HTTP response at all (e.g. the device is offline).
  final int statusCode;

  /// A human-readable description of what went wrong, suitable for display.
  final String message;

  ApiException(this.statusCode, this.message);

  @override
  String toString() => 'ApiException($statusCode, $message)';
}

/// The single HTTP client every `*Api` class in the app routes its requests
/// through. It centralizes base-URL resolution, bearer-token auth, JSON
/// encoding/decoding, and error handling so no other code calls `package:http`
/// directly.
class ApiClient {
  final String baseUrl;
  final http.Client httpClient;
  final String? Function() getToken;
  final void Function() onUnauthorized;

  ApiClient({
    required this.baseUrl,
    required this.httpClient,
    required this.getToken,
    required this.onUnauthorized,
  });

  Future<dynamic> get(String path, {Map<String, String>? query}) {
    final uri = _buildUri(path, query: query);
    final headers = _headers();
    return _send(() => httpClient.get(uri, headers: headers));
  }

  Future<dynamic> post(String path, {Object? body}) {
    final uri = _buildUri(path);
    final headers = _headers(jsonBody: body != null);
    // Encode the body before entering _send's try block: a non-encodable
    // body is a caller bug, not a network failure, and must propagate as
    // itself rather than be reported as ApiException(0, ...).
    final encodedBody = body != null ? jsonEncode(body) : null;
    return _send(() => httpClient.post(uri, headers: headers, body: encodedBody));
  }

  Future<dynamic> patch(String path, {Object? body}) {
    final uri = _buildUri(path);
    final headers = _headers(jsonBody: body != null);
    final encodedBody = body != null ? jsonEncode(body) : null;
    return _send(() => httpClient.patch(uri, headers: headers, body: encodedBody));
  }

  Future<dynamic> delete(String path) {
    final uri = _buildUri(path);
    final headers = _headers();
    return _send(() => httpClient.delete(uri, headers: headers));
  }

  Future<dynamic> postMultipart(
    String path, {
    required List<int> bytes,
    required String filename,
    required String fieldName,
    required String contentType,
  }) {
    final uri = _buildUri(path);
    // Build the request and multipart file before entering _send's try
    // block: an invalid content-type string or other construction failure
    // is a caller bug, not a network failure, and must propagate as itself.
    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll(_headers())
      ..files.add(http.MultipartFile.fromBytes(
        fieldName,
        bytes,
        filename: filename,
        contentType: MediaType.parse(contentType),
      ));
    return _send(() async {
      final streamedResponse = await httpClient.send(request);
      return http.Response.fromStream(streamedResponse);
    });
  }

  Uri _buildUri(String path, {Map<String, String>? query}) {
    return Uri.parse('$baseUrl$path').replace(queryParameters: query);
  }

  Map<String, String> _headers({bool jsonBody = false}) {
    final headers = <String, String>{};
    final token = getToken();
    if (token != null) {
      headers['Authorization'] = 'Bearer $token';
    }
    if (jsonBody) {
      headers['Content-Type'] = 'application/json';
    }
    return headers;
  }

  Future<dynamic> _send(Future<http.Response> Function() request) async {
    http.Response response;
    try {
      response = await request();
    } catch (_) {
      throw ApiException(0, 'Network error — check your connection');
    }

    if (response.statusCode == 401) {
      onUnauthorized();
      throw ApiException(401, _errorMessage(response));
    }

    if (response.statusCode >= 400) {
      throw ApiException(response.statusCode, _errorMessage(response));
    }

    if (response.statusCode == 204 || response.body.isEmpty) {
      return null;
    }

    return jsonDecode(response.body);
  }

  /// Parses the server's error `detail` field, which FastAPI sends either as
  /// a plain string (most errors) or as a list of validation-error objects
  /// (422s), each carrying a `msg` field.
  String _errorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['detail'] is String) {
        return decoded['detail'] as String;
      }
      if (decoded is Map && decoded['detail'] is List) {
        final details = decoded['detail'] as List;
        return details
            .map((entry) =>
                entry is Map && entry['msg'] != null ? entry['msg'].toString() : entry.toString())
            .join('; ');
      }
    } catch (_) {
      // Body wasn't valid JSON shaped like a FastAPI error; fall through.
    }
    return 'Request failed with status ${response.statusCode}';
  }
}
