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

/// Refreshes the token of one [AccountId], for requests sent with
/// `Options().withAccount(id)`. Same contract as [RefreshToken].
typedef RefreshAccountToken = Future<TokenPair?> Function(
  AccountId account,
  TokenPair? current,
);

/// Predicate to detect whether a request is the refresh endpoint itself.
///
/// Return true if this request should skip auth handling (not inject token,
/// not trigger refresh on 401).
typedef IsRefreshRequest = bool Function(RequestOptions request);

/// A request whose credentials were rejected, reported to
/// [AuthStrategy.onAuthFailure].
final class AuthRejection {
  /// The rejected request.
  final RequestOptions request;

  /// The access token the request carried, or null if it carried none. Lets
  /// an app with several sessions tell which one ended.
  final String? rejectedToken;

  /// The account the request was sent for (`withAccount`), if any.
  final AccountId? account;

  /// The response that rejected the token (the `401`), or null when a
  /// preemptive refresh failed before the request was sent.
  final Response<dynamic>? response;

  /// True when a token refresh was tried for this request and failed, or
  /// its new token was rejected too.
  final bool refreshAttempted;

  /// What the refresh failed with, if it threw.
  final Object? refreshError;

  const AuthRejection({
    required this.request,
    required this.rejectedToken,
    required this.account,
    required this.response,
    required this.refreshAttempted,
    this.refreshError,
  });
}

/// Context key marking a request that already had its token refreshed, so a
/// second `401` ends it instead of refreshing forever.
const String _kRefreshedKey = '__dio_resilience_auth_refreshed__';

/// Context key marking a request that carries a token this strategy put in
/// its `Authorization` header.
const String _kInjectedKey = '__dio_resilience_auth_injected__';

/// Strategy that manages OAuth/JWT token injection and refresh.
///
/// Injects the access token as `Authorization: Bearer <token>` (or custom
/// scheme) on each request.
///
/// With a [refreshToken] callback, a 401 or [shouldRefresh] match triggers a
/// refresh. Refresh is single-flight per account: concurrent 401s share one
/// refresh. A 401 for a token that was already replaced (another request
/// refreshed it meanwhile) just replays with the new token. A request gets
/// one refresh; a 401 for its refreshed token ends it with a
/// [RefreshFailedException].
///
/// Without [refreshToken] the strategy only injects tokens: a 401 is
/// reported to [onAuthFailure] and reaches the caller unchanged.
///
/// Honors [AuthOverride.disabled], [AuthOverride.account] and the
/// [kSkipAuthKey] flag per request. Emits [AuthState] changes via
/// [authStateStream].
class AuthStrategy extends ResilienceStrategy {
  /// Token storage for requests without an account.
  final TokenStorage storage;

  /// Token storage for requests sent with `withAccount(id)`. Without it
  /// those requests use [storage].
  final AccountTokenStorage? accountStorage;

  /// Callback to refresh the token. Null turns refresh off.
  final RefreshToken? refreshToken;

  /// Callback to refresh one account's token. Defaults to [refreshToken].
  final RefreshAccountToken? refreshAccountToken;

  /// Authorization scheme (default 'Bearer').
  final String scheme;

  /// Preemptive refresh window: if [TokenPair.accessExpiresAt] is within
  /// this duration of now, or already past, refresh before sending the
  /// request.
  final Duration preemptiveRefreshWindow;

  /// Optional predicate to detect refresh endpoint (skip auth for it). The
  /// [kSkipAuthKey] flag in `extra` is honored as well.
  final IsRefreshRequest? isRefreshRequest;

  /// Optional predicate to determine if a non-401 error should trigger
  /// refresh. Return true to attempt refresh; false otherwise.
  final bool Function(DioException error)? shouldRefresh;

  /// Called for every request whose credentials were rejected: a 401
  /// without refresh, a failed refresh, or a 401 for a refreshed token.
  final void Function(AuthRejection rejection)? onAuthFailure;

  /// Callback fired once when a refresh fails terminally.
  @Deprecated('Use onAuthFailure, which says which request and token failed')
  final void Function()? onRefreshFailed;

  /// Clear the token storage when a refresh fails. Turn off when the app
  /// decides what happens to the session itself (in [onAuthFailure]).
  final bool clearTokensOnRefreshFailure;

