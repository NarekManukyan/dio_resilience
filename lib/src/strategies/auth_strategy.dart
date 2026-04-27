import 'dart:async';

import 'package:dio/dio.dart';

import '../exceptions.dart';
import '../options_extension.dart';
import '../overrides.dart';
import '../pipeline_context.dart';
import '../strategy.dart';
import '../token.dart';

/// Auth state enum for [AuthStrategy.authStateStream].
enum AuthState {
  /// No authentication activity; initial state or idle.
  idle,

  /// User is authenticated with a valid token.
  authenticated,

  /// Token refresh is currently in progress.
  refreshing,

  /// No valid token; user must re-authenticate.
  unauthenticated,

  /// User was forcibly logged out (e.g., via logout method).
  forcedLogout,
}

/// Signature for a user-supplied function that refreshes the token.
///
/// Called with the current [TokenPair] (or null if no token exists).
/// Should return a new [TokenPair], or throw an exception, or return null
/// to signal that refresh failed.
typedef RefreshToken = Future<TokenPair?> Function(TokenPair? current);

/// Predicate to detect whether a request is the refresh endpoint itself.
///
/// Return true if this request should skip auth handling (not inject token,
/// not trigger refresh on 401).
typedef IsRefreshRequest = bool Function(RequestOptions request);

/// Strategy that manages OAuth/JWT token injection and refresh.
///
/// Injects the access token as `Authorization: Bearer <token>` (or custom
/// scheme) on each request. When a 401 or [shouldRefresh] match occurs,
/// triggers a refresh via the user-supplied [refreshToken] callback.
/// Implements single-flight refresh: concurrent 401s share a single in-flight
/// refresh operation via a [Completer].
///
/// Honors [AuthOverride.disabled] and [AuthOverride.account] per-request.
/// Emits [AuthState] changes via [authStateStream].
class AuthStrategy extends ResilienceStrategy {
  /// Primary token storage.
  final TokenStorage storage;

  /// Optional storage for multi-account support.
  final TokenStorage? multiAccountStorage;

  /// Callback to refresh the token.
  final RefreshToken refreshToken;

  /// Authorization scheme (default 'Bearer').
  final String scheme;

  /// Preemptive refresh window: if [TokenPair.accessExpiresAt] is within
  /// this duration of now, trigger refresh before allowing the request.
  final Duration preemptiveRefreshWindow;

  /// Optional predicate to detect refresh endpoint (skip auth for it).
  /// If not provided, looks for [Options.extra] flag instead.
  final IsRefreshRequest? isRefreshRequest;

  /// Optional predicate to determine if a non-401 error should trigger
  /// refresh. Return true to attempt refresh; false otherwise.
  final bool Function(DioException error)? shouldRefresh;

  /// Callback fired when refresh fails terminally. Typically used to route
  /// the user to a login screen.
  final void Function()? onRefreshFailed;

  /// Callback fired when a user is detected as unauthenticated.
  final void Function()? onUnauthenticated;

  final StreamController<AuthState> _authStateController;
  Completer<void>? _refreshInFlight;

  @override
  String get name => 'auth';

  /// Stream of auth state changes. Emits whenever the auth state transitions.
  Stream<AuthState> get authStateStream => _authStateController.stream;

  AuthStrategy({
    required this.storage,
    required this.refreshToken,
    this.multiAccountStorage,
    this.scheme = 'Bearer',
    this.preemptiveRefreshWindow = const Duration(minutes: 1),
    this.isRefreshRequest,
    this.shouldRefresh,
    this.onRefreshFailed,
    this.onUnauthenticated,
  }) : _authStateController = StreamController<AuthState>.broadcast();

  /// Clean up the stream controller.
  void dispose() {
    _authStateController.close();
  }

  /// Manually log out the user (clears storage and emits forcedLogout).
  Future<void> logout({AccountId? accountId}) async {
    if (accountId != null && multiAccountStorage != null) {
      await multiAccountStorage!.clear();
    } else {
      await storage.clear();
    }
    _emitAuthState(AuthState.forcedLogout);
  }

