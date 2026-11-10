import 'package:flutter/material.dart';

import '../models/todo.dart';

/// One row in the to-dos list: a checkbox bound to [todo.done] (calling
/// [onToggle]), the description (struck through when done), and a
/// trailing delete action (calling [onDelete]).
class TodoListTile extends StatelessWidget {
  final TodoItem todo;
  final ValueChanged<bool?> onToggle;
  final VoidCallback onDelete;

  const TodoListTile({
    super.key,
    required this.todo,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: todo.done,
      onChanged: onToggle,
      title: Text(
        todo.description,
        style: todo.done ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
      ),
      secondary: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Delete to-do',
        onPressed: onDelete,
      ),
    );
  }
}
