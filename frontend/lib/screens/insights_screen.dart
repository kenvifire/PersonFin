import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/insights.dart';
import '../providers/dashboard_provider.dart' show LoadState;
import '../providers/insights_provider.dart';
import '../providers/todos_provider.dart';
import '../widgets/allocation_bar.dart';
import '../widgets/todo_list_tile.dart';

/// The app's second tab: editable allocation targets, the DeepSeek
/// narrative, and the to-do list.
///
/// [InsightsProvider] and [TodosProvider] are consumed independently —
/// the to-do section renders whenever [TodosProvider.state] is
/// [LoadState.loaded], regardless of the insights state, since the two
/// are independent data and one failing shouldn't hide the other.
class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  final _todoController = TextEditingController();

  @override
  void dispose() {
    _todoController.dispose();
    super.dispose();
  }

  void _submitTodo(TodosProvider todosProvider) {
    final description = _todoController.text.trim();
    if (description.isEmpty) return;
    todosProvider.add(description);
    _todoController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final insightsProvider = context.watch<InsightsProvider>();
    final todosProvider = context.watch<TodosProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Insights')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildInsightsSection(insightsProvider),
          if (todosProvider.state == LoadState.loaded) ...[
            const SizedBox(height: 24),
            _buildTodoSection(todosProvider),
          ],
        ],
      ),
    );
  }

  Widget _buildInsightsSection(InsightsProvider provider) {
    switch (provider.state) {
      case LoadState.loading:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator()),
        );
      case LoadState.error:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    provider.errorMessage ?? 'Something went wrong',
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton(onPressed: provider.load, child: const Text('Retry')),
              ],
            ),
          ),
        );
      case LoadState.loaded:
        return _buildLoadedInsights(provider);
    }
  }

  Widget _buildLoadedInsights(InsightsProvider provider) {
    final data = provider.data!;
    final driftedClasses = data.drift.map((flag) => flag.assetClass).toSet();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Allocation', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final target in provider.targets)
          AllocationBar(
            key: ValueKey('allocation-bar-${target.assetClass}'),
            assetClass: target.assetClass,
            targetPct: target.targetPct,
            actualPct: _actualPctFor(data, target.assetClass),
            isUserSet: target.isUserSet,
            isDrifted: driftedClasses.contains(target.assetClass),
            onTargetChanged: (value) => provider.updateTarget(target.assetClass, value),
          ),
        const SizedBox(height: 16),
        _buildNarrativeCard(data.narrative),
      ],
    );
  }

  /// `actualPct = byAssetClass[assetClass] / netWorth * 100`, guarding
  /// `netWorth == 0` to 0 — matching the backend's own zero-net-worth
  /// handling rather than dividing by zero.
  double _actualPctFor(InsightsData data, String assetClass) {
    final netWorth = data.dashboard.netWorth;
    if (netWorth == 0) return 0;
    final value = data.dashboard.byAssetClass[assetClass] ?? 0;
    return value / netWorth * 100;
  }

  /// Shows `narrative.summary` as-is, whether or not it's the real
  /// DeepSeek narrative, the zero-net-worth placeholder, or (when
  /// `narrativeUnavailable` is true) the backend's own friendly
  /// "temporarily unavailable" fallback — never adding an extra error
  /// banner on top of it.
  Widget _buildNarrativeCard(InsightsNarrative narrative) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(narrative.summary),
            if (narrative.actionItems.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final item in narrative.actionItems)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('• ${item.suggestion}'),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTodoSection(TodosProvider todosProvider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('To-dos', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final todo in todosProvider.todos)
          TodoListTile(
            key: ValueKey('todo-${todo.id}'),
            todo: todo,
            onToggle: (_) => todosProvider.toggle(todo),
            onDelete: () => todosProvider.remove(todo.id),
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _todoController,
                decoration: const InputDecoration(hintText: '+ Add to-do'),
                onSubmitted: (_) => _submitTodo(todosProvider),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'Add to-do',
              onPressed: () => _submitTodo(todosProvider),
            ),
          ],
        ),
      ],
    );
  }
}
