// Prints a random cat saying LGTM as Markdown and copies it to the clipboard,
// ready to paste into a PR review.
//
//   dart run projects/lgtmeow/lgtmeow.dart [text] [--tag cute] [--save cat.png] [--open]
library;

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/shell.dart';

final textArg = Arg('text', 'What the cat says.', or: 'LGTM');
final tagOpt = Opt<String?>('tag', 'Only cats with this tag (cute, funny, orange…).', short: 't');
final saveOpt = Opt<String?>('save', 'Also save the picture to this file.', short: 's');
final openFlag = Flag('open', 'Show the cat in the browser.', short: 'o');

final cataas = Http.client(base: 'https://cataas.com/', retries: 3, check: true);

Future<void> main(List<String> args) => Command(
  'lgtmeow',
  'A random cat that says LGTM, as Markdown for a review.',
  params: [textArg, tagOpt, saveOpt, openFlag],
  handler: run,
).run(args);

Future<void> run(Context c) async {
  final text = c(textArg);
  final tag = c(tagOpt);
  var path = 'cat/says/${Uri.encodeComponent(text)}';
  if (tag != null) path = 'cat/${Uri.encodeComponent(tag)}/says/${Uri.encodeComponent(text)}';

  final String url;
  try {
    final cat = await Console.spin(
      'finding a cat',
      cataas.get(path, query: {'json': true, 'fontSize': 60, 'fontColor': 'white'}).json(),
    );
    url = cat.$('url').text() ?? (throw Exception('cataas sent no picture link'));
  } on HttpStatusException catch (e) {
    if (e.status == 404 && tag != null) throw UsageException('No cat has the tag "$tag".');
    rethrow;
  }

  final markdown = '![$text]($url)';
  print(markdown);
  Console.copy(markdown);
  Console.log('copied to the clipboard: paste it into the review');

  final save = c(saveOpt);
  if (save != null) {
    await (cataas.get(url) > Fs.file(save));
    Console.log('saved the picture to $save');
  }
  if (c(openFlag)) await Shell.open(url);
}
