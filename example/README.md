# Examples

Three task-shaped programs. Each is runnable and each is checked by `dart analyze` in CI.

| file | shows |
|---|---|
| [`cli_app.dart`](cli_app.dart) | `Cli` option kinds, `Logger`, `Console.progress` |
| [`file_automation.dart`](file_automation.dart) | `Path`, hashing, archiving |
| [`web_crawler.dart`](web_crawler.dart) | the `scrape` pipeline and typed `ScrapeContext` |

```sh
dart run example/cli_app.dart --env staging --workers 8
dart run example/file_automation.dart
dart run example/web_crawler.dart          # needs network
```

There is deliberately no example that demonstrates every API at once. One existed, and it made
the surface feel obligatory rather than compositional.