  @override
  Future<void> onRequest(PipelineContext ctx) async {
    final overrides = overridesFor(ctx.request);
    final authOverride = overrides?.auth;

    // Honor AuthOverride.disabled
    if (authOverride is AuthDisabled) {
      return;
    }

    // Check if this is a refresh request (skip auth for it)
    if (_isRefreshRequest(ctx.request)) {
      return;
    }

    // Determine which storage to read from
    final AccountId? account = switch (authOverride) {
      AuthAccount aa => aa.account,
      _ => null,
    };

    final effectiveStorage = account != null && multiAccountStorage != null
        ? multiAccountStorage!
        : storage;

    // Read token
    final pair = await effectiveStorage.read();
    if (pair == null) {
      _emitAuthState(AuthState.unauthenticated);
      onUnauthenticated?.call();
      return;
    }

    // Check if preemptive refresh is needed
    if (pair.accessExpiresAt != null) {
      final now = DateTime.now();
      final expiresAt = pair.accessExpiresAt!;
      if (expiresAt.isBefore(now.add(preemptiveRefreshWindow)) &&
          expiresAt.isAfter(now)) {
        // Preemptively refresh
        await _doRefresh(ctx, pair, effectiveStorage);
        // If refresh was successful, re-read the new token
        final newPair = await effectiveStorage.read();
        if (newPair != null) {
          _injectAuthHeader(ctx.request, newPair);
        }
        return;
      }
    }

    // Inject the authorization header
    _injectAuthHeader(ctx.request, pair);
    _emitAuthState(AuthState.authenticated);
  }

  @override
  Future<void> onResponse(
    PipelineContext ctx,
    Response<dynamic> response,
  ) async {
    // No-op: response succeeded with current token.
  }

  @override
  Future<StrategyDecision?> onError(
    PipelineContext ctx,
    DioException error,
  ) async {
    final overrides = overridesFor(ctx.request);
    final authOverride = overrides?.auth;

    // Honor AuthOverride.disabled
    if (authOverride is AuthDisabled) {
      return null;
    }

    // Check if this is a refresh request (don't retry refresh on 401)
    if (_isRefreshRequest(ctx.request)) {
      return null;
    }

    // Determine which storage to read from
    final AccountId? account = switch (authOverride) {
      AuthAccount aa => aa.account,
      _ => null,
    };

    final effectiveStorage = account != null && multiAccountStorage != null
        ? multiAccountStorage!
        : storage;

    // Check if refresh should be triggered
    final shouldTriggerRefresh = error.response?.statusCode == 401 ||
        (shouldRefresh != null && shouldRefresh!(error));

    if (!shouldTriggerRefresh) {
      return null;
    }

    // Get current token
    final pair = await effectiveStorage.read();

    try {
      await _doRefresh(ctx, pair, effectiveStorage);
    } on RefreshFailedException {
      rethrow;
    }

    // Mark as replayed after refresh and request replay
    ctx.wasReplayedAfterRefresh = true;
    return const StrategyDecision.replay();
  }

  /// Perform the actual token refresh, with single-flight semantics.
  ///
  /// If a refresh is already in flight, this awaits the same Completer.
  /// On success, updates storage with new token.
  /// On failure, clears storage and throws [RefreshFailedException].
  Future<void> _doRefresh(
    PipelineContext ctx,
    TokenPair? currentPair,
    TokenStorage effectiveStorage,
  ) async {
    // Single-flight: if refresh is already in progress, await it
    if (_refreshInFlight != null) {
      await _refreshInFlight!.future;
      return;
    }

    _refreshInFlight = Completer<void>();
    _emitAuthState(AuthState.refreshing);

    try {
      final newPair = await refreshToken(currentPair);
      if (newPair == null) {
        throw Exception('refreshToken returned null');
      }

      await effectiveStorage.write(newPair);
      _emitAuthState(AuthState.authenticated);
      _refreshInFlight!.complete();
    } catch (e) {
      await effectiveStorage.clear();
      _emitAuthState(AuthState.unauthenticated);
      onRefreshFailed?.call();

      final exception = RefreshFailedException(
        requestOptions: ctx.request,
        error: e,
        stackTrace: StackTrace.current,
      );

      _refreshInFlight!.completeError(exception);
      rethrow;
    } finally {
      _refreshInFlight = null;
    }
  }

  /// Check if the request is a refresh endpoint.
  bool _isRefreshRequest(RequestOptions request) {
    if (isRefreshRequest != null) {
      return isRefreshRequest!(request);
    }

    // Look for a flag in Options.extra
    return request.extra['isRefreshRequest'] == true;
  }

  /// Inject the Authorization header into the request.
  void _injectAuthHeader(RequestOptions request, TokenPair pair) {
    request.headers['Authorization'] = '$scheme ${pair.access}';
  }

  /// Emit an auth state change to the stream.
  void _emitAuthState(AuthState state) {
    if (!_authStateController.isClosed) {
      _authStateController.add(state);
    }
  }
}
