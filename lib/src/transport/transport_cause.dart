import 'package:http/http.dart' show ClientException;

import 'transport_cause_stub.dart'
    if (dart.library.io) 'transport_cause_io.dart' as platform;

/// Whether [cause], the error inside a `DioException` of type `unknown`, is
/// a dropped or failed connection, so another attempt may get through:
///
/// - a package:http [ClientException], which the native adapters
///   (`native_dio_adapter`, over cupertino_http and cronet_http) raise for
///   every transport failure. They don't say which, so each one counts;
/// - on `dart:io`, a `SocketException`, a TLS handshake the connection cut
///   short, or an `HttpException` for a connection closed before the
///   response was complete.
///
/// A response that failed to decode, a certificate dart:io rejected or a
/// redirect loop fails the same way on every attempt, so it is not one.
bool isTransportCause(Object? cause) =>
    cause is ClientException || platform.isPlatformTransportCause(cause);
