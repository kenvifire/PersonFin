import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/insights.dart';
import '../providers/dashboard_provider.dart';
import '../providers/insights_provider.dart';
import '../providers/todos_provider.dart';
import '../widgets/allocation_bar.dart';
import '../widgets/sign_out_button.dart';
import '../widgets/todo_list_tile.dart';

/// The app's second tab: editable allocation targets, the DeepSeek
/// narrative, and the to-do list.
///
/// [InsightsProvider] and [TodosProvider] are consumed independently —
/// the to-do section renders whenever [TodosProvider.state] is
/// [LoadState.loaded] (or an error + Retry row when it's
/// [LoadState.error]), regardless of the insights state, since the two
/// are independent data and one failing shouldn't hide the other. A failed
/// edit on either provider is surfaced as a SnackBar.
class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  final _todoController = TextEditingController();
  late final InsightsProvider _insightsProvider;
  late final TodosProvider _todosProvider;

  @override
  void initState() {
    super.initState();
    // Failed *edits* (target update, to-do add/toggle/remove) only set the
    // provider's errorMessage while its state stays `loaded`; nothing in
    // build() would otherwise show them. Listening (rather than checking in
    // build) fires once per failure, including a repeat failure with the
    // same message.
    _insightsProvider = context.read<InsightsProvider>()..addListener(_onInsightsChanged);
    _todosProvider = context.read<TodosProvider>()..addListener(_onTodosChanged);
  }

  @override
  void dispose() {
    _insightsProvider.removeListener(_onInsightsChanged);
    _todosProvider.removeListener(_onTodosChanged);
    _todoController.dispose();
    super.dispose();
  }

  void _onInsightsChanged() {
    final message = _insightsProvider.errorMessage;
    if (_insightsProvider.state != LoadState.loaded || message == null) return;
    _insightsProvider.clearErrorMessage();
    _showError(message);
  }

  void _onTodosChanged() {
    final message = _todosProvider.errorMessage;
    if (_todosProvider.state != LoadState.loaded || message == null) return;
    _todosProvider.clearErrorMessage();
    _showError(message);
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
      appBar: AppBar(
        title: const Text('Insights'),
        actions: const [SignOutButton(), SizedBox(width: 8)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildInsightsSection(insightsProvider),
          if (todosProvider.state == LoadState.loaded) ...[
            const SizedBox(height: 24),
            _buildTodoSection(todosProvider),
          ] else if (todosProvider.state == LoadState.error) ...[
            const SizedBox(height: 24),
            _buildTodoError(todosProvider),
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
            onTargetChanged: (value) => _updateTarget(provider, target.assetClass, value),
          ),
        const SizedBox(height: 16),
        _buildNarrativeCard(data.narrative),
      ],
    );
  }

  /// Saves the target, then refreshes the dashboard's drift banner too —
  /// InsightsProvider refreshes its own drift, but DashboardProvider holds
  /// a separately fetched copy.
  Future<void> _updateTarget(InsightsProvider provider, String assetClass, double value) async {
    final dashboardProvider = context.read<DashboardProvider>();
    final saved = await provider.updateTarget(assetClass, value);
    if (saved) await dashboardProvider.refreshDrift();
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

  Widget _buildTodoError(TodosProvider todosProvider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('To-dos', style: TextStyle(fontWeight: FontWeight.bold)),
        Row(
          children: [
            Expanded(
              child: Text(
                todosProvider.errorMessage ?? "Couldn't load your to-dos",
                key: const ValueKey('todos-error'),
              ),
            ),
            TextButton(onPressed: todosProvider.load, child: const Text('Retry')),
          ],
        ),
      ],
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
