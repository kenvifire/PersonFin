/// Mirrors `app.schemas.extraction.DraftHolding`: one vision-extracted
/// holding guess, read-only and deliberately loose — nothing here is
/// validated yet. The review screen seeds an [EditableHolding] from this.
class DraftHolding {
  final String label;
  final String? assetClassGuess;
  final double? quantity;
  final double? value;
  final String? currencyGuess;
  final String? countryGuess;

  DraftHolding({
    required this.label,
    required this.assetClassGuess,
    required this.quantity,
    required this.value,
    required this.currencyGuess,
    required this.countryGuess,
  });

  factory DraftHolding.fromJson(Map<String, dynamic> json) => DraftHolding(
        label: json['label'] as String,
        assetClassGuess: json['asset_class_guess'] as String?,
        quantity: (json['quantity'] as num?)?.toDouble(),
        value: (json['value'] as num?)?.toDouble(),
        currencyGuess: json['currency_guess'] as String?,
        countryGuess: json['country_guess'] as String?,
      );
}

/// Mirrors `app.schemas.extraction.ExtractionResult`: the full vision
/// extraction result for one uploaded screenshot.
class ExtractionResult {
  final String? institution;
  final String? accountLabel;
  final String? accountTypeGuess;
  final DateTime? takenAtGuess;
  final List<DraftHolding> holdings;

  ExtractionResult({
    required this.institution,
    required this.accountLabel,
    required this.accountTypeGuess,
    required this.takenAtGuess,
    required this.holdings,
  });

  factory ExtractionResult.fromJson(Map<String, dynamic> json) => ExtractionResult(
        institution: json['institution'] as String?,
        accountLabel: json['account_label'] as String?,
        accountTypeGuess: json['account_type_guess'] as String?,
        takenAtGuess:
            json['taken_at_guess'] == null ? null : DateTime.parse(json['taken_at_guess'] as String),
        holdings: (json['holdings'] as List)
            .map((entry) => DraftHolding.fromJson(entry as Map<String, dynamic>))
            .toList(),
      );
}
