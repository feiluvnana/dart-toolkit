part of '../../tui.dart';

/// Pixels drawn as half-block cells: two pixels a cell, the upper one `▀`'s colour and the
/// lower one its background, in 24-bit colour or the nearest the terminal shows. [frames] are
/// RGBA bytes, [width] × [height] each (from `image`'s decode, or made by hand); more than one
/// animate, [every] apart. A pixel more than half transparent shows what is behind it. Larger
/// than its canvas, it is scaled down to fit.
///
/// ```dart
/// final mascot = Picture([rgba], width: 16, height: 16);
/// final walking = Picture(steps, width: 16, height: 16, every: 150.ms);
/// ```
///
/// {@category CLI}
final class Picture extends Widget {
  final List<Uint8List> frames;
  final int pixels, rows;
  final Duration every;

  Picture(this.frames, {required int width, required int height, this.every = const Duration(milliseconds: 100)})
    : pixels = width,
      rows = height {
    if (width < 1 || height < 1) {
      throw ArgumentError.value((width, height), 'size', 'Invalid size, expected at least 1×1');
    }
    if (frames.isEmpty) throw ArgumentError.value(frames, 'frames', 'Invalid frames: none');
    for (final f in frames) {
      if (f.length != width * height * 4) {
        throw ArgumentError.value(f.length, 'frames', 'Invalid frame: expected ${width * height * 4} RGBA bytes');
      }
    }
    if (every <= Duration.zero) throw ArgumentError.value(every, 'every', 'Invalid interval, expected more than zero');
  }

  @override
  int get width => pixels;

  @override
  int heightAt(int width) {
    final scale = width < pixels ? pixels / width : 1.0;
    return (rows / scale / 2).ceil();
  }

  @override
  void paint(Canvas canvas) {
    if (frames.length > 1) canvas.animate(every);
    final frame =
        frames[frames.length == 1 ? 0 : canvas._frame.elapsed.inMicroseconds ~/ every.inMicroseconds % frames.length];
    // Nearest neighbour into the canvas, keeping the shape.
    final fit = [pixels / canvas.width, rows / (canvas.height * 2), 1.0].reduce((a, b) => a > b ? a : b);
    final w = (pixels / fit).floor(), h = (rows / fit).floor();
    final unicode = TerminalBridge.drawsUnicode;
    Color? at(int x, int y) {
      if (y >= h) return null;
      final i = (((y * fit).floor().clamp(0, rows - 1)) * pixels + (x * fit).floor().clamp(0, pixels - 1)) * 4;
      return frame[i + 3] < 128 ? null : Color.rgb(frame[i], frame[i + 1], frame[i + 2]);
    }

    for (var cy = 0; cy * 2 < h && cy < canvas.height; cy++) {
      for (var x = 0; x < w && x < canvas.width; x++) {
        final top = at(x, cy * 2), bottom = at(x, cy * 2 + 1);
        if (top == null && bottom == null) continue;
        if (!unicode) {
          canvas._put(x, cy, ' ', 1, Style(bg: top ?? bottom));
        } else if (top == null) {
          canvas._put(x, cy, '▄', 1, Style(fg: bottom));
        } else {
          canvas._put(x, cy, '▀', 1, Style(fg: top, bg: bottom));
        }
      }
    }
  }
}
