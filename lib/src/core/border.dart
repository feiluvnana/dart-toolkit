part of '../../core.dart';

/// The glyphs a box or a table is drawn with, shared by `Console`, `Table.show` and `Tui`.
///
/// Every glyph has a default from [square], so a custom border names only what differs:
/// `Border(topLeft: '╭', topRight: '╮', bottomLeft: '╰', bottomRight: '╯')`.
///
/// {@category CLI}
final class Border {
  final String topLeft, top, topRight, side, bottomLeft, bottomRight;

  /// Where a column divider meets the top and bottom edges, and where a row divider crosses.
  final String topTee, bottomTee, leftTee, rightTee, cross;

  const Border({
    this.topLeft = '┌',
    this.top = '─',
    this.topRight = '┐',
    this.side = '│',
    this.bottomLeft = '└',
    this.bottomRight = '┘',
    this.topTee = '┬',
    this.bottomTee = '┴',
    this.leftTee = '├',
    this.rightTee = '┤',
    this.cross = '┼',
  });

  static const square = Border();
  static const rounded = Border(topLeft: '╭', topRight: '╮', bottomLeft: '╰', bottomRight: '╯');
  static const double = Border(
    topLeft: '╔',
    top: '═',
    topRight: '╗',
    side: '║',
    bottomLeft: '╚',
    bottomRight: '╝',
    topTee: '╦',
    bottomTee: '╩',
    leftTee: '╠',
    rightTee: '╣',
    cross: '╬',
  );
  static const heavy = Border(
    topLeft: '┏',
    top: '━',
    topRight: '┓',
    side: '┃',
    bottomLeft: '┗',
    bottomRight: '┛',
    topTee: '┳',
    bottomTee: '┻',
    leftTee: '┣',
    rightTee: '┫',
    cross: '╋',
  );
  static const ascii = Border(
    topLeft: '+',
    top: '-',
    topRight: '+',
    side: '|',
    bottomLeft: '+',
    bottomRight: '+',
    topTee: '+',
    bottomTee: '+',
    leftTee: '+',
    rightTee: '+',
    cross: '+',
  );

  /// A Markdown table: `| a | b |` rows under a `|---|---|` rule, no outer box.
  static const markdown = Border(
    topLeft: '',
    top: '-',
    topRight: '',
    bottomLeft: '',
    bottomRight: '',
    side: '|',
    topTee: '',
    bottomTee: '',
    leftTee: '|',
    rightTee: '|',
    cross: '|',
  );

  /// No glyphs: a box is only its padding and title, a table only its aligned columns.
  static const none = Border(
    topLeft: '',
    top: '',
    topRight: '',
    side: '',
    bottomLeft: '',
    bottomRight: '',
    topTee: '',
    bottomTee: '',
    leftTee: '',
    rightTee: '',
    cross: '',
  );
}
