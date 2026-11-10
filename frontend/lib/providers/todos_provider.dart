import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/todos_api.dart';
import '../models/todo.dart';
import 'dashboard_provider.dart' show LoadState;

/// Loads and mutates the user's to-dos, exposing them to the
/// insights/to-dos screen.
class TodosProvider extends ChangeNotifier {
  final TodosApiBase _todosApi;

  TodosProvider({required TodosApiBase todosApi}) : _todosApi = todosApi;

  LoadState state = LoadState.loading;
  List<TodoItem> todos = [];
  String? errorMessage;

  /// Fetches all to-dos. On success, updates [todos] and sets [state] to
  /// [LoadState.loaded]. If the request throws an [ApiException], sets
  /// [errorMessage] to its message and [state] to [LoadState.error].
  Future<void> load() async {
    try {
      todos = await _todosApi.listTodos();
      state = LoadState.loaded;
    } on ApiException catch (e) {
      errorMessage = e.message;
      state = LoadState.error;
    }
    notifyListeners();
  }

  /// Optimistically appends a placeholder to-do for [description] (and
  /// optional [relatedAssetClass]), then calls `createTodo` and replaces
  /// the placeholder with the server's copy. On failure, the optimistic
  /// entry is rolled back and [errorMessage] is set.
  Future<void> add(String description, {String? relatedAssetClass}) async {
    final placeholder = TodoItem(
      id: -DateTime.now().microsecondsSinceEpoch,
      description: description,
      done: false,
      relatedAssetClass: relatedAssetClass,
    );
    todos = [...todos, placeholder];
    notifyListeners();

    try {
      final created = await _todosApi.createTodo(
        description: description,
        relatedAssetClass: relatedAssetClass,
      );
      todos = [
        for (final todo in todos)
          if (todo.id == placeholder.id) created else todo,
      ];
      errorMessage = null;
    } on ApiException catch (e) {
      todos = todos.where((todo) => todo.id != placeholder.id).toList();
      errorMessage = e.message;
    }
    notifyListeners();
  }

  /// Toggles [item]'s done flag via the server, updating the local list
  /// on success.
  Future<void> toggle(TodoItem item) async {
    try {
      final updated = await _todosApi.setDone(item.id, !item.done);
      todos = [
        for (final todo in todos)
          if (todo.id == item.id) updated else todo,
      ];
      errorMessage = null;
    } on ApiException catch (e) {
      errorMessage = e.message;
    }
    notifyListeners();
  }

  /// Deletes the to-do with [id], removing it locally on success.
  Future<void> remove(int id) async {
    try {
      await _todosApi.deleteTodo(id);
      todos = todos.where((todo) => todo.id != id).toList();
      errorMessage = null;
    } on ApiException catch (e) {
      errorMessage = e.message;
    }
    notifyListeners();
  }
}
