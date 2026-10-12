import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/path.dart';
import 'package:test/test.dart';

void main() {
  late io.HttpServer server;
  late List<int> big;
  var flakyHits = 0;
  String? lastRange;
  String? lastContentType;
  String? lastBody;
  List<int>? lastBodyBytes;

  setUp(() async {
    big = List.generate(1000, (i) => i & 0xFF);
    flakyHits = 0;
    lastRange = lastContentType = lastBody = null;
    lastBodyBytes = null;
    server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      if (request.method == 'POST' && path == '/echo') {
        final body = await request.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
        lastBodyBytes = body;
        try {
          lastBody = utf8.decode(body);
        } catch (_) {
          lastBody = null;
        }
        lastContentType = request.headers.value('content-type');
        request.response
          ..statusCode = 200
          ..write('ok');
        await request.response.close();
        return;
      }
      switch (path) {
        case '/hello':
          request.response.headers.contentType = io.ContentType.text;
          request.response.write('hello');
        case '/missing':
          request.response.statusCode = 404;
          request.response.write('nope');
        case '/big':
          // A resumable file: answers the rest from the Range start.
          lastRange = request.headers.value('range');
          if (lastRange case final range?) {
            final start = int.parse(range.split('=')[1].split('-')[0]);
            request.response.statusCode = 206;
            request.response.add(big.sublist(start));
          } else {
            request.response.add(big);
          }
        case '/big-full':
          // No resume support: always the whole body, Range or not.
          lastRange = request.headers.value('range');
          request.response.add(big);
        case '/flaky':
          flakyHits++;
          if (flakyHits == 1) {
            request.response.statusCode = 503;
            request.response.write('try again');
          } else {
            request.response.write('recovered');
          }
        default:
          request.response.statusCode = 404;
          request.response.write('nope');
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  String url(String path) => 'http://${server.address.host}:${server.port}$path';

  test('Http.get(u).text() with one await: 200 gives the body', () async {
    expect(await Http.get(url('/hello')).text(), 'hello');
  });

  test('await Http.get(u) gives the Resp: status and headers, nothing read yet', () async {
    final resp = await Http.get(url('/hello'));
    expect(resp.status, 200);
    expect(resp.header('content-type'), contains('text/plain'));
    expect(await resp.text(), 'hello');
  });

  test('a non-2xx text() throws HttpException with the status', () async {
    await expectLater(
      Http.get(url('/missing')).text(),
      throwsA(isA<HttpException>().having((e) => e.status, 'status', 404)),
    );
  });

  test('pipe(file, resume: true) asks for the rest with Range', () async {
    final dir = await Dir.temp();
    try {
      final file = dir.file('big.bin');
      await file.write(big.sublist(0, 400));
      final n = await Http.get(url('/big')).pipe(file, resume: true);
      expect(n, 600);
      expect(lastRange, 'bytes=400-');
      expect(await file.bytes(), big);
    } finally {
      await dir.drop();
    }
  });

  test('resume against a server that answers 200 throws HttpException', () async {
    final dir = await Dir.temp();
    try {
      final file = dir.file('big.bin');
      await file.write(big.sublist(0, 400));
      await expectLater(
        Http.get(url('/big-full')).pipe(file, resume: true),
        throwsA(isA<HttpException>().having((e) => e.status, 'status', 200)),
      );
    } finally {
      await dir.drop();
    }
  });

  test('post(form:) sends fields as form content', () async {
    final resp = await Http.post(url('/echo'), form: {'a': '1'});
    expect(resp.status, 200);
    await resp.close();
    expect(lastContentType, contains('application/x-www-form-urlencoded'));
    expect(lastBody, 'a=1');
  });

  test('post(body: File) uploads identical bytes', () async {
    final dir = await Dir.temp();
    try {
      final file = dir.file('up.bin');
      await file.write(big);
      final resp = await Http.post(url('/echo'), body: file);
      expect(resp.status, 200);
      await resp.close();
      expect(lastBodyBytes, big);
    } finally {
      await dir.drop();
    }
  });

  test('more than one body parameter is an ArgumentError', () {
    expect(() => Http.post('http://127.0.0.1/', json: 1, form: {}), throwsArgumentError);
  });

  test('a 503 then 200 is retried', () async {
    expect(await Http.get(url('/flaky')).text(), 'recovered');
    expect(flakyHits, 2);
  });
}
