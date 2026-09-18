part of '../../xml.dart';

/// Parses [source] into its document element. Lenient where a scraper wants it: a mismatched
/// end tag closes the nearest open element of that name, an unknown entity stays literal.
XmlElement _parseXml(String source) {
  final src = source.contains('\r') ? source.replaceAll('\r\n', '\n').replaceAll('\r', '\n') : source;
  XmlElement? root;
  final open = <XmlElement>[];
  var pos = 0;

  void text(String raw) {
    if (open.isEmpty) return; // whitespace or junk outside the document element
    final target = open.last;
    final data = _decodeXmlEntities(raw);
    if (target.children.lastOrNull case final XmlText last) {
      target.children[target.children.length - 1] = XmlText(last.data + data)..parent = target;
    } else {
      target.children.add(XmlText(data)..parent = target);
    }
  }

  while (pos < src.length) {
    final lt = src.indexOf('<', pos);
    if (lt == -1) {
      text(src.substring(pos));
      break;
    }
    if (lt > pos) text(src.substring(pos, lt));
    pos = lt;
    if (src.startsWith('<!--', pos)) {
      final end = src.indexOf('-->', pos + 4);
      pos = end == -1 ? src.length : end + 3;
    } else if (src.startsWith('<![CDATA[', pos)) {
      final end = src.indexOf(']]>', pos + 9);
      final data = src.substring(pos + 9, end == -1 ? src.length : end);
      if (open.isNotEmpty) {
        final target = open.last;
        if (target.children.lastOrNull case final XmlText last) {
          target.children[target.children.length - 1] = XmlText(last.data + data)..parent = target;
        } else {
          target.children.add(XmlText(data)..parent = target);
        }
      }
      pos = end == -1 ? src.length : end + 3;
    } else if (src.startsWith('<?', pos)) {
      final end = src.indexOf('?>', pos + 2);
      pos = end == -1 ? src.length : end + 2;
    } else if (src.startsWith('<!', pos)) {
      // <!DOCTYPE …>, possibly with an internal subset in brackets.
      var depth = 0;
      var i = pos + 2;
      while (i < src.length) {
        final c = src[i];
        if (c == '[') depth++;
        if (c == ']') depth--;
        if (c == '>' && depth <= 0) break;
        i++;
      }
      pos = i + 1;
    } else if (src.startsWith('</', pos)) {
      final gt = src.indexOf('>', pos);
      final name = src.substring(pos + 2, gt == -1 ? src.length : gt).trim();
      pos = gt == -1 ? src.length : gt + 1;
      for (var i = open.length - 1; i >= 0; i--) {
        if (open[i].name == name) {
          open.removeRange(i, open.length);
          break;
        }
      }
    } else if (pos + 1 < src.length && _isXmlNameStart(src.codeUnitAt(pos + 1))) {
      pos = _startTag(src, pos, open, (e) => root ??= e);
    } else {
      text('<');
      pos++;
    }
  }
  final result = root;
  if (result == null) throw const FormatException('No document element');
  return result;
}

int _startTag(String src, int pos, List<XmlElement> open, void Function(XmlElement) onRoot) {
  var i = pos + 1;
  final start = i;
  while (i < src.length && _isXmlNameChar(src.codeUnitAt(i))) {
    i++;
  }
  final name = src.substring(start, i);
  final attributes = <String, String>{};
  var selfClosing = false;
  while (true) {
    while (i < src.length && _isXmlSpace(src.codeUnitAt(i))) {
      i++;
    }
    if (i >= src.length) break;
    final c = src.codeUnitAt(i);
    if (c == 0x3e) {
      i++;
      break;
    }
    if (c == 0x2f) {
      i++;
      if (i < src.length && src.codeUnitAt(i) == 0x3e) {
        selfClosing = true;
        i++;
        break;
      }
      continue;
    }
    final nameStart = i;
    while (i < src.length && _isXmlNameChar(src.codeUnitAt(i))) {
      i++;
    }
    if (i == nameStart) {
      i++;
      continue;
    }
    final attrName = src.substring(nameStart, i);
    while (i < src.length && _isXmlSpace(src.codeUnitAt(i))) {
      i++;
    }
    var value = '';
    if (i < src.length && src.codeUnitAt(i) == 0x3d) {
      i++;
      while (i < src.length && _isXmlSpace(src.codeUnitAt(i))) {
        i++;
      }
      if (i < src.length) {
        final q = src.codeUnitAt(i);
        if (q == 0x22 || q == 0x27) {
          final end = src.indexOf(String.fromCharCode(q), i + 1);
          value = src.substring(i + 1, end == -1 ? src.length : end);
          i = end == -1 ? src.length : end + 1;
        } else {
          final vs = i;
          while (i < src.length && !_isXmlSpace(src.codeUnitAt(i)) && src.codeUnitAt(i) != 0x3e) {
            i++;
          }
          value = src.substring(vs, i);
        }
      }
    }
    attributes.putIfAbsent(attrName, () => _decodeXmlEntities(value));
  }
  final element = XmlElement(name, attributes);
  if (open.isEmpty) {
    onRoot(element);
  } else {
    element.parent = open.last;
    open.last.children.add(element);
  }
  if (!selfClosing) open.add(element);
  return i;
}

const _xmlEntities = {'lt': '<', 'gt': '>', 'amp': '&', 'quot': '"', 'apos': "'"};

/// Decodes the five predefined entities and numeric references; anything else stays as written.
String _decodeXmlEntities(String text) {
  var amp = text.indexOf('&');
  if (amp == -1) return text;
  final sb = StringBuffer();
  var last = 0;
  while (amp != -1) {
    final semi = text.indexOf(';', amp + 1);
    if (semi == -1) break;
    final name = text.substring(amp + 1, semi);
    String? decoded;
    if (name.startsWith('#')) {
      final hex = name.length > 1 && (name[1] == 'x' || name[1] == 'X');
      final code = int.tryParse(name.substring(hex ? 2 : 1), radix: hex ? 16 : 10);
      if (code != null && code > 0 && code <= 0x10ffff && (code < 0xd800 || code > 0xdfff)) {
        decoded = String.fromCharCode(code);
      }
    } else {
      decoded = _xmlEntities[name];
    }
    if (decoded != null) {
      sb
        ..write(text.substring(last, amp))
        ..write(decoded);
      last = semi + 1;
    }
    amp = text.indexOf('&', amp + 1);
  }
  sb.write(text.substring(last));
  return sb.toString();
}

bool _isXmlSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;
bool _isXmlNameStart(int c) =>
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f || c == 0x3a || c > 0x7f;
bool _isXmlNameChar(int c) => _isXmlNameStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x2d || c == 0x2e;
