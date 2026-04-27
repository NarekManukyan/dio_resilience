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
