import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../models/snapshot.dart';
import '../providers/account_detail_provider.dart';

/// Shown after tapping an account in the dashboard's breakdown list: the
/// account's current holdings (its most recent snapshot), its full
/// snapshot history, and rename/delete actions.
class AccountDetailScreen extends StatefulWidget {
  const AccountDetailScreen({super.key});

  @override
  State<AccountDetailScreen> createState() => _AccountDetailScreenState();
}

class _AccountDetailScreenState extends State<AccountDetailScreen> {
  bool _handledDeleted = false;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AccountDetailProvider>();
    _maybeHandleDeleted(provider);

    return Scaffold(
      appBar: AppBar(
        title: Text(provider.account?.name ?? 'Account'),
        actions: provider.state == AccountDetailState.loaded
            ? [
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'Edit account',
                  onPressed: () => _editAccount(provider),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete account',
                  onPressed: () => _confirmDelete(provider),
                ),
              ]
            : null,
      ),
      body: _buildBody(context, provider),
    );
  }

  /// Pops back once the account is actually deleted — scheduled via a
  /// post-frame callback since navigating mid-build isn't allowed.
  void _maybeHandleDeleted(AccountDetailProvider provider) {
    if (_handledDeleted || !provider.deleted) return;
    _handledDeleted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.pop();
    });
  }

  Widget _buildBody(BuildContext context, AccountDetailProvider provider) {
    switch (provider.state) {
      case AccountDetailState.loading:
        return const Center(child: CircularProgressIndicator());
      case AccountDetailState.error:
        return Center(
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
              ElevatedButton(
                onPressed: () => provider.load(provider.accountId!),
                child: const Text('Retry'),
              ),
            ],
          ),
        );
      case AccountDetailState.loaded:
        return _buildLoaded(context, provider);
    }
  }

  Widget _buildLoaded(BuildContext context, AccountDetailProvider provider) {
    final account = provider.account!;
    final snapshots = provider.snapshots;
    final latest = snapshots.isEmpty ? null : snapshots.first;
    final history = snapshots.length > 1 ? snapshots.sublist(1) : const <SnapshotOut>[];
    final textTheme = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('${account.institution} · ${account.accountType}', style: textTheme.bodySmall),
        const SizedBox(height: 16),
        if (provider.errorMessage != null) ...[
          Text(provider.errorMessage!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 16),
        ],
        const Text('Current holdings', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (latest == null)
          const Text('No snapshots yet — upload a screenshot to add one.')
        else ...[
          Text(
            'As of ${DateFormat.yMMMd().format(latest.takenAt)}',
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (final holding in latest.holdings) _buildHoldingTile(holding),
        ],
        if (history.isNotEmpty) ...[
          const SizedBox(height: 24),
          const Text('History', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final snapshot in history) _buildHistoryTile(snapshot),
        ],
      ],
    );
  }

  Widget _buildHoldingTile(HoldingOut holding) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(holding.label),
      subtitle: Text('${holding.assetClass} · ${holding.country}'),
      trailing: Text(_formatMoney(holding.value, holding.currency)),
    );
  }

  Widget _buildHistoryTile(SnapshotOut snapshot) {
    final totalUsd = snapshot.holdings.fold<double>(0, (sum, h) => sum + h.valueUsd);
    return ExpansionTile(
      title: Text(DateFormat.yMMMd().format(snapshot.takenAt)),
      subtitle: Text(
        '${snapshot.holdings.length} '
        '${snapshot.holdings.length == 1 ? 'holding' : 'holdings'} · '
        '${_formatMoney(totalUsd, 'USD')}',
      ),
      children: [for (final holding in snapshot.holdings) _buildHoldingTile(holding)],
    );
  }

  String _formatMoney(double value, String currency) =>
      NumberFormat.currency(name: currency, decimalDigits: 0).format(value);

  Future<void> _editAccount(AccountDetailProvider provider) async {
    final result = await showDialog<({String name, String institution, String accountType})>(
      context: context,
      builder: (_) => _EditAccountDialog(account: provider.account!),
    );
    if (result == null) return;

    final ok = await provider.rename(
      name: result.name,
      institution: result.institution,
      accountType: result.accountType,
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: ${provider.errorMessage}')),
      );
    }
  }

  Future<void> _confirmDelete(AccountDetailProvider provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          "This can't be undone. An account with snapshot history can't be deleted.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await provider.delete();
    if (!mounted) return;
    if (!provider.deleted && provider.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(provider.errorMessage!)));
    }
  }
}

class _EditAccountDialog extends StatefulWidget {
  final AccountSummaryLite account;

  const _EditAccountDialog({required this.account});

  @override
  State<_EditAccountDialog> createState() => _EditAccountDialogState();
}

class _EditAccountDialogState extends State<_EditAccountDialog> {
  late final _name = TextEditingController(text: widget.account.name);
  late final _institution = TextEditingController(text: widget.account.institution);
  late final _accountType = TextEditingController(text: widget.account.accountType);

  bool get _isValid =>
      _name.text.trim().isNotEmpty &&
      _institution.text.trim().isNotEmpty &&
      _accountType.text.trim().isNotEmpty;

  @override
  void dispose() {
    _name.dispose();
    _institution.dispose();
    _accountType.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit account'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Account name'),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: _institution,
            decoration: const InputDecoration(labelText: 'Institution'),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: _accountType,
            decoration: const InputDecoration(labelText: 'Account type'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _isValid
              ? () => Navigator.of(context).pop((
                    name: _name.text.trim(),
                    institution: _institution.text.trim(),
                    accountType: _accountType.text.trim(),
                  ))
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
