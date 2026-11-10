/// A user's to-do item, as returned by the `/todos` endpoints. Mirrors
/// `app.schemas.todo.TodoOut`.
class TodoItem {
  final int id;
  final String description;
  final bool done;
  final String? relatedAssetClass;

  TodoItem({
    required this.id,
    required this.description,
    required this.done,
    required this.relatedAssetClass,
  });

  factory TodoItem.fromJson(Map<String, dynamic> json) => TodoItem(
        id: json['id'] as int,
        description: json['description'] as String,
        done: json['done'] as bool,
        relatedAssetClass: json['related_asset_class'] as String?,
      );
}
