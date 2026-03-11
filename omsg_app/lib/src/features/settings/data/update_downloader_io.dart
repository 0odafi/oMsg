import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'update_download_models.dart';

Future<DownloadedUpdatePackage> downloadUpdatePackage({
  required String downloadUrl,
  required String fileName,
  String? expectedSha256,
  void Function(double progress)? onProgress,
}) async {
  final supportDir = await getApplicationSupportDirectory();
  final updatesDir = Directory('${supportDir.path}/updates');
  if (!updatesDir.existsSync()) {
    updatesDir.createSync(recursive: true);
  }

  final target = File('${updatesDir.path}/$fileName');
  if (target.existsSync()) {
    target.deleteSync();
  }

  http.Client? client;
  IOSink? sink;
  try {
    client = http.Client();
    final request = http.Request('GET', Uri.parse(downloadUrl));
    final response = await client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Could not download update (${response.statusCode})');
    }

    sink = target.openWrite();
    final totalBytes = response.contentLength;
    final digestOutput = AccumulatorSink<Digest>();
    final digestSink = sha256.startChunkedConversion(digestOutput);

    var receivedBytes = 0;
    await for (final chunk in response.stream) {
      digestSink.add(chunk);
      sink.add(chunk);
      receivedBytes += chunk.length;
      if (totalBytes != null && totalBytes > 0) {
        onProgress?.call(receivedBytes / totalBytes);
      }
    }
    digestSink.close();
    final digest = digestOutput.events.single.toString();

    await sink.flush();
    await sink.close();
    sink = null;
    onProgress?.call(1);

    final expected = expectedSha256?.trim().toLowerCase();
    if (expected != null && expected.isNotEmpty && digest.toLowerCase() != expected) {
      try {
        if (target.existsSync()) {
          target.deleteSync();
        }
      } catch (_) {}
      throw Exception('Downloaded update failed SHA-256 verification');
    }

    return DownloadedUpdatePackage(
      path: target.path,
      fileSizeBytes: receivedBytes,
      sha256: digest,
    );
  } finally {
    await sink?.close();
    client?.close();
  }
}
