import 'package:flutter/material.dart';

/// Backend asset-class codes (`app.models.AssetClass`), mapped to the
/// display names the approved mockup shows.
const Map<String, String> assetClassDisplayNames = {
  'equity': 'Equities',
  'cash': 'Cash',
  'bond': 'Fixed income',
  'crypto': 'Crypto',
};

/// One labeled allocation row: the asset class's display name, a
/// horizontal bar filled to [actualPct] with a tick mark at [targetPct],
/// amber when [isDrifted] and green otherwise (matching the mockup), and
/// — for a system-proposed target the user hasn't touched yet — a small
/// "suggested" label so the user can tell a default from one they've
/// already adjusted.
///
/// Tapping the bar opens a dialog to edit the target percentage; on
/// submission [onTargetChanged] is called with the new value (0-100).
/// This editability is a previously-approved design-spec requirement
/// ("system proposes defaults, user edits them") that the brainstormed
/// mockup never surfaced as a UI affordance — it's added here as that
/// requirement, not as a new design decision reopening the mockup.
class AllocationBar extends StatelessWidget {
  final String assetClass;
  final double targetPct;
  final double actualPct;
  final bool isUserSet;
  final bool isDrifted;
  final ValueChanged<double> onTargetChanged;

  const AllocationBar({
    super.key,
    required this.assetClass,
    required this.targetPct,
    required this.actualPct,
    required this.isUserSet,
    required this.isDrifted,
    required this.onTargetChanged,
  });

  String get displayName => assetClassDisplayNames[assetClass] ?? assetClass;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final barColor = isDrifted ? Colors.amber.shade700 : Colors.green.shade700;

    return InkWell(
      onTap: () => _editTarget(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(displayName, style: theme.textTheme.bodyMedium),
                if (!isUserSet) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('suggested', style: theme.textTheme.labelSmall),
                  ),
                ],
                const Spacer(),
                Text('${actualPct.round()}% of ${targetPct.round()}% target'),
              ],
            ),
            const SizedBox(height: 6),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final fillWidth = (actualPct.clamp(0.0, 100.0) / 100) * width;
                final tickLeft = ((targetPct.clamp(0.0, 100.0) / 100) * width - 1)
                    .clamp(0.0, width > 2 ? width - 2 : 0.0);
                return SizedBox(
                  height: 16,
                  child: Stack(
                    children: [
                      Container(
                        width: width,
                        height: 12,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      Container(
                        key: ValueKey('allocation-fill-$assetClass'),
                        width: fillWidth,
                        height: 12,
                        decoration: BoxDecoration(
                          color: barColor,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      Positioned(
                        left: tickLeft,
                        child: Container(width: 2, height: 16, color: theme.colorScheme.onSurface),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // Note: this controller is deliberately left un-disposed. It's local to
  // one dialog's lifetime and the dialog's own closing transition still
  // reads from it after this function's Future resolves (showDialog
  // completes on pop, before the exit animation finishes) — disposing it
  // here throws "used after being disposed" mid-transition. Dart's GC
  // reclaims it once the dialog's route is gone.
  Future<void> _editTarget(BuildContext context) async {
    final controller = TextEditingController(text: targetPct.round().toString());
    final result = await showDialog<double>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Edit $displayName target'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Target %', suffixText: '%'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final parsed = double.tryParse(controller.text);
              if (parsed == null) return;
              Navigator.of(dialogContext).pop(parsed.clamp(0.0, 100.0));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) {
      onTargetChanged(result);
    }
  }
}
