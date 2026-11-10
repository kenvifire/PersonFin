import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personfin/api/api_client.dart';
import 'package:personfin/api/todos_api.dart';

void main() {
  group('TodosApi', () {
    test('listTodos parses a GET /todos list response', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode([
            {
              'id': 1,
              'description': 'Rebalance equity',
              'done': false,
              'related_asset_class': 'Equity',
              'created_at': '2026-01-01T00:00:00',
            },
            {
              'id': 2,
              'description': 'Review bonds',
              'done': true,
              'related_asset_class': null,
              'created_at': '2026-01-02T00:00:00',
            },
          ]),
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
      final todosApi = TodosApi(apiClient);

      final todos = await todosApi.listTodos();

      expect(capturedRequest!.url.path, '/todos');
      expect(todos, hasLength(2));
      expect(todos.first.id, 1);
      expect(todos.first.description, 'Rebalance equity');
      expect(todos.first.done, isFalse);
      expect(todos.first.relatedAssetClass, 'Equity');
      expect(todos[1].done, isTrue);
      expect(todos[1].relatedAssetClass, isNull);
    });

    test('createTodo posts description/related_asset_class and parses the created TodoItem',
        () async {
      http.Request? capturedRequest;
      Map<String, dynamic>? capturedBody;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'id': 3,
            'description': 'Buy more bonds',
            'done': false,
            'related_asset_class': 'Bond',
            'created_at': '2026-01-03T00:00:00',
          }),
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
      final todosApi = TodosApi(apiClient);

      final todo = await todosApi.createTodo(description: 'Buy more bonds', relatedAssetClass: 'Bond');

      expect(capturedRequest!.url.path, '/todos');
      expect(capturedBody, {'description': 'Buy more bonds', 'related_asset_class': 'Bond'});
      expect(todo.id, 3);
      expect(todo.description, 'Buy more bonds');
      expect(todo.done, isFalse);
      expect(todo.relatedAssetClass, 'Bond');
    });

    test('setDone PATCHes done to /todos/{id} and parses the updated TodoItem', () async {
      http.Request? capturedRequest;
      Map<String, dynamic>? capturedBody;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'id': 1,
            'description': 'Rebalance equity',
            'done': true,
            'related_asset_class': 'Equity',
            'created_at': '2026-01-01T00:00:00',
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
      final todosApi = TodosApi(apiClient);

      final todo = await todosApi.setDone(1, true);

      expect(capturedRequest!.method, 'PATCH');
      expect(capturedRequest!.url.path, '/todos/1');
      expect(capturedBody, {'done': true});
      expect(todo.done, isTrue);
    });

    test('deleteTodo sends DELETE and tolerates a 204 empty response', () async {
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
      final todosApi = TodosApi(apiClient);

      await todosApi.deleteTodo(1);

      expect(capturedRequest!.method, 'DELETE');
      expect(capturedRequest!.url.path, '/todos/1');
    });
  });
}
