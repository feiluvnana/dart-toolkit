/// A Claude Code-style chat loop on `tui` (REPORT §15.8), inline in the
/// terminal: finished turns go to the scrollback, the live area is the
/// reply being streamed and the prompt.
///
/// ```sh
/// dart run example/agent.dart
/// ```
///
/// `enter` sends, `shift+enter`/`\`+`enter` add a line, `esc` interrupts a
/// reply, `shift+tab` cycles the mode, `ctrl+y` copies the last reply,
/// `/quit` (or `/q` + `tab`) quits. [reply] fakes a model that streams text.
library;

import 'dart:async';

import 'package:dart_toolkit/tui.dart';

sealed class Turn {}

final class Chat extends Turn {
  final prompt = TextField();
  var reply = '', mode = 0, last = '';
  DateTime? since;
  StreamSubscription<String>? stream;
}

const _modes = ['', '⏵⏵ accept edits on', '⏸ plan mode on'];
const _commands = ['/clear', '/help', '/model', '/quit'];

Future<void> main() async {
  await Tui.run<Turn>(
    Chat(),
    fullscreen: false,
    (turn, app) => switch (turn) {
      Chat c => Screen(
        status: _modes[c.mode],
        (r) {
          if (c.since case final t?) {
            r.markdown(c.reply).spin('Thinking… (${DateTime.now().difference(t).inSeconds}s · esc to interrupt)');
          }
          r
              .box('')
              .input(
                c.prompt,
                lines: 0,
                hint: 'Try "fix the failing test"',
                suggest: (w) => [
                  for (final x in _commands)
                    if (x.startsWith(w)) x,
                ],
              );
        },
        keys: {
          'enter': ('send', () => _send(c, app)),
          if (c.stream != null) 'escape': ('interrupt', () => _done(c, app)),
          'shift+tab': ('mode', () => c.mode = (c.mode + 1) % _modes.length),
          'ctrl+y': ('', () => app.copyToClipboard(c.last)),
        },
      ),
    },
  );
}

void _send(Chat c, App<Turn> app) {
  if (c.stream != null || c.prompt.text().trim().isEmpty) return;
  final text = c.prompt.submit();
  if (text == '/quit') return app.quit();
  app.printAbove((Region r) => r.write('> $text', color: Color.gray));
  c
    ..reply = ''
    ..since = DateTime.now();
  c.stream = reply(text).listen(
    (t) => c.reply += t,
    onDone: () {
      _done(c, app);
      app.notify('Claude is done'); // only shows when the terminal is in the background
    },
  );
}

void _done(Chat c, App<Turn> app) {
  c.stream?.cancel();
  final text = c.last = c.reply;
  app.printAbove((Region r) => r.markdown(text)); // into scrollback; the live area shrinks back to the prompt
  c
    ..stream = null
    ..since = null
    ..reply = '';
}

/// A fake model: streams a markdown answer a few characters at a time.
Stream<String> reply(String prompt) async* {
  final answer =
      '''
Looking at **$prompt** — here is a fix:

```dart
int add(int a, int b) => a + b; // was a - b
```

- run `dart test` again
- it should pass now
''';
  for (var i = 0; i < answer.length; i += 3) {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    yield answer.substring(i, i + 3 > answer.length ? answer.length : i + 3);
  }
}
