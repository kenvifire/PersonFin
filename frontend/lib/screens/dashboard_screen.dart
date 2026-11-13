import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/dashboard.dart';
import '../providers/dashboard_provider.dart';
import '../services/image_picker_service.dart';
import '../widgets/account_breakdown_list.dart';
import '../widgets/currency_switcher.dart';
import '../widgets/drift_alert_banner.dart';
import '../widgets/net_worth_hero.dart';
import '../widgets/sign_out_button.dart';
import '../widgets/trend_sparkline.dart';

/// The app's landing screen: a hero net-worth figure, a trend sparkline, a
/// drift alert when allocations are off target, and a per-account
/// breakdown — all in the currently selected display currency.
class DashboardScreen extends StatelessWidget {
  final ImagePickerService imagePickerService;

  DashboardScreen({super.key, ImagePickerService? imagePickerService})
      : imagePickerService = imagePickerService ?? RealImagePickerService();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DashboardProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          CurrencySwitcher(currency: provider.currency, onChanged: provider.setCurrency),
          const SignOutButton(),
          const SizedBox(width: 8),
        ],
      ),
      body: _buildBody(context, provider),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _pickAndReview(context),
        child: const Icon(Icons.camera_alt),
      ),
    );
  }

  /// Picks an image, synchronously (from the engine's perspective) in
  /// response to the FAB tap, and only then navigates to `/upload` with it
  /// — see `RealImagePickerService`'s doc comment for why the picker must
  /// be called from here rather than from the pushed screen's `initState`.
  Future<void> _pickAndReview(BuildContext context) async {
    final router = GoRouter.of(context);
    final picked = await imagePickerService.pickImage();
    if (!context.mounted) return;
    if (picked != null) {
      router.push('/upload', extra: picked);
    }
  }

  Widget _buildBody(BuildContext context, DashboardProvider provider) {
    switch (provider.state) {
      case LoadState.loading:
        return const Center(child: CircularProgressIndicator());
      case LoadState.error:
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
              ElevatedButton(onPressed: provider.load, child: const Text('Retry')),
            ],
          ),
        );
      case LoadState.loaded:
        final data = provider.data!;
        // Review Focus: zero net worth / no holdings yet must render a
        // deliberate empty state, not a zero-filled chart or blank screen.
        if (data.netWorth == 0) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No accounts yet — tap the camera button to add your first screenshot',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return _buildLoaded(context, provider, data);
    }
  }

  Widget _buildLoaded(BuildContext context, DashboardProvider provider, DashboardData data) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(child: NetWorthHero(netWorth: data.netWorth, currency: provider.currency)),
        const SizedBox(height: 16),
        TrendSparkline(trend: data.trend),
        if (provider.drift.isNotEmpty) ...[
          const SizedBox(height: 16),
          DriftAlertBanner(drift: provider.drift, onTap: () => context.go('/insights')),
        ],
        const SizedBox(height: 16),
        AccountBreakdownList(data: data),
      ],
    );
  }
}
