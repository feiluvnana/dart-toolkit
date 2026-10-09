/// The names README.md uses without declaring them, one type each, for `doc_examples_test.dart`.
library;

import 'dart:async';

import 'package:dart_toolkit/async.dart';
import 'package:dart_toolkit/chrome.dart';

// URLs.
late Uri url, api, login;
late List<Uri> urls, links;

// Text.
late String text, published, body, message, word, digest;

// Files.
late Path dir, cover;
late List<Path> files, images, photos;

// Streams.
late Stream<int> events, clicks, a, b, c;
late Stream<User> users;

// Work.
late Book book;
Future<void> work() async {}

final class User {
  final int id = 0;
}

final class Book {}

final class Thumbnail extends Worker<Path, Path> {
  @override
  Future<Path> run(Path item, Work work) async => item;
}

final class FetchBook extends Worker<Book, Path> {
  @override
  Future<Path> run(Book item, Work work) async => Path('book');
}

/// Keeps the imports the examples rely on in use.
void keep() => [Chrome, Completer];
