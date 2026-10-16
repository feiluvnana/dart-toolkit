/// `or:` for whole-value readings (VISION rule 18): one rule for when a
/// source is missing, shared by `json` `yaml` `html` `csv` `cookies` and a
/// file's `text`/`bytes`.
library;

import 'dart:async';
import 'dart:io' show PathNotFoundException;

import '../core.dart';

final _missing = Expando<bool>('missing');

/// Mark [e] as "the source is not there" (an HTTP 404/410 from `check:`)
/// and return it.
T missing<T extends Object>(T e) {
  _missing[e] = true;
  return e;
}

/// [read] of [source]; with [or], [or] instead when the source is missing:
/// a missing file, or an HTTP 404/410 (thrown by `check:` or as the status
/// of a body read anyway). Every other failure still throws.
Future<T> orMissing<T extends Object>(FutureOr<Reader> source, T? or, Future<T> Function(Reader r) read) async {
  if (or == null) return read(await source);
  Reader? r;
  try {
    r = await source;
    final value = await read(r);
    return _gone(r) ? or : value;
  } catch (e) {
    if (e is PathNotFoundException || (e is Exception && _missing[e] == true) || (r != null && _gone(r))) return or;
    rethrow;
  }
}

bool _gone(Reader r) => switch (r.origin().status()) {
  404 || 410 => true,
  _ => false,
};
