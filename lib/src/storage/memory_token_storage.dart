import '../token.dart';

/// Simple in-memory implementation of TokenStorage.
///
/// Suitable for testing and development. For production, use a persistent
/// storage backed by [flutter_secure_storage] or similar.
class MemoryTokenStorage implements TokenStorage {
  TokenPair? _pair;

  @override
  Future<TokenPair?> read() async => _pair;

  @override
  Future<void> write(TokenPair pair) async {
    _pair = pair;
  }

  @override
  Future<void> clear() async {
    _pair = null;
  }
}

/// Simple in-memory implementation of [AccountTokenStorage].
///
/// Suitable for testing and development. For production, persist the tokens
/// (e.g. with flutter_secure_storage).
class MemoryAccountTokenStorage implements AccountTokenStorage {
  final Map<AccountId, TokenPair> _pairs = {};

  @override
  Future<TokenPair?> read(AccountId account) async => _pairs[account];

  @override
  Future<void> write(AccountId account, TokenPair pair) async {
    _pairs[account] = pair;
  }

  @override
  Future<void> clear(AccountId account) async {
    _pairs.remove(account);
  }
}
