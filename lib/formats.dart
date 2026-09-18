/// # Formats
///
/// YAML, TOML and INI decoded into `JsonDocument`, so one query language — JSONPath — and one
/// `to<T>()` serve every configuration and data file; YAML written back out. CSV, TSV, NDJSON
/// and Markdown tables are `Table`'s, in `collection`. No dependencies.
///
/// ```dart
/// final pubspec = (await 'pubspec.yaml'.path.readText()).yaml;
/// print(pubspec.$(r'$.dependencies.*').length);
/// final config = configText.toml['server']['port'].to<int>();
/// ```
///
/// {@category Formats}
library;

import 'dart:convert';

import 'core.dart';

part 'src/formats/ini.dart';
part 'src/formats/toml.dart';
part 'src/formats/yaml.dart';
