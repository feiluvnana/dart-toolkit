part of '../../image.dart';

typedef _Handle = Pointer<Void>;
typedef _U8 = Pointer<Uint8>;

/// The native image calls. Each isolate binds its own: a worker reaches them as the caller does.
final class _ImageNative {
  static final lib = NativeBridge.main.require();

  static final freePtr = lib.lookup<NativeFunction<Void Function(_Handle)>>('tk_image_free');
  static final free = freePtr.asFunction<void Function(_Handle)>();

  static final finalizer = NativeFinalizer(freePtr.cast());

  static final loadFile = lib.lookupFunction<_Handle Function(_U8, IntPtr, Uint32), _Handle Function(_U8, int, int)>(
    'tk_image_load_file',
  );
  static final loadMemory = lib
      .lookupFunction<_Handle Function(_U8, IntPtr, Uint32, Uint32), _Handle Function(_U8, int, int, int)>(
        'tk_image_load_memory',
      );
  static final createBlank = lib
      .lookupFunction<
        _Handle Function(Uint32, Uint32, Uint8, Uint8, Uint8, Uint8),
        _Handle Function(int, int, int, int, int, int)
      >('tk_image_create_blank');

  static final dimensions = lib
      .lookupFunction<
        Int32 Function(_Handle, Pointer<Uint32>, Pointer<Uint32>),
        int Function(_Handle, Pointer<Uint32>, Pointer<Uint32>)
      >('tk_image_dimensions');

  static final probeFile = lib
      .lookupFunction<
        Int32 Function(_U8, IntPtr, Pointer<IntPtr>, Pointer<IntPtr>, Pointer<IntPtr>),
        int Function(_U8, int, Pointer<IntPtr>, Pointer<IntPtr>, Pointer<IntPtr>)
      >('tk_image_probe_file');
  static final probeMemory = lib
      .lookupFunction<
        Int32 Function(_U8, IntPtr, Pointer<IntPtr>, Pointer<IntPtr>, Pointer<IntPtr>),
        int Function(_U8, int, Pointer<IntPtr>, Pointer<IntPtr>, Pointer<IntPtr>)
      >('tk_image_probe_memory');

  static final resize = lib
      .lookupFunction<
        _Handle Function(_Handle, Uint32, Uint32, Uint32, Uint32),
        _Handle Function(_Handle, int, int, int, int)
      >('tk_image_resize');
  static final crop = lib
      .lookupFunction<
        _Handle Function(_Handle, Uint32, Uint32, Uint32, Uint32),
        _Handle Function(_Handle, int, int, int, int)
      >('tk_image_crop');
  static final cropAspect = lib
      .lookupFunction<
        _Handle Function(_Handle, Double, Float, Float),
        _Handle Function(_Handle, double, double, double)
      >('tk_image_crop_aspect');
  static final rotate = lib.lookupFunction<_Handle Function(_Handle, Int32), _Handle Function(_Handle, int)>(
    'tk_image_rotate',
  );
  static final flip = lib.lookupFunction<_Handle Function(_Handle, Bool, Bool), _Handle Function(_Handle, bool, bool)>(
    'tk_image_flip',
  );
  static final pad = lib
      .lookupFunction<
        _Handle Function(_Handle, Uint32, Uint32, Uint32, Uint32, Uint8, Uint8, Uint8, Uint8),
        _Handle Function(_Handle, int, int, int, int, int, int, int, int)
      >('tk_image_pad');
  static final trim = lib.lookupFunction<_Handle Function(_Handle, Uint8), _Handle Function(_Handle, int)>(
    'tk_image_trim',
  );

  static final adjust = lib
      .lookupFunction<
        _Handle Function(_Handle, Float, Float, Float, Float, Float, Float),
        _Handle Function(_Handle, double, double, double, double, double, double)
      >('tk_image_adjust');
  static final grayscale = lib.lookupFunction<_Handle Function(_Handle), _Handle Function(_Handle)>(
    'tk_image_grayscale',
  );
  static final invert = lib.lookupFunction<_Handle Function(_Handle), _Handle Function(_Handle)>('tk_image_invert');
  static final sepia = lib.lookupFunction<_Handle Function(_Handle), _Handle Function(_Handle)>('tk_image_sepia');
  static final blur = lib.lookupFunction<_Handle Function(_Handle, Float), _Handle Function(_Handle, double)>(
    'tk_image_blur',
  );
  static final sharpen = lib
      .lookupFunction<_Handle Function(_Handle, Float, Float), _Handle Function(_Handle, double, double)>(
        'tk_image_sharpen',
      );
  static final denoise = lib.lookupFunction<_Handle Function(_Handle, Uint32), _Handle Function(_Handle, int)>(
    'tk_image_denoise',
  );
  static final vignette = lib.lookupFunction<_Handle Function(_Handle, Float), _Handle Function(_Handle, double)>(
    'tk_image_vignette',
  );

