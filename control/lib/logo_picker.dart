import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:web/web.dart' as web;

/// Lets the user pick an image and returns it as a PNG data URL, scaled down
/// to at most [maxSide] pixels so the upload stays small. Null if cancelled.
Future<String?> pickLogo({int maxSide = 512}) async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'image/png,image/jpeg,image/webp';
  final chosen = Completer<web.File?>();
  input.addEventListener(
    'change',
    ((web.Event _) {
      if (!chosen.isCompleted) chosen.complete(input.files?.item(0));
    }).toJS,
  );
  input.addEventListener(
    'cancel',
    ((web.Event _) {
      if (!chosen.isCompleted) chosen.complete(null);
    }).toJS,
  );
  input.click();
  final file = await chosen.future;
  if (file == null) return null;
  final url = web.URL.createObjectURL(file);
  try {
    final image = web.HTMLImageElement()..src = url;
    await image.decode().toDart;
    final width = image.naturalWidth, height = image.naturalHeight;
    if (width == 0 || height == 0) return null;
    final scale = math.min(1.0, maxSide / math.max(width, height));
    final canvas = web.HTMLCanvasElement()
      ..width = math.max(1, (width * scale).round())
      ..height = math.max(1, (height * scale).round());
    (canvas.getContext('2d') as web.CanvasRenderingContext2D).drawImage(
      image,
      0,
      0,
      canvas.width,
      canvas.height,
    );
    return canvas.toDataURL('image/png');
  } catch (_) {
    return null;
  } finally {
    web.URL.revokeObjectURL(url);
  }
}
