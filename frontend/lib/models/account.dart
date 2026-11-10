/// Mirrors `app.schemas.account.AccountOut`, trimmed to the fields the
/// upload flow needs to let the user pick an existing account.
class AccountSummaryLite {
  final int id;
  final String name;
  final String institution;
  final String accountType;

  AccountSummaryLite({
    required this.id,
    required this.name,
    required this.institution,
    required this.accountType,
  });

  factory AccountSummaryLite.fromJson(Map<String, dynamic> json) => AccountSummaryLite(
        id: json['id'] as int,
        name: json['name'] as String,
        institution: json['institution'] as String,
        accountType: json['account_type'] as String,
      );
}
