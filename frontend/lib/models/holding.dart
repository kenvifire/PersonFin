import 'dashboard.dart';
import 'extraction.dart';

/// Currencies a holding may be recorded in: every currency the backend can
/// convert ([supportedCurrencies]) plus `'CRYPTO'`, a placeholder currency
/// for crypto assets that gets a locked 1:1 USD rate rather than a real FX
/// lookup. Mirrors `app.schemas.snapshot.ALLOWED_HOLDING_CURRENCIES`.
const List<String> holdingCurrencies = [...supportedCurrencies, 'CRYPTO'];

/// Asset classes a holding may be recorded as. Mirrors
/// `app.services.allocation.normalize_asset_class`'s recognized set.
const List<String> assetClasses = ['equity', 'cash', 'crypto', 'bond'];

/// The review screen's mutable row for one holding: seeded from a
/// [DraftHolding]'s guesses (or created blank for a holding the user adds
/// by hand), then edited freely until it's complete enough to submit.
class EditableHolding {
  String label;
  String? assetClass;
  double? quantity;
  double? value;
  String? currency;
  String country;

  EditableHolding({
    this.label = '',
    this.assetClass,
    this.quantity,
    this.value,
    this.currency,
    this.country = '',
  });

  factory EditableHolding.fromDraft(DraftHolding draft) => EditableHolding(
        label: draft.label,
        assetClass: draft.assetClassGuess,
        quantity: draft.quantity,
        value: draft.value,
        currency: draft.currencyGuess,
        country: draft.countryGuess ?? '',
      );

  /// Whether every field `toHoldingIn` requires is present and valid.
  bool get isComplete =>
      label.isNotEmpty &&
      assetClass != null &&
      value != null &&
      value! >= 0 &&
      currency != null &&
      country.isNotEmpty;

  /// Converts this row to the strict, backend-ready [HoldingIn] shape.
  /// Throws a [StateError] if [isComplete] is false — callers must check
  /// first.
  HoldingIn toHoldingIn() {
    if (!isComplete) {
      throw StateError('Cannot convert an incomplete EditableHolding to HoldingIn');
    }
    return HoldingIn(
      label: label,
      assetClass: assetClass!,
      quantity: quantity,
      value: value!,
      currency: currency!,
      country: country,
    );
  }
}

/// Mirrors `app.schemas.snapshot.HoldingIn`: the strict, validated shape
/// the backend accepts once a holding is ready to be submitted as part of
/// a snapshot.
class HoldingIn {
  final String label;
  final String assetClass;
  final double? quantity;
  final double value;
  final String currency;
  final String country;

  HoldingIn({
    required this.label,
    required this.assetClass,
    required this.quantity,
    required this.value,
    required this.currency,
    required this.country,
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'asset_class': assetClass,
        'quantity': quantity,
        'value': value,
        'currency': currency,
        'country': country,
      };
}
