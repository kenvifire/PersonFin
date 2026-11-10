import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/dashboard.dart';

/// Two small summary rows (by country, by asset class) followed by a flat
/// list of accounts with their value and staleness.
///
/// Deliberately flat rather than grouped by country: `DashboardData` only
/// carries aggregate `byCountry` totals, not a per-account country, so
/// grouping accounts by country isn't possible from this shape. The
/// per-account `asOf` is what actually satisfies the staleness-visibility
/// requirement.
class AccountBreakdownList extends StatelessWidget {
  final DashboardData data;

  const AccountBreakdownList({super.key, required this.data});

  String _formatMoney(double value) =>
      NumberFormat.currency(name: data.currency, decimalDigits: 0).format(value);

  String _summaryLine(Map<String, double> byKey) =>
      byKey.entries.map((e) => '${e.key} ${_formatMoney(e.value)}').join(' · ');

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat.yMMMd();
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (data.byCountry.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(_summaryLine(data.byCountry), style: textTheme.bodySmall),
          ),
        if (data.byAssetClass.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(_summaryLine(data.byAssetClass), style: textTheme.bodySmall),
          ),
        const Divider(),
        for (final account in data.accounts)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(account.name),
            subtitle: Text(
              account.asOf == null ? 'no data yet' : 'updated ${dateFormat.format(account.asOf!)}',
            ),
            trailing: Text(_formatMoney(account.value)),
          ),
      ],
    );
  }
}
