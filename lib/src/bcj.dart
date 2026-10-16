/// Branch and delta filters, decoding direction: 7z coders and xz filters
/// both undo them after the LZMA stage. Each works in place on a whole
/// block and returns it.
library;

import 'dart:typed_data';

/// The x86 branch filter: CALL/JMP targets back from absolute to relative.
Uint8List bcjX86(Uint8List b) {
  const maskToAllowed = [true, true, true, false, true, false, false, false];
  const maskToBitNumber = [0, 1, 2, 2, 3, 3, 3, 3];
  var prevMask = 0;
  var prevPos = -5;
  var i = 0;
  final end = b.length - 5;
  while (i <= end) {
    final op = b[i];
    if (op != 0xE8 && op != 0xE9) {
      i++;
      continue;
    }
    final gap = i - prevPos;
    prevPos = i;
    if (gap > 5) {
      prevMask = 0;
    } else {
      for (var k = 0; k < gap; k++) {
        prevMask = (prevMask & 0x77) << 1;
      }
    }
    var b4 = b[i + 4];
    if ((b4 == 0 || b4 == 0xFF) && maskToAllowed[prevMask >> 1 & 7] && (prevMask >> 1) < 0x10) {
      var src = b4 << 24 | b[i + 3] << 16 | b[i + 2] << 8 | b[i + 1];
      int dest;
      while (true) {
        dest = (src - (i + 5)) & 0xFFFFFFFF;
        if (prevMask == 0) break;
        final index = maskToBitNumber[prevMask >> 1] * 8;
        b4 = dest >> (24 - index) & 0xFF;
        if (!(b4 == 0 || b4 == 0xFF)) break;
        src = dest ^ ((1 << (32 - index)) - 1);
      }
      dest = dest & 0x01FFFFFF;
      if (dest & 0x01000000 != 0) dest |= 0xFF000000;
      b[i + 1] = dest & 0xFF;
      b[i + 2] = dest >> 8 & 0xFF;
      b[i + 3] = dest >> 16 & 0xFF;
      b[i + 4] = dest >> 24 & 0xFF;
      i += 5;
      prevMask = 0;
    } else {
      i++;
      prevMask |= 1;
      if (b4 == 0 || b4 == 0xFF) prevMask |= 0x10;
    }
  }
  return b;
}

/// The ARM64 branch filter (BL and ADRP), decoding direction.
Uint8List bcjArm64(Uint8List b) {
  for (var i = 0; i + 4 <= b.length; i += 4) {
    var insn = b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24;
    if (insn >> 26 == 0x25) {
      final pc = i >> 2;
      insn = 0x94000000 | ((insn - pc) & 0x03FFFFFF);
    } else if (insn & 0x9F000000 == 0x90000000) {
      final src = (insn >> 29 & 3) | (insn >> 3 & 0x001FFFFC);
      if ((src + 0x00020000) & 0x001C0000 != 0) continue;
      final pc = i >> 12;
      final dest = (src - pc) & 0x1FFFFF;
      insn &= 0x9000001F;
      insn |= (dest & 3) << 29;
      insn |= (dest & 0x0003FFFC) << 3;
      insn |= (0 - (dest & 0x00020000)) & 0x00E00000;
    } else {
      continue;
    }
    b[i] = insn & 0xFF;
    b[i + 1] = insn >> 8 & 0xFF;
    b[i + 2] = insn >> 16 & 0xFF;
    b[i + 3] = insn >> 24 & 0xFF;
  }
  return b;
}

Uint8List delta(Uint8List b, int distance) {
  for (var i = distance; i < b.length; i++) {
    b[i] = (b[i] + b[i - distance]) & 0xFF;
  }
  return b;
}