  static final composite = lib
      .lookupFunction<
        _Handle Function(_Handle, _Handle, Int64, Int64, Float, Uint32),
        _Handle Function(_Handle, _Handle, int, int, double, int)
      >('tk_image_composite');
  static final watermark = lib
      .lookupFunction<
        _Handle Function(_Handle, _Handle, Float, Float, Float, Float, Int32, Uint32),
        _Handle Function(_Handle, _Handle, double, double, double, double, int, int)
      >('tk_image_watermark');
  static final mask = lib.lookupFunction<_Handle Function(_Handle, _Handle), _Handle Function(_Handle, _Handle)>(
    'tk_image_mask',
  );
  static final drawText = lib
      .lookupFunction<
        _Handle Function(_Handle, _U8, IntPtr, Int32, Int32, Uint32, Uint32, Uint32, Bool),
        _Handle Function(_Handle, _U8, int, int, int, int, int, int, bool)
      >('tk_image_draw_text');

  static final encodeMemory = lib
      .lookupFunction<
        Int32 Function(_Handle, Uint32, Uint8, Bool, Pointer<Pointer<Uint8>>, Pointer<IntPtr>),
        int Function(_Handle, int, int, bool, Pointer<Pointer<Uint8>>, Pointer<IntPtr>)
      >('tk_image_encode_memory');
  static final deblock = lib.lookupFunction<_Handle Function(_Handle, Float), _Handle Function(_Handle, double)>(
    'tk_image_deblock',
  );
  static final autoLevels = lib
      .lookupFunction<_Handle Function(_Handle, Float, Bool), _Handle Function(_Handle, double, bool)>(
        'tk_image_auto_levels',
      );
  static final sharpness = lib.lookupFunction<Double Function(_Handle), double Function(_Handle)>('tk_image_sharpness');
  static final phashFiles = lib
      .lookupFunction<
        Int32 Function(_U8, IntPtr, Pointer<Uint64>, _U8, IntPtr),
        int Function(_U8, int, Pointer<Uint64>, _U8, int)
      >('tk_image_phash_files');
  static final grid = lib
      .lookupFunction<
        _Handle Function(Pointer<_Handle>, IntPtr, Uint32, Uint32, Uint32, Uint32),
        _Handle Function(Pointer<_Handle>, int, int, int, int, int)
      >('tk_image_grid');
  static final cropSmart = lib.lookupFunction<_Handle Function(_Handle, Double), _Handle Function(_Handle, double)>(
    'tk_image_crop_smart',
  );
  static final hash = lib.lookupFunction<Uint64 Function(_Handle, Uint32), int Function(_Handle, int)>('tk_image_hash');
  static final similarity = lib
      .lookupFunction<
        Int32 Function(_Handle, _Handle, Pointer<Double>),
        int Function(_Handle, _Handle, Pointer<Double>)
      >('tk_image_similarity');
  static final compress = lib
      .lookupFunction<
        Int32 Function(
          _Handle,
          Uint32,
          Uint8,
          Double,
          Uint64,
          Pointer<Pointer<Uint8>>,
          Pointer<IntPtr>,
          Pointer<Uint32>,
          Pointer<Double>,
        ),
        int Function(
          _Handle,
          int,
          int,
          double,
          int,
          Pointer<Pointer<Uint8>>,
          Pointer<IntPtr>,
          Pointer<Uint32>,
          Pointer<Double>,
        )
      >('tk_image_compress');
  static final png = lib
      .lookupFunction<
        Int32 Function(_U8, IntPtr, Bool, Pointer<Pointer<Uint8>>, Pointer<IntPtr>),
        int Function(_U8, int, bool, Pointer<Pointer<Uint8>>, Pointer<IntPtr>)
      >('tk_image_png');
  static final dominantColor = lib.lookupFunction<Uint32 Function(_Handle), int Function(_Handle)>(
    'tk_image_dominant_color',
  );
}
