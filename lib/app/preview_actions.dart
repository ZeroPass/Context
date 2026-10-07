import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'clipboard_writer.dart';
import 'file_references.dart';
import 'workspace_paths.dart';

typedef PreviewSavePicker = Future<String?> Function(String path);

class PreviewActions {
  PreviewActions({ClipboardWriter? clipboard, PreviewSavePicker? savePicker})
    : clipboard = clipboard ?? clipboardWriter,
      savePicker = savePicker ?? _pickSave;

  final ClipboardWriter clipboard;
  final PreviewSavePicker savePicker;
  static const maxReadBytes = 64 * 1024 * 1024;
  static const maxImagePixels = 32 * 1024 * 1024;

  static Future<String?> _pickSave(String path) => FilePicker.platform.saveFile(
    dialogTitle: 'Save as',
    fileName: contextPaths(path).basename(path),
    lockParentWindow: true,
  );

  static Future<Uint8List> readBounded(String path, int limit) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in File(path).openRead(0, limit + 1)) {
      bytes.add(chunk);
      if (bytes.length > limit) {
        throw StateError('File is too large to copy. Use Save as instead.');
      }
    }
    return bytes.takeBytes();
  }

  Future<bool> copy(String path, {String? markdown}) async {
    if (isPreviewMarkdown(path)) {
      return clipboard.copyPreparedText(
        () async =>
            markdown ??
            utf8.decode(
              await readBounded(path, 8 * 1024 * 1024),
              allowMalformed: true,
            ),
      );
    }
    if (isPreviewImage(path)) {
      return copyImage(() => readBounded(path, maxReadBytes));
    }
    return clipboard.copyMedia(() async {
      if (!await File(path).exists()) {
        throw StateError('File no longer exists.');
      }
      return File(path).absolute.path;
    }, 'writeFile');
  }

  Future<bool> copyImage(Future<Uint8List> Function() bytes) =>
      clipboard.copyMedia(() async => imageDib(await bytes()), 'writeImage');

  // CF_DIB uses bottom-up BGR pixels. Flatten transparent pixels onto white
  // for compatibility with Windows apps that ignore bitmap alpha channels.
  static Future<Uint8List> imageDib(Uint8List encoded) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width * descriptor.height > maxImagePixels) {
        throw StateError('Image is too large to copy. Use Save as instead.');
      }
      codec = await descriptor.instantiateCodec();
      image = (await codec.getNextFrame()).image;
      final pixels = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (pixels == null) throw StateError('Image pixels unavailable.');
      return await compute(_rgbaDib, (
        width: image.width,
        height: image.height,
        pixels: pixels.buffer.asUint8List(
          pixels.offsetInBytes,
          pixels.lengthInBytes,
        ),
      ));
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<bool> saveAs(String path) async {
    final destination = await savePicker(path);
    if (destination == null || destination.trim().isEmpty) return false;
    final paths = contextPaths(path);
    if (paths.equals(paths.absolute(path), paths.absolute(destination))) {
      throw StateError(
        'Choose a different file to avoid replacing the original.',
      );
    }
    if (await File(destination).exists() &&
        await FileSystemEntity.identical(path, destination)) {
      throw StateError(
        'Choose a different file to avoid replacing the original.',
      );
    }
    // File.copy streams through the OS; videos are never loaded into Dart RAM.
    await File(path).copy(p.normalize(destination));
    return true;
  }
}

final previewActions = PreviewActions();

Uint8List _rgbaDib(({int width, int height, Uint8List pixels}) input) {
  final (:width, :height, :pixels) = input;
  final result = Uint8List(40 + width * height * 4);
  final header = ByteData.sublistView(result);
  header.setUint32(0, 40, Endian.little);
  header.setInt32(4, width, Endian.little);
  header.setInt32(8, height, Endian.little);
  header.setUint16(12, 1, Endian.little);
  header.setUint16(14, 32, Endian.little);
  header.setUint32(20, result.length - 40, Endian.little);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final source = (y * width + x) * 4;
      final target = 40 + ((height - 1 - y) * width + x) * 4;
      final alpha = pixels[source + 3];
      for (var channel = 0; channel < 3; channel++) {
        result[target + channel] =
            (pixels[source + 2 - channel] * alpha +
                255 * (255 - alpha) +
                127) ~/
            255;
      }
      result[target + 3] = 255;
    }
  }
  return result;
}
