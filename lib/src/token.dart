/// A pair of OAuth/JWT tokens managed by the auth strategy.
class TokenPair {
  /// The current access token. Sent as `Authorization: Bearer <access>`.
  final String access;

  /// The current refresh token. Sent to your refresh endpoint.
  final String? refresh;

  /// Optional explicit expiry. If provided, the auth strategy will preemptively
  /// refresh the access token slightly before this moment.
  final DateTime? accessExpiresAt;

  const TokenPair({
    required this.access,
    this.refresh,
    this.accessExpiresAt,
  });

  TokenPair copyWith({
    String? access,
    String? refresh,
    DateTime? accessExpiresAt,
  }) =>
      TokenPair(
        access: access ?? this.access,
        refresh: refresh ?? this.refresh,
        accessExpiresAt: accessExpiresAt ?? this.accessExpiresAt,
      );

  @override
  String toString() =>
      'TokenPair(access: ***${access.length} chars, expiresAt: $accessExpiresAt)';
}

/// Pluggable persistence layer for [TokenPair].
///
/// Implementations include the default in-memory storage (good for tests),
/// flutter_secure_storage-backed storage (recommended for production), and
/// any custom implementation that suits the host app.
abstract interface class TokenStorage {
  Future<TokenPair?> read();
  Future<void> write(TokenPair pair);
  Future<void> clear();
}

/// Identifier for one of multiple concurrent identities (multi-account auth).
///
/// Used as `Options().withAccount(AccountId('alice'))`. The pipeline looks
/// up that account's tokens in the [AccountTokenStorage] and injects them on
/// the request.
extension type const AccountId(String value) {}

/// Token persistence for several accounts at once, keyed by [AccountId].
///
/// Serves requests sent with `Options().withAccount(id)`. Requests without
/// an account keep using the pipeline's [TokenStorage].
abstract interface class AccountTokenStorage {
  Future<TokenPair?> read(AccountId account);
  Future<void> write(AccountId account, TokenPair pair);
  Future<void> clear(AccountId account);
}