  /// Callback fired when a user is detected as unauthenticated.
  final void Function()? onUnauthenticated;

  /// Clock for token expiry. Defaults to [DateTime.now].
  final DateTime Function() now;

  final StreamController<AuthState> _authStateController;
  AuthState _authState = AuthState.idle;

  /// In-flight refresh per account (null: the [storage] session).
  final Map<AccountId?, Future<TokenPair>> _refreshes = {};

  /// The last finished refresh per account: the access token it replaced
  /// and the pair that replaced it. A request that read the old pair before
  /// that refresh wrote the new one gets the new pair instead of a second
  /// refresh, which a rotating refresh token would reject.
  final Map<AccountId?, ({String? from, TokenPair to})> _lastRefresh = {};

  @override
  String get name => 'auth';

  /// Stream of auth state changes. Emits whenever the auth state transitions.
  Stream<AuthState> get authStateStream => _authStateController.stream;

  AuthStrategy({
    required this.storage,
    this.refreshToken,
    this.accountStorage,
    this.refreshAccountToken,
    this.scheme = 'Bearer',
    this.preemptiveRefreshWindow = const Duration(minutes: 1),
    this.isRefreshRequest,
    this.shouldRefresh,
    this.onAuthFailure,
    @Deprecated('Use onAuthFailure') this.onRefreshFailed,
    this.clearTokensOnRefreshFailure = true,
    this.onUnauthenticated,
    DateTime Function()? now,
  })  : now = now ?? DateTime.now,
        _authStateController = StreamController<AuthState>.broadcast();

  /// Clean up the stream controller.
  void dispose() {
    _authStateController.close();
  }

  /// Manually log out (clears storage and emits forcedLogout). With
  /// [accountId] and an [accountStorage], clears only that account.
  Future<void> logout({AccountId? accountId}) async {
    final account = _accountKey(accountId);
    _lastRefresh.remove(account);
    await _clear(account);
    _emitAuthState(AuthState.forcedLogout);
  }

  @override
  Future<void> onRequest(PipelineContext ctx) async {
    if (_skips(ctx.request)) return;

    final account = _accountKey(_overrideAccount(ctx.request));
    var pair = await _read(account);
    if (pair == null) {
      // Signed out since an earlier attempt: don't resend that token.
      if (ctx.meta.remove(_kInjectedKey) == true) {
        ctx.request.headers.remove('Authorization');
      }
      _emitAuthState(AuthState.unauthenticated);
      onUnauthenticated?.call();
      return;
    }

    final expiresAt = pair.accessExpiresAt;
    if (_canRefresh(account) &&
        expiresAt != null &&
        !expiresAt.isAfter(now().add(preemptiveRefreshWindow))) {
      final expiring = pair;
      try {
        pair = await _refresh(account, expiring);
      } catch (cause, st) {
        _report(
          AuthRejection(
            request: ctx.request,
            rejectedToken: expiring.access,
            account: account,
            response: null,
            refreshAttempted: true,
            refreshError: cause,
          ),
        );
        throw RefreshFailedException(
          requestOptions: ctx.request,
          error: cause,
          stackTrace: st,
        );
      }
    }

    ctx.request.headers['Authorization'] = '$scheme ${pair.access}';
    ctx.meta[_kInjectedKey] = true;
    _emitAuthState(AuthState.authenticated);
  }

  @override
  Future<StrategyDecision?> onError(
    PipelineContext ctx,
    DioException error,
  ) async {
    if (_skips(ctx.request)) return null;
    if (error is DioResilienceException) return null;

    final shouldTriggerRefresh = error.response?.statusCode == 401 ||
        (shouldRefresh != null && shouldRefresh!(error));
    if (!shouldTriggerRefresh) return null;

    final account = _accountKey(_overrideAccount(ctx.request));
    final sent = _sentToken(ctx.request);
    AuthRejection rejection({bool attempted = false, Object? cause}) =>
        AuthRejection(
          request: ctx.request,
          rejectedToken: sent,
          account: account,
          response: error.response,
          refreshAttempted: attempted,
          refreshError: cause,
        );

    if (!_canRefresh(account)) {
      // Injection only: the 401 is the caller's answer.
      _report(rejection());
      return null;
    }

    if (ctx.meta[_kRefreshedKey] == true) {
      // The refreshed token was rejected too; another refresh won't help.
      _report(rejection(attempted: true));
      return StrategyDecision.fail(
        RefreshFailedException(
          requestOptions: ctx.request,
          response: error.response,
          stackTrace: error.stackTrace,
        ),
      );
    }

    final stored = await _read(account);
    final replaced = _lastRefresh[account]?.from;
    if (sent != null &&
        ((stored != null && stored.access != sent) || replaced == sent)) {
      // Another request refreshed the token while this one was in flight.
      return const StrategyDecision.replay(countsAsAttempt: false);
    }

    try {
      await _refresh(account, stored);
    } catch (cause, st) {
      _report(rejection(attempted: true, cause: cause));
      return StrategyDecision.fail(
        RefreshFailedException(
          requestOptions: ctx.request,
          response: error.response,
          error: cause,
          stackTrace: st,
        ),
      );
    }

    ctx.meta[_kRefreshedKey] = true;
    return const StrategyDecision.replay(countsAsAttempt: false);
  }

