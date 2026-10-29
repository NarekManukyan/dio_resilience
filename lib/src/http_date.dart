const _months = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// IMF-fixdate: `Sun, 06 Nov 1994 08:49:37 GMT`.
final _imfFixdate = RegExp(
  r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
);

/// Obsolete RFC 850 date: `Sunday, 06-Nov-94 08:49:37 GMT`.
final _rfc850 = RegExp(
  r'^[A-Za-z]+, (\d{2})-([A-Za-z]{3})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) GMT$',
);

/// Obsolete asctime date: `Sun Nov  6 08:49:37 1994`.
final _asctime = RegExp(
  r'^[A-Za-z]{3} ([A-Za-z]{3}) +(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})$',
);

/// Parses an HTTP-date (RFC 9110 §5.6.7) in any of its three forms, as UTC.
/// Null when [value] is none of them.
///
/// Written here rather than using `HttpDate` from `dart:io`, which isn't
/// available on the web.
DateTime? parseHttpDate(String value) {
  final text = value.trim();

  var m = _imfFixdate.firstMatch(text);
  if (m != null) {
    return _utc(m[3]!, m[2]!, m[1]!, m[4]!, m[5]!, m[6]!);
  }

  m = _rfc850.firstMatch(text);
  if (m != null) {
    // Two-digit years: RFC 9110 says read one more than 50 years ahead as
    // the past century. Retry-After dates are never that far off.
    final yy = int.parse(m[3]!);
    final year = yy < 70 ? 2000 + yy : 1900 + yy;
    return _utc('$year', m[2]!, m[1]!, m[4]!, m[5]!, m[6]!);
  }

  m = _asctime.firstMatch(text);
  if (m != null) {
    return _utc(m[6]!, m[1]!, m[2]!, m[3]!, m[4]!, m[5]!);
  }

  return null;
}

DateTime? _utc(
  String year,
  String month,
  String day,
  String hour,
  String minute,
  String second,
) {
  final mon = _months[month.toLowerCase()];
  if (mon == null) return null;
  final d = int.parse(day);
  final h = int.parse(hour);
  final mi = int.parse(minute);
  final s = int.parse(second);
  if (d < 1 || d > 31 || h > 23 || mi > 59 || s > 60) return null;
  return DateTime.utc(int.parse(year), mon, d, h, mi, s);
}
