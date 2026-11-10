import 'package:flutter/material.dart';

import '../models/drift_flag.dart';

/// Shown on the dashboard only when [drift] is non-empty. Tapping it is
/// wired by the caller (`DashboardScreen`) to navigate to the insights
/// screen, where the underlying allocation drift can be reviewed.
class DriftAlertBanner extends StatelessWidget {
  final List<DriftFlag> drift;
  final VoidCallback onTap;

  const DriftAlertBanner({super.key, required this.drift, required this.onTap});

  String get _message {
    if (drift.length == 1) {
      final flag = drift.first;
      final direction = flag.deltaPct > 0 ? 'above' : 'below';
      return '${flag.assetClass} is ${flag.deltaPct.abs().round()}% $direction target';
    }
    return '${drift.length} asset classes are off target';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.warning_amber, color: colors.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_message, style: TextStyle(color: colors.onErrorContainer)),
              ),
              Icon(Icons.chevron_right, color: colors.onErrorContainer),
            ],
          ),
        ),
      ),
    );
  }
}
