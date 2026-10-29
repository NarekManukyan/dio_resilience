import 'dart:io';

/// How every message dart:io raises as an HttpException of its own opens,
/// apart from a dropped connection: a malformed response, a bad header, a
/// refused proxy, a redirect. These fail the same way on every attempt. Any
/// other HttpException message is a SocketException's or TlsException's
/// message that dart:io rewrapped, so a dropped connection.
///
/// From `grep -rn 'HttpException(' <dart-sdk>/lib/_http`.
const _kHttpOwnFailurePrefixes = [
  "'SameSite'",
  'Chunk size',
  'Content size',
  'Content-Length',
  'Cookie with',
  'Data on',
  'Failed to parse',
  'HTTP headers',
  'HttpServer',
  'Illegal value',
  'Invalid HTTP',
  'Invalid Transfer-Encoding',
  'Invalid cookie',
  'Invalid header',
  'Invalid proxy',
  'Invalid request',
  'Invalid response',
  'Missing value',
  'More than one value',
  'No content',
  'No proxies',
  'Proxy failed',
  'Redirect',
  'Request has been aborted',
  'Server response',
  'The Content-Length',
  'The authentication',
  'Trying to',
  'Unexpected',
  'Value given',
];

/// How dart:io's header size limits end ('… exceeds the 1048576 size limit').
const _kHttpSizeLimitSuffix = ' size limit';

/// Whether [cause], the error inside a `DioException` of type `unknown`, is
/// a dropped or failed connection: a socket error, a TLS handshake the
/// connection cut short, or an HTTP connection closed before the response
/// was complete.
///
/// A response that failed to decode, a rejected certificate or a redirect
/// loop fails the same way on every attempt, so it is not one.
bool isTransportCause(Object? cause) => switch (cause) {
      SocketException() => true,
      // The only handshake failure dart:io raises for a cut connection; any
      // other is a negotiation the TLS layer refused.
      HandshakeException(:final message) =>
        message.startsWith('Connection terminated'),
      HttpException(:final message) => !(message.isEmpty ||
          message.endsWith(_kHttpSizeLimitSuffix) ||
          _kHttpOwnFailurePrefixes.any(message.startsWith)),
      _ => false,
    };
