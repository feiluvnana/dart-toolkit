// lgtmeow: a random cat that says LGTM, as Markdown for a pull request review.
//
//   dart run projects/lgtmeow.dart [text] [--tag cute] [--save cat.png] [--open]
//
// Prints `![LGTM](https://cataas.com/cat/<id>/says/LGTM…)` and copies it to the clipboard
// (OSC 52), so the next paste in the review box is the cat. The link is a permalink to
// that one cat. --tag picks from cats with that tag, --save keeps the picture, --open
// shows it in the browser.
library;

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/shell.dart';

final _text = Arg('text', 'What the cat says.', or: 'LGTM');
final _tag = Opt<String?>('tag', 'Only cats with this tag (cute, funny, orange…).', short: 't');
final _save = Opt<String?>('save', 'Also save the picture to this file.', short: 's');
final _open = Flag('open', 'Show the cat in the browser.', short: 'o');

final _cats = Http.client(base: 'https://cataas.com/', retries: 3, check: true);

Future<void> main(List<String> args) => Command(
  'lgtmeow',
  'A random cat that says LGTM, as Markdown for a review.',
  params: [_text, _tag, _save, _open],
  handler: _run,
).run(args);

Future<void> _run(Context c) async {
  final says = Uri.encodeComponent(c(_text));
  final tag = c(_tag);
  final Json cat;
  try {
    cat = await Console.spin(
      'finding a cat',
      _cats
          .get(
            tag == null ? 'cat/says/$says' : 'cat/${Uri.encodeComponent(tag)}/says/$says',
            query: {'json': true, 'fontSize': 60, 'fontColor': 'white'},
          )
          .json(),
    );
  } on HttpStatusException catch (e) {
    if (e.status == 404 && tag != null) throw UsageException('No cat has the tag "$tag".');
    rethrow;
  }
  final url = cat.$('url').text() ?? (throw Exception('cataas sent no picture link'));
  final markdown = '![${c(_text)}]($url)';
  print(markdown);
  Console.copy(markdown);
  Console.log('copied to the clipboard');
  if (c(_save) case final path?) {
    await (_cats.get(url) > Fs.file(path));
    Console.log('saved $path');
  }
  if (c(_open)) await Shell.open(url);
}
