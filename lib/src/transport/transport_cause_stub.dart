/// Off `dart:io` (the web) the browser adapter reports connection failures
/// as `connectionError` itself, so no other cause is one.
bool isPlatformTransportCause(Object? cause) => false;
