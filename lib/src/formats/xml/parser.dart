part of '../../markup.dart';

/// Parses [source] into its document element. Lenient where a scraper wants it: a mismatched
/// end tag closes the nearest open element of that name, an unknown entity stays literal.
Element _parseXml(String source) {
  final src = source.contains('\r') ? source.replaceAll('\r\n', '\n').replaceAll('\r', '\n') : source;
  Element? root;
  final open = <Element>[];
  final openNames = <String, int>{}; // how many of each name are in [open]
  final run = _TextRun();
  var pos = 0;

  // Whitespace or junk outside the document element is dropped.
  void text(String data) => open.isEmpty ? null : run.add(open.last, data);

  while (pos < src.length) {
    final lt = src.indexOf('<', pos);
    if (lt == -1) {
      text(_decodeXmlEntities(src.substring(pos)));
      break;
    }
    if (lt > pos) text(_decodeXmlEntities(src.substring(pos, lt)));
    pos = lt;
    // Where [close] ends, searching from [from]; the end of the input when it never comes.
    int past(String close, int from) {
      final end = src.indexOf(close, from);
      return end == -1 ? src.length : end + close.length;
    }

    if (src.startsWith('<!--', pos)) {
      pos = past('-->', pos + 4);
    } else if (src.startsWith('<![CDATA[', pos)) {
      final end = src.indexOf(']]>', pos + 9);
      text(src.substring(pos + 9, end == -1 ? src.length : end));
      pos = end == -1 ? src.length : end + 3;
    } else if (src.startsWith('<?', pos)) {
      pos = past('?>', pos + 2);
    } else if (src.startsWith('<!', pos)) {
      // <!DOCTYPE …>, possibly with an internal subset in brackets.
      var depth = 0;
      var i = pos + 2;
      for (; i < src.length; i++) {
        final c = src.codeUnitAt(i);
        if (c == 0x5b) depth++;
        if (c == 0x5d) depth--;
        if (c == 0x3e && depth <= 0) break;
      }
      pos = i + 1;
    } else if (src.startsWith('</', pos)) {
      final gt = src.indexOf('>', pos);
      final name = src.substring(pos + 2, gt == -1 ? src.length : gt).trim();
      pos = gt == -1 ? src.length : gt + 1;
      // A name not open is ignored without searching the stack, which made stray closes quadratic.

      final i = (openNames[name] ?? 0) == 0 ? -1 : open.lastIndexWhere((e) => e.name == name);
      if (i != -1) {
        run.flush();
        for (var k = i; k < open.length; k++) {
          openNames[open[k].name] = openNames[open[k].name]! - 1;
        }
        open.removeRange(i, open.length);
      }
    } else if (pos + 1 < src.length && _isXmlNameStart(src.codeUnitAt(pos + 1))) {
      final nameEndPos = _nameEnd(src, pos + 1);
      final element = Element(src.substring(pos + 1, nameEndPos), {}, Syntax.xml);
      final end = _scanAttributes(src, nameEndPos, element.attributes, html: false);
      final selfClosing = end < 0;
      pos = end.abs();
      run.flush();
      if (open.isEmpty) {
        root ??= element;
      } else {
        open.last._nodes.add(
          element
            .._parent = open.last
            .._slot = open.last._nodes.length,
        );
      }
      if (!selfClosing) {
        open.add(element);
        openNames.update(element.name, (n) => n + 1, ifAbsent: () => 1);
      }
    } else {
      text('<');
      pos++;
    }
  }
  run.flush();
  return root ?? (throw const FormatException('XML: no document element'));
}

bool _isXmlNameStart(int c) =>
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f || c == 0x3a || c > 0x7f;
