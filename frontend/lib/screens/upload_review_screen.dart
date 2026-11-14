import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/holding.dart';
import '../providers/dashboard_provider.dart';
import '../providers/insights_provider.dart';
import '../providers/upload_flow_provider.dart';

/// The screen shown after the dashboard's camera FAB has already picked a
/// screenshot: runs [picked] through [UploadFlowProvider]'s upload-then-
/// extract flow, and lets the user review/edit the extracted holdings
/// before confirming them into a real snapshot (or discarding the upload).
///
/// The image is picked by the caller (see `DashboardScreen`), not by this
/// screen, and passed in via [picked] — picking it here instead, after the
/// navigation to this screen, would call the platform image picker outside
/// the original tap's user-gesture context, which browsers (iOS WebKit in
/// particular) silently refuse to honor (see `RealImagePickerService`).
class UploadReviewScreen extends StatefulWidget {
  final ({List<int> bytes, String filename, String mimeType})? picked;

  const UploadReviewScreen({super.key, this.picked});

  @override
  State<UploadReviewScreen> createState() => _UploadReviewScreenState();
}

/// Holdings lists at or below this length always start fully expanded
/// (today's behavior) — only a screenshot with several holdings at once
/// (e.g. a multi-position brokerage statement) gets the collapsed-summary
/// treatment, and only for the ones extraction already got right.
const int _manyHoldingsThreshold = 3;

class _UploadReviewScreenState extends State<UploadReviewScreen> {
  int? _selectedAccountId;
  bool _useNewAccount = false;
  bool _accountSelectionInitialized = false;
  bool _newAccountFieldsInitialized = false;
  bool _holdingsExpansionInitialized = false;
  bool _handledTerminalState = false;

  /// Holdings currently showing their editable fields; identity-keyed,
  /// since [EditableHolding] has no custom equality. Seeded once (see
  /// [_initializeHoldingsExpansionOnce]) and then only ever changed by the
  /// user tapping a row, or by adding/removing a holding.
  final Set<EditableHolding> _expandedHoldings = {};

  final _newAccountName = TextEditingController();
  final _newAccountInstitution = TextEditingController();
  final _newAccountType = TextEditingController();

  @override
  void initState() {
    super.initState();
    final provider = context.read<UploadFlowProvider>();
    provider.loadAccounts();
    if (provider.state == UploadFlowState.picking && widget.picked != null) {
      // Deferred a tick: notifyListeners() inside startUpload() would
      // otherwise fire synchronously while this very widget is still being
      // built (initState runs mid-mount), which Flutter disallows.
      Future.microtask(() => provider.startUpload(
            bytes: widget.picked!.bytes,
            filename: widget.picked!.filename,
            mimeType: widget.picked!.mimeType,
          ));
    }
  }

  @override
  void dispose() {
    _newAccountName.dispose();
    _newAccountInstitution.dispose();
    _newAccountType.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<UploadFlowProvider>();

    if (!_accountSelectionInitialized &&
        provider.state == UploadFlowState.ready &&
        provider.suggestedAccountId != null) {
      _selectedAccountId = provider.suggestedAccountId;
      _accountSelectionInitialized = true;
    }

    if (!_newAccountFieldsInitialized && provider.state == UploadFlowState.ready) {
      // Pre-filled from the vision extraction's own guesses, so the user
      // doesn't have to retype a broker name that's already visible in
      // the screenshot just because they're entering a brand-new account.
      _newAccountName.text = provider.accountLabel;
      _newAccountInstitution.text = provider.institution;
      _newAccountType.text = provider.accountTypeGuess;
      _newAccountFieldsInitialized = true;
    }

    if (!_holdingsExpansionInitialized && provider.state == UploadFlowState.ready) {
      _initializeHoldingsExpansionOnce(provider.holdings);
      _holdingsExpansionInitialized = true;
    }

    _maybeHandleTerminalState(provider);

    return Scaffold(
      appBar: AppBar(title: const Text('Review Upload')),
      body: _buildBody(context, provider),
    );
  }

