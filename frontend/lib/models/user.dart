/// A signed-in user of the app, as returned by the backend's
/// `/auth/google` endpoint.
class AppUser {
  final int id;
  final String email;

  AppUser({required this.id, required this.email});

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id'] as int,
        email: json['email'] as String,
      );
}
