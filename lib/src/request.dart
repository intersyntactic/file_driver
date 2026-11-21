import 'package:is_effects/is_effects.dart';

/// What the airlock asks the file driver to do, as it crosses the socket.
sealed class FileRequest {
  const FileRequest();

  static FileRequest fromJson(Object? json) => switch (json) {
    {'kind': 'read', 'path': final Object? path} => ReadRequest(
      decodeRelativePath(path),
    ),
    {'kind': 'readBytes', 'path': final Object? path} => ReadBytesRequest(
      decodeRelativePath(path),
    ),
    {'kind': 'write', 'file': final Object? file} => WriteRequest(
      decodeFileText(file),
    ),
    _ => throw const FormatException(
      'not {"kind": "read" | "readBytes", "path"} or '
      '{"kind": "write", "file"}',
    ),
  };

  Object? toJson();
}

final class ReadRequest extends FileRequest {
  const ReadRequest(this.path);

  final RelativePath path;

  @override
  Object? toJson() => {'kind': 'read', 'path': encodeRelativePath(path)};
}

final class ReadBytesRequest extends FileRequest {
  const ReadBytesRequest(this.path);

  final RelativePath path;

  @override
  Object? toJson() => {'kind': 'readBytes', 'path': encodeRelativePath(path)};
}

final class WriteRequest extends FileRequest {
  const WriteRequest(this.file);

  final FileText file;

  @override
  Object? toJson() => {'kind': 'write', 'file': encodeFileText(file)};
}
