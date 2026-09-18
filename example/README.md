# Examples

Four task-shaped programs, each runnable and analysed with the package.

Each one opens with the modules it uses, not `dart_toolkit.dart` — under `dart run file.dart`
the barrel costs about 1.4 s of front-end work per invocation against about 0.3 s.
`tool/check_deps.dart` fails the build if one of these files reaches for the barrel again. A
`bin/` executable has a cheaper path: `dart run dart_toolkit:keybox` uses pub's incremental
snapshot and starts in about 0.4 s.

| file | shows |
|---|---|
| [`cli_app.dart`](cli_app.dart) | `Cli` option kinds, required options, `Logger.stages`, `Console.progress` |
| [`file_automation.dart`](file_automation.dart) | `Path`, `filename`, hashing, archiving |
| [`web_crawler.dart`](web_crawler.dart) | `Http.session`, the `scrape` chain, `Elements` and `$x` queries |
| [`collections.dart`](collections.dart) | six tasks solved with the SDK's `Iterable` and again with `Sequence` and `Table`, side by side |

```sh
dart run example/cli_app.dart --token abc --env staging --workers 8
dart run example/file_automation.dart
dart run example/web_crawler.dart          # needs network
dart run example/collections.dart
```

There is deliberately no example that demonstrates every API at once. One existed, and it made
the surface feel obligatory rather than compositional. `bin/keybox.dart` is the program that
composes several modules at once and serves as the composition test.
