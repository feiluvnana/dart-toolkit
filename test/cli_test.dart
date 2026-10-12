import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/testing.dart';
import 'package:test/test.dart';

void main() {
  group('BarGlyphs', () {
    test('presets draw the fraction', () {
      expect(BarGlyphs.blocks.draw(0.5, 4), '██░░');
      expect(BarGlyphs.line.draw(0.5, 4), '━━╸─');
      expect(BarGlyphs.ascii.draw(0.5, 4), '##--');
      expect(BarGlyphs.arrow.draw(0.5, 4), '==>-');
      expect(BarGlyphs.blocks.draw(0.0, 3), '░░░');
      expect(BarGlyphs.blocks.draw(1.0, 3), '███');
    });
  });

  test('CliFake.lines feeds confirm', () async {
    CliFake.lines(['y']);
    expect(await Cli.confirm('Proceed?'), isTrue);
  });
}
