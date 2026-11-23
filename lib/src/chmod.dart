import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

final int Function(ffi.Pointer<Utf8>, int) _libcChmod =
    ffi.DynamicLibrary.process().lookupFunction<
      // mode_t is 32 bits on Linux and 16 on macOS, where a mode, which
      // fits in 16, passed as 32 reads the same.
      ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Uint32),
      int Function(ffi.Pointer<Utf8>, int)
    >('chmod');

/// Sets the permission bits of the file at [path] to [mode], which dart:io
/// cannot do. False when the kernel refuses.
bool chmod(String path, int mode) {
  final p = path.toNativeUtf8();
  try {
    return _libcChmod(p, mode) == 0;
  } finally {
    malloc.free(p);
  }
}
