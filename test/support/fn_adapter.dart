import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';

typedef Answer = FutureOr<ResponseBody> Function(
  RequestOptions o,
  Future<dynamic>? cancel,
);

class FnAdapter implements HttpClientAdapter {
  FnAdapter(this.answer);
  final Answer answer;
  final List<RequestOptions> requests = [];
  int get calls => requests.length;
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<List<int>>? s,
    Future<dynamic>? cancel,
  ) async {
    requests.add(o.copyWith(headers: {...o.headers}));
    return answer(o, cancel);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody body(
  int status, [
  Object? data,
  Map<String, List<String>> headers = const {},
]) =>
    ResponseBody.fromString(
      data == null ? '' : jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...headers,
      },
    );

Future<ResponseBody> hang(Future<dynamic>? cancel) async {
  await Future.any([
    Future<void>.delayed(const Duration(seconds: 30)),
    if (cancel != null) cancel,
  ]);
  throw DioException(
    requestOptions: RequestOptions(),
    type: DioExceptionType.cancel,
  );
}

Dio mkDio(HttpClientAdapter a) =>
    Dio(BaseOptions(baseUrl: 'https://api.example.com'))..httpClientAdapter = a;
