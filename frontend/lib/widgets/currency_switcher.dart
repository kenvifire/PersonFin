import 'package:flutter/material.dart';

import '../models/dashboard.dart';

/// Dropdown listing [supportedCurrencies]; selecting a new one invokes
/// [onChanged] (wired by `DashboardScreen` to `DashboardProvider.setCurrency`).
class CurrencySwitcher extends StatelessWidget {
  final String currency;
  final ValueChanged<String> onChanged;

  const CurrencySwitcher({super.key, required this.currency, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButton<String>(
      value: currency,
      underline: const SizedBox.shrink(),
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
      items: [
        for (final code in supportedCurrencies) DropdownMenuItem(value: code, child: Text(code)),
      ],
    );
  }
}
