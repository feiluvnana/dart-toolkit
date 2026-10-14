/// Windows console input mode through kernel32 (no compiled code shipped).
///
/// Dart's raw `io.stdin` on Windows leaves `ENABLE_VIRTUAL_TERMINAL_INPUT`
/// off, so the console drops arrows, Home/End, PgUp/PgDn and F keys and
/// Esc never arrives as a sequence. With the flag on, keys arrive as the
/// same VT bytes macOS and Linux send, so the decoder needs no Windows branch.
library;

import 'dart:ffi';
import 'dart:io' as io;

const _vtInput = 0x0200; // ENABLE_VIRTUAL_TERMINAL_INPUT
const _stdInput = -10; // STD_INPUT_HANDLE

typedef _GetStdC = IntPtr Function(Int32);
typedef _GetStd = int Function(int);
typedef _GetModeC = Int32 Function(IntPtr, Pointer<Uint32>);
typedef _GetMode = int Function(int, Pointer<Uint32>);
typedef _SetModeC = Int32 Function(IntPtr, Uint32);
typedef _SetMode = int Function(int, int);
typedef _AllocC = Pointer<Uint32> Function(Uint32, IntPtr);
typedef _Alloc = Pointer<Uint32> Function(int, int);
typedef _FreeC = IntPtr Function(Pointer<Uint32>);
typedef _Free = int Function(Pointer<Uint32>);

final class _K32 {
  _K32(DynamicLibrary l)
      : std = l.lookupFunction<_GetStdC, _GetStd>('GetStdHandle'),
        get = l.lookupFunction<_GetModeC, _GetMode>('GetConsoleMode'),
        set = l.lookupFunction<_SetModeC, _SetMode>('SetConsoleMode'),
        alloc = l.lookupFunction<_AllocC, _Alloc>('LocalAlloc'),
        free = l.lookupFunction<_FreeC, _Free>('LocalFree');

  final _GetStd std;
  final _GetMode get;
  final _SetMode set;
  final _Alloc alloc;
  final _Free free;
}

_K32? _k32;
_K32? _lib() {
  if (!io.Platform.isWindows) return null;
  try {
    return _k32 ??= _K32(DynamicLibrary.open('kernel32.dll'));
  } catch (_) {
    return null;
  }
}

/// The stdin console mode, or null off Windows or when stdin is no console.
int? inputMode() {
  final k = _lib();
  if (k == null) return null;
  final p = k.alloc(0x40, 4); // LMEM_ZEROINIT
  if (p.address == 0) return null;
  try {
    return k.get(k.std(_stdInput), p) == 0 ? null : p.value;
  } finally {
    k.free(p);
  }
}

/// Set the stdin console mode; a no-op off Windows.
void setInputMode(int mode) {
  final k = _lib();
  if (k != null) k.set(k.std(_stdInput), mode);
}

/// Turn on VT input, keeping every other flag.
void enableVtInput() {
  final mode = inputMode();
  if (mode != null && mode & _vtInput == 0) setInputMode(mode | _vtInput);
}
