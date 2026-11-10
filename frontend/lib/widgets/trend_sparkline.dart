import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/dashboard.dart';

/// A plain net-worth-over-time sparkline: no axis labels, titles, or grid —
/// just the shape of the trend, matching the approved mockup.
class TrendSparkline extends StatelessWidget {
  final List<TrendPoint> trend;

  const TrendSparkline({super.key, required this.trend});

  @override
  Widget build(BuildContext context) {
    final spots = [
      for (var i = 0; i < trend.length; i++) FlSpot(i.toDouble(), trend[i].netWorth),
    ];

    if (spots.isEmpty) {
      // Not enough history yet to draw a line; the hero number alone still
      // conveys current net worth, so just reserve the space quietly.
      return const SizedBox(height: 80);
    }

    return SizedBox(
      height: 80,
      child: LineChart(
        LineChartData(
          titlesData: const FlTitlesData(show: false),
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          lineTouchData: const LineTouchData(enabled: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              dotData: const FlDotData(show: false),
            ),
          ],
        ),
      ),
    );
  }
}
