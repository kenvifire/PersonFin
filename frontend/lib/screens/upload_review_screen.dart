import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/holding.dart';
import '../providers/dashboard_provider.dart';
import '../providers/upload_flow_provider.dart';

/// Wraps `image_picker`'s `ImagePicker` behind an interface the screen can
/// take as a constructor parameter, so widget tests can fake it instead of
/// touching the real SDK (which isn't available in the test environment).
/// `pickImage` returns `null` when the user cancels the picker.
abstract class ImagePickerService {
  Future<({List<int> bytes, String filename, String mimeType})?> pickImage();
}

/// Real implementation backed by `image_picker`. `ImageSource.camera` adds
/// the browser's `capture` attribute: mobile browsers honor it and open the
/// camera directly (matching "snap a screenshot"), while desktop browsers
/// ignore it and fall back to a normal file dialog — so one source works
/// for both.
class RealImagePickerService implements ImagePickerService {
  @override
  Future<({List<int> bytes, String filename, String mimeType})?> pickImage() async {
    final file = await ImagePicker().pickImage(source: ImageSource.camera);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    return (bytes: bytes, filename: file.name, mimeType: file.mimeType ?? 'image/jpeg');
  }
}

/// The screen shown after tapping the dashboard's camera FAB: picks a
/// screenshot, runs it through [UploadFlowProvider]'s upload-then-extract
/// flow, and lets the user review/edit the extracted holdings before
/// confirming them into a real snapshot (or discarding the upload).
class UploadReviewScreen extends StatefulWidget {
  final ImagePickerService imagePickerService;

  UploadReviewScreen({super.key, ImagePickerService? imagePickerService})
      : imagePickerService = imagePickerService ?? RealImagePickerService();

  @override
  State<UploadReviewScreen> createState() => _UploadReviewScreenState();
}

class _UploadReviewScreenState extends State<UploadReviewScreen> {
  int? _selectedAccountId;
  bool _useNewAccount = false;
  bool _accountSelectionInitialized = false;
  bool _handledTerminalState = false;

  final _newAccountName = TextEditingController();
  final _newAccountInstitution = TextEditingController();
  final _newAccountType = TextEditingController();

  @override
  void initState() {
    super.initState();
    final provider = context.read<UploadFlowProvider>();
    provider.loadAccounts();
    if (provider.state == UploadFlowState.picking) {
      _pickAndStartUpload(provider);
    }
  }

  Future<void> _pickAndStartUpload(UploadFlowProvider provider) async {
    final picked = await widget.imagePickerService.pickImage();
    if (!mounted) return;
    if (picked == null) {
      context.pop();
      return;
    }
    await provider.startUpload(
      bytes: picked.bytes,
      filename: picked.filename,
      mimeType: picked.mimeType,
    );
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
      WidgetsBinding.instance.addPostFrameCallback((_) async {
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
        const SizedBox(height: 8),
        for (final holding in provider.holdings) _buildHoldingRow(provider, holding),
        TextButton(
          onPressed: () => setState(() => provider.holdings.add(EditableHolding())),
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
    return Card(
      key: ValueKey(holding),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                onPressed: () => setState(() => provider.holdings.remove(holding)),
                child: const Text('Remove'),
              ),
            ),
          ],
        ),
      ),
    );
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
