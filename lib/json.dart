/// # Documents
///
/// JSON, YAML, TOML and INI as one model, [Doc]: read by key and typed, queried with JSONPath,
/// edited, and written in any of the four formats.
///
/// {@category Formats}
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'src/collection/formats_bridge.dart';
import 'src/base.dart';
import 'src/message.dart';

export 'src/foundations.dart';

part 'src/formats/ini.dart';
part 'src/formats/json/doc.dart';
part 'src/formats/json/json_path.dart';
part 'src/formats/json/jsonpath.dart';
part 'src/formats/toml.dart';
part 'src/formats/yaml.dart';
