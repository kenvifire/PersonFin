import '../models/todo.dart';
import 'api_client.dart';

abstract class TodosApiBase {
  Future<List<TodoItem>> listTodos();
  Future<TodoItem> createTodo({required String description, String? relatedAssetClass});
  Future<TodoItem> setDone(int id, bool done);
  Future<void> deleteTodo(int id);
}

/// Wraps the backend's `/todos` CRUD endpoints.
class TodosApi implements TodosApiBase {
  final ApiClient _client;

  TodosApi(this._client);

  @override
  Future<List<TodoItem>> listTodos() async {
    final body = await _client.get('/todos');
    return (body as List)
        .map((entry) => TodoItem.fromJson(entry as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<TodoItem> createTodo({required String description, String? relatedAssetClass}) async {
    final body = await _client.post('/todos', body: {
      'description': description,
      'related_asset_class': relatedAssetClass,
    });
    return TodoItem.fromJson(body as Map<String, dynamic>);
  }

  @override
  Future<TodoItem> setDone(int id, bool done) async {
    final body = await _client.patch('/todos/$id', body: {'done': done});
    return TodoItem.fromJson(body as Map<String, dynamic>);
  }

  @override
  Future<void> deleteTodo(int id) async {
    await _client.delete('/todos/$id');
  }
}
