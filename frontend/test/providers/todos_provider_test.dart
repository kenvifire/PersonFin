import 'package:flutter_test/flutter_test.dart';
import 'package:personfin/api/api_client.dart';
import 'package:personfin/models/todo.dart';
import 'package:personfin/providers/dashboard_provider.dart' show LoadState;
import 'package:personfin/providers/todos_provider.dart';

import '../fakes.dart';

void main() {
  group('TodosProvider', () {
    test('load() populates todos on success', () async {
      final todosApi = FakeTodosApi();
      final provider = TodosProvider(todosApi: todosApi);

      await provider.load();

      expect(provider.state, LoadState.loaded);
      expect(provider.todos, hasLength(1));
      expect(provider.todos.first.description, 'Rebalance equity');
      expect(provider.errorMessage, isNull);
    });

    test('load() sets state to error with the ApiException message on failure', () async {
      final todosApi = FakeTodosApi(
        listTodosError: ApiException(500, 'Internal server error'),
      );
      final provider = TodosProvider(todosApi: todosApi);

      await provider.load();

      expect(provider.state, LoadState.error);
      expect(provider.errorMessage, 'Internal server error');
    });

    test('add() appends the new todo on success', () async {
      final todosApi = FakeTodosApi(
        createdTodo:
            TodoItem(id: 42, description: 'Buy more bonds', done: false, relatedAssetClass: 'Bond'),
      );
      final provider = TodosProvider(todosApi: todosApi);
      await provider.load();

      await provider.add('Buy more bonds', relatedAssetClass: 'Bond');

      expect(provider.todos, hasLength(2));
      expect(provider.todos.last.id, 42);
      expect(provider.todos.last.description, 'Buy more bonds');
      expect(provider.errorMessage, isNull);
    });

    test('add() rolls back the optimistic entry and sets errorMessage on failure', () async {
      final todosApi = FakeTodosApi(
        createTodoError: ApiException(422, 'description must not be blank'),
      );
      final provider = TodosProvider(todosApi: todosApi);
      await provider.load();
      final originalCount = provider.todos.length;

      await provider.add('', relatedAssetClass: null);

      expect(provider.todos, hasLength(originalCount));
      expect(provider.errorMessage, 'description must not be blank');
    });

    test("toggle() updates the item's done flag on success", () async {
      final existing =
          TodoItem(id: 1, description: 'Rebalance equity', done: false, relatedAssetClass: 'Equity');
      final todosApi = FakeTodosApi(
        fixedTodos: [existing],
        updatedTodo:
            TodoItem(id: 1, description: 'Rebalance equity', done: true, relatedAssetClass: 'Equity'),
      );
      final provider = TodosProvider(todosApi: todosApi);
      await provider.load();

      await provider.toggle(existing);

      expect(provider.todos, hasLength(1));
      expect(provider.todos.first.done, isTrue);
      expect(todosApi.lastSetDoneId, 1);
      expect(todosApi.lastSetDoneValue, true);
    });

    test('remove() removes the item on success', () async {
      final existing =
          TodoItem(id: 1, description: 'Rebalance equity', done: false, relatedAssetClass: 'Equity');
      final todosApi = FakeTodosApi(fixedTodos: [existing]);
      final provider = TodosProvider(todosApi: todosApi);
      await provider.load();

      await provider.remove(1);

      expect(provider.todos, isEmpty);
      expect(todosApi.lastDeletedId, 1);
    });
  });
}