  /// Refreshes [account]'s token, sharing a refresh already in flight.
  Future<TokenPair> _refresh(AccountId? account, TokenPair? current) {
    final inFlight = _refreshes[account];
    if (inFlight != null) return inFlight;

    final last = _lastRefresh[account];
    if (last != null && current != null && current.access == last.from) {
      // Already refreshed away from this token; [current] was a stale read.
      return Future.value(last.to);
    }

    final refresh = _runRefresh(account, current);
    _refreshes[account] = refresh;
    unawaited(
      refresh.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (identical(_refreshes[account], refresh)) {
          _refreshes.remove(account);
        }
      }),
    );
    return refresh;
  }

  Future<TokenPair> _runRefresh(AccountId? account, TokenPair? current) async {
    _emitAuthState(AuthState.refreshing);
    try {
      final refreshAccount = refreshAccountToken;
      final pair = account != null && refreshAccount != null
          ? await refreshAccount(account, current)
          : await refreshToken!(current);
      if (pair == null) {
        throw StateError('refreshToken returned null');
      }
      await _write(account, pair);
      _lastRefresh[account] = (from: current?.access, to: pair);
      _emitAuthState(AuthState.authenticated);
      return pair;
    } catch (_) {
      if (clearTokensOnRefreshFailure) {
        await _clear(account);
      }
      _emitAuthState(AuthState.unauthenticated);
      // ignore: deprecated_member_use_from_same_package
      onRefreshFailed?.call();
      rethrow;
    }
  }

  bool _canRefresh(AccountId? account) =>
      refreshToken != null || (account != null && refreshAccountToken != null);

  /// The account whose tokens serve this request: null (the [storage]
  /// session) unless it was sent `withAccount` and there is an
  /// [accountStorage].
  AccountId? _accountKey(AccountId? account) =>
      accountStorage == null ? null : account;

  AccountId? _overrideAccount(RequestOptions request) =>
      switch (overridesFor(request)?.auth) {
        AuthAccount(:final account) => account,
        _ => null,
      };

  Future<TokenPair?> _read(AccountId? account) =>
      account == null ? storage.read() : accountStorage!.read(account);

  Future<void> _write(AccountId? account, TokenPair pair) => account == null
      ? storage.write(pair)
      : accountStorage!.write(account, pair);

  Future<void> _clear(AccountId? account) =>
      account == null ? storage.clear() : accountStorage!.clear(account);

  /// The token this request was sent with, read from its header.
  String? _sentToken(RequestOptions request) {
    final header = request.headers['Authorization'];
    if (header is! String) return null;
    final prefix = '$scheme ';
    return header.startsWith(prefix) ? header.substring(prefix.length) : null;
  }

  /// Whether auth stays out of this request: disabled for it, or it is the
  /// refresh endpoint / brings its own credentials.
  bool _skips(RequestOptions request) {
    if (overridesFor(request)?.auth is AuthDisabled) return true;
    return (isRefreshRequest?.call(request) ?? false) ||
        request.extra[kSkipAuthKey] == true;
  }

  void _report(AuthRejection rejection) => onAuthFailure?.call(rejection);

  /// Emit an auth state change to the stream, only when it changes.
  void _emitAuthState(AuthState state) {
    if (state == _authState && state != AuthState.forcedLogout) return;
    _authState = state;
    if (!_authStateController.isClosed) {
      _authStateController.add(state);
    }
  }
}
