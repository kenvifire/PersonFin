import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// The dashboard's headline figure: current net worth formatted in the
/// currently selected display currency.
class NetWorthHero extends StatelessWidget {
  final double netWorth;
  final String currency;

  const NetWorthHero({super.key, required this.netWorth, required this.currency});

  @override
  Widget build(BuildContext context) {
    final formatted = NumberFormat.currency(name: currency).format(netWorth);
    return Text(
      formatted,
      style: Theme.of(context).textTheme.displaySmall,
    );
  }
}
