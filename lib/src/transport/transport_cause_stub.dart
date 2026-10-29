/// Whether [cause], the error inside a `DioException` of type `unknown`, is
/// a dropped or failed connection.
///
/// Off `dart:io` (the web) the browser adapter reports connection failures
/// as `connectionError` itself, so nothing here is one.
bool isTransportCause(Object? cause) => false;