  /// Reacts once to the two states that end the screen's life: successful
  /// confirmation/discard ([UploadFlowState.confirmed]) and the Review
  /// Focus 409 race ([UploadFlowState.alreadyFinalized]). Both pop back to
  /// `/dashboard`; scheduled via a post-frame callback since navigating
  /// (and showDialog) must not happen mid-build.
  void _maybeHandleTerminalState(UploadFlowProvider provider) {
    if (_handledTerminalState) return;

    if (provider.state == UploadFlowState.confirmed) {
      _handledTerminalState = true;
      final dashboardProvider = context.read<DashboardProvider>();
      final insightsProvider = context.read<InsightsProvider>();
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        // New holdings change allocation/drift/narrative too. Not awaited:
        // the insights call includes the (slow) LLM narrative, and the
        // user is returning to the dashboard, not the insights tab.
        unawaited(insightsProvider.load());
        await dashboardProvider.load();
        if (!mounted) return;
        context.pop();
      });
    } else if (provider.state == UploadFlowState.alreadyFinalized) {
      _handledTerminalState = true;
      final message = provider.errorMessage ?? 'Upload is already finalized.';
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Upload already finalized'),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        if (!mounted) return;
        context.pop();
      });
    }
  }

  /// With few holdings, every row starts expanded (today's behavior). With
  /// more than [_manyHoldingsThreshold], a row extraction already filled in
  /// completely starts collapsed to a summary line — the ones still
  /// missing something start expanded, since those are what need the
  /// user's attention.
  void _initializeHoldingsExpansionOnce(List<EditableHolding> holdings) {
    if (holdings.length <= _manyHoldingsThreshold) {
      _expandedHoldings.addAll(holdings);
    } else {
      _expandedHoldings.addAll(holdings.where((holding) => !holding.isComplete));
    }
  }

  Widget _buildBody(BuildContext context, UploadFlowProvider provider) {
    switch (provider.state) {
      case UploadFlowState.picking:
      case UploadFlowState.uploading:
      case UploadFlowState.extracting:
        return _buildSpinner('Reading account details…');
      case UploadFlowState.confirming:
        return _buildSpinner('Saving…');
      case UploadFlowState.ready:
      case UploadFlowState.failed:
        return _buildForm(context, provider);
      case UploadFlowState.confirmed:
      case UploadFlowState.alreadyFinalized:
        // A post-frame callback (scheduled in build()) handles navigation;
        // this is only ever visible for the single frame before it fires.
        return _buildSpinner(null);
      case UploadFlowState.error:
        return _buildError(context, provider);
    }
  }

  Widget _buildSpinner(String? label) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (label != null) ...[
            const SizedBox(height: 16),
            Text(label),
          ],
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context, UploadFlowProvider provider) {
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
            onPressed: () => provider.discard(),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
  }

  Widget _buildForm(BuildContext context, UploadFlowProvider provider) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (provider.state == UploadFlowState.failed && provider.errorMessage != null) ...[
          Text(
            provider.errorMessage!,
            style: const TextStyle(color: Colors.red),
          ),
          const SizedBox(height: 16),
        ],
        _buildDateField(context, provider),
        const SizedBox(height: 16),
        const Text('Holdings', style: TextStyle(fontWeight: FontWeight.bold)),
        if (provider.institution.isNotEmpty || provider.accountLabel.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            [provider.institution, provider.accountLabel].where((s) => s.isNotEmpty).join(' · '),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
        const SizedBox(height: 8),
        for (final holding in provider.holdings) _buildHoldingRow(provider, holding),
        TextButton(
          onPressed: () => setState(() {
            final added = EditableHolding();
            provider.holdings.add(added);
            _expandedHoldings.add(added);
          }),
          child: const Text('+ Add holding'),
        ),
        const SizedBox(height: 16),
        _buildAccountSection(provider),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: ElevatedButton(
                onPressed: _isConfirmEnabled(provider) ? () => _onConfirm(provider) : null,
                child: const Text('Confirm'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: OutlinedButton(
                onPressed: () => provider.discard(),
                child: const Text('Discard'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDateField(BuildContext context, UploadFlowProvider provider) {
    return Row(
      children: [
        Expanded(child: Text('Taken on: ${DateFormat('yyyy-MM-dd').format(provider.takenAt)}')),
        TextButton(
          onPressed: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: provider.takenAt,
              firstDate: DateTime(2000),
              lastDate: DateTime.now(),
            );
            if (picked != null) {
              setState(() => provider.takenAt = picked);
            }
          },
          child: const Text('Change'),
        ),
      ],
    );
  }

  Widget _buildHoldingRow(UploadFlowProvider provider, EditableHolding holding) {
    final expanded = _expandedHoldings.contains(holding);
    return Card(
      key: ValueKey(holding),
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() {
              if (expanded) {
                _expandedHoldings.remove(holding);
              } else {
                _expandedHoldings.add(holding);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    holding.isComplete ? Icons.check_circle : Icons.error_outline,
                    color: holding.isComplete ? Colors.green : Colors.orange,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  // The label/summary live in the editable fields below once
                  // expanded — shown here too would duplicate that text.
                  if (!expanded)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            holding.label.isEmpty ? '(unlabeled)' : holding.label,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            _holdingSummary(holding),
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                    )
                  else
                    const Expanded(child: SizedBox.shrink()),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    initialValue: holding.label,
                    decoration: const InputDecoration(labelText: 'Label'),
                    onChanged: (value) => setState(() => holding.label = value),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: holding.assetClass,
                    decoration: const InputDecoration(labelText: 'Asset class'),
                    items: [
                      for (final assetClass in assetClasses)
                        DropdownMenuItem(value: assetClass, child: Text(assetClass)),
                    ],
                    onChanged: (value) => setState(() => holding.assetClass = value),
                  ),
                  TextFormField(
                    initialValue: holding.quantity?.toString() ?? '',
                    decoration: const InputDecoration(labelText: 'Quantity (optional)'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (value) => setState(() => holding.quantity = double.tryParse(value)),
                  ),
                  TextFormField(
                    initialValue: holding.value?.toString() ?? '',
                    decoration: const InputDecoration(labelText: 'Value'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (value) => setState(() => holding.value = double.tryParse(value)),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: holding.currency,
                    decoration: const InputDecoration(labelText: 'Currency'),
                    items: [
                      for (final currency in holdingCurrencies)
                        DropdownMenuItem(value: currency, child: Text(currency)),
                    ],
                    onChanged: (value) => setState(() => holding.currency = value),
                  ),
                  TextFormField(
                    initialValue: holding.country,
                    decoration: const InputDecoration(labelText: 'Country'),
                    onChanged: (value) => setState(() => holding.country = value),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => setState(() {
                        provider.holdings.remove(holding);
                        _expandedHoldings.remove(holding);
                      }),
                      child: const Text('Remove'),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// One-line summary shown on a collapsed holding row.
  String _holdingSummary(EditableHolding holding) {
    final parts = <String>[
      if (holding.quantity != null) '${holding.quantity} units',
      if (holding.value != null) holding.value!.toStringAsFixed(2),
      if (holding.currency != null) holding.currency!,
    ];
    return parts.isEmpty ? 'Tap to fill in' : parts.join(' · ');
  }

  Widget _buildAccountSection(UploadFlowProvider provider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Account', style: TextStyle(fontWeight: FontWeight.bold)),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('+ New account'),
          value: _useNewAccount,
          onChanged: (value) => setState(() {
            _useNewAccount = value ?? false;
            if (_useNewAccount) _selectedAccountId = null;
          }),
        ),
        if (!_useNewAccount)
          DropdownButtonFormField<int>(
            initialValue: _selectedAccountId,
            decoration: const InputDecoration(labelText: 'Select account'),
            items: [
              for (final account in provider.accounts)
                DropdownMenuItem(value: account.id, child: Text(account.name)),
            ],
            onChanged: (value) => setState(() => _selectedAccountId = value),
          )
        else ...[
          TextFormField(
            controller: _newAccountName,
            decoration: const InputDecoration(labelText: 'Account name'),
            onChanged: (_) => setState(() {}),
          ),
          TextFormField(
            controller: _newAccountInstitution,
            decoration: const InputDecoration(labelText: 'Institution'),
            onChanged: (_) => setState(() {}),
          ),
          TextFormField(
            controller: _newAccountType,
            decoration: const InputDecoration(labelText: 'Account type'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ],
    );
  }

  bool _isConfirmEnabled(UploadFlowProvider provider) {
    if (provider.holdings.isEmpty) return false;
    if (!provider.holdings.every((holding) => holding.isComplete)) return false;
    if (_useNewAccount) {
      return _newAccountName.text.trim().isNotEmpty &&
          _newAccountInstitution.text.trim().isNotEmpty &&
          _newAccountType.text.trim().isNotEmpty;
    }
    return _selectedAccountId != null;
  }

  Future<void> _onConfirm(UploadFlowProvider provider) async {
    await _confirm(provider);
    // A non-409 failure returns the provider to `ready` (form intact) with
    // errorMessage set; surface it so the user knows to fix and retry.
    if (!mounted) return;
    if (provider.state == UploadFlowState.ready && provider.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: ${provider.errorMessage}')),
      );
    }
  }

  Future<void> _confirm(UploadFlowProvider provider) async {
    if (_useNewAccount) {
      await provider.confirm(
        accountId: null,
        newAccount: (
          name: _newAccountName.text.trim(),
          institution: _newAccountInstitution.text.trim(),
          accountType: _newAccountType.text.trim(),
        ),
      );
    } else {
      await provider.confirm(accountId: _selectedAccountId, newAccount: null);
    }
  }
}
