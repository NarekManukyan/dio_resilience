import 'package:dio/dio.dart';

import '../options_extension.dart';
import '../overrides.dart';
import '../pipeline_context.dart';
import '../strategy.dart';

/// Meta key stored in [PipelineContext.meta] while this request's endpoint
/// fallback is in flight.
const String _kFallbackInFlight = 'fallback_in_flight';

/// Flag in the `extra` of an endpoint re-fire. The re-fire is a request of
/// its own with its own context, so the fallback strategy reads this flag to
/// stay out of it instead of falling back again, and again.
const String _kFallbackRefire = '__dio_resilience_fallback_refire__';

/// Pipeline-owned `extra` keys that must not be copied onto a re-fire.
const _kPipelineOwnedKeys = {
  '__dio_resilience_pipeline_context__',
  '__dio_resilience_sub_dispatch__',
};

/// Fallback strategy — the last resort in the resilience pipeline.
///
/// Positioned LAST in the pipeline so it only activates when every other
/// strategy (auth, rate-limit, circuit, hedging, retry, timeout) has
/// declined to handle the error.
///
/// The [handlers] list is walked in order; the first handler whose condition
/// is satisfied produces a [StrategyDecision.respond] result. If no handler
/// matches, the strategy returns `null` and the pipeline propagates the
/// original error.
///
/// ### Recursion guard
/// When an [FallbackHandler.endpoint] fires a secondary request and that
/// request itself errors, the [FallbackStrategy] will NOT try to fall back
/// again — the re-fire is flagged and the fallback strategy skips it.
///
/// ### Pipeline position
/// The builder always runs it LAST:
/// ```
/// auth → rateLimit → circuit → hedging → challenge → retry → timeout → fallback
/// ```
/// so it handles whatever failure the others end with: an exhausted retry,
/// a pipeline timeout, an open circuit, a failed refresh or challenge.
///
/// Usage:
/// ```dart
/// ResiliencePipeline.builder()
///   .retry(maxAttempts: 3)
///   .fallback(handlers: [
///     FallbackHandler.endpoint('https://mirror.example.com/api'),
///     FallbackHandler.response((err, opts) => Response(
///       requestOptions: opts,
///       statusCode: 200,
///       data: {'offline': true},
///     )),
///   ])
///   .build()
///   ..attachTo(dio);
/// ```
final class FallbackStrategy extends ResilienceStrategy {
  @override
  String get name => 'fallback';

  /// Ordered list of fallback handlers tried on error.
  final List<FallbackHandler> handlers;

  /// The Dio instance used for endpoint re-fires. Injected by the pipeline
  /// after [attachTo] so the secondary request still goes through the full
  /// interceptor chain (auth, retry, …).
  Dio? _dio;

  /// Creates a [FallbackStrategy].
  ///
  /// [handlers] — fallback handlers tried in order on error.
  FallbackStrategy({required this.handlers});

  /// Called by [ResiliencePipeline.attachTo] to wire up the Dio reference.
  // ignore: use_setters_to_change_properties
  void injectDio(Dio dio) => _dio = dio;

  @override
  Future<StrategyDecision?> onError(
    PipelineContext ctx,
    DioException error,
  ) async {
    // Never fall back from a cancellation, or from inside an endpoint
    // re-fire.
    if (error.type == DioExceptionType.cancel ||
        ctx.meta[_kFallbackInFlight] == true ||
        ctx.request.extra[_kFallbackRefire] == true) {
      return null;
    }

    // Check per-request override.
    final override = overridesFor(ctx.request)?.fallback;
    if (override is FallbackDisabled) {
      return null;
    }

    // Determine effective handler list (override may supply its own).
    final effectiveHandlers = _resolveHandlers(override);

    for (final handler in effectiveHandlers) {
      final decision = await _tryHandler(handler, ctx, error);
      if (decision != null) {
        return decision;
      }
    }

    return null;
  }

  /// Resolve the handler list honouring any per-request [override].
  List<FallbackHandler> _resolveHandlers(FallbackOverride? override) {
    if (override == null || override is FallbackDisabled) {
      return handlers;
    }
    if (override is FallbackResponse) {
      // Wrap the simple builder into a ResponseFallbackHandler.
      return [
        FallbackHandler.response((err, opts) => override.builder(err)),
      ];
    }
    if (override is FallbackHandlers) {
      return override.handlers;
    }
    return handlers;
  }

  /// Attempt a single handler. Returns a [StrategyDecision] on success, or
  /// `null` if this handler did not match / produce a result.
  Future<StrategyDecision?> _tryHandler(
    FallbackHandler handler,
    PipelineContext ctx,
    DioException error,
  ) async {
    switch (handler) {
      case ResponseFallbackHandler(builder: final build):
        final response = build(error, ctx.request);
        return StrategyDecision.respond(response);

      case EndpointFallbackHandler(url: final url, method: final method):
        return _fireEndpoint(url: url, method: method, ctx: ctx, error: error);

      case PredicateFallbackHandler(
          predicate: final pred,
          handler: final inner
        ):
        if (!pred(error)) return null;
        return _tryHandler(inner, ctx, error);
    }
  }

  /// Re-fire the original request to an alternate [url].
  ///
  /// Sets [_kFallbackInFlight] on [ctx] before the request so that if the
  /// secondary request also errors, [FallbackStrategy.onError] will skip
  /// itself and not recurse further.
  Future<StrategyDecision?> _fireEndpoint({
    required String url,
    required String? method,
    required PipelineContext ctx,
    required DioException error,
  }) async {
    final dio = _dio;
    if (dio == null) {
      // Should never happen after attachTo(); fail-safe: skip handler.
      return null;
    }

    // Set flag before the await so any error path sees it.
    ctx.meta[_kFallbackInFlight] = true;

    try {
      final original = ctx.request;

      final options = Options(
        method: method ?? original.method,
        headers: Map<String, dynamic>.from(original.headers),
        responseType: original.responseType,
        contentType: original.contentType,
        receiveTimeout: original.receiveTimeout,
        sendTimeout: original.sendTimeout,
        extra: {
          for (final entry in original.extra.entries)
            if (!_kPipelineOwnedKeys.contains(entry.key))
              entry.key: entry.value,
          _kFallbackRefire: true,
        },
      );

      final response = await dio.request<dynamic>(
        url,
        data: original.data,
        queryParameters: original.queryParameters,
        options: options,
        cancelToken: original.cancelToken,
      );

      return StrategyDecision.respond(response);
    } on DioException {
      // Alt endpoint failed — do not recurse. Return null so the pipeline
      // propagates the original error to the caller.
      return null;
    } catch (_) {
      return null;
    } finally {
      ctx.meta.remove(_kFallbackInFlight);
    }
  }
}
