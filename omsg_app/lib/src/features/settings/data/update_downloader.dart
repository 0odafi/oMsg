import 'update_download_models.dart';
import 'update_downloader_stub.dart'
    if (dart.library.io) 'update_downloader_io.dart' as impl;

export 'update_download_models.dart';

Future<DownloadedUpdatePackage> downloadUpdatePackage({
  required String downloadUrl,
  required String fileName,
  String? expectedSha256,
  void Function(double progress)? onProgress,
}) {
  return impl.downloadUpdatePackage(
    downloadUrl: downloadUrl,
    fileName: fileName,
    expectedSha256: expectedSha256,
    onProgress: onProgress,
  );
}
