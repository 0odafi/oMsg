import 'update_download_models.dart';

Future<DownloadedUpdatePackage> downloadUpdatePackage({
  required String downloadUrl,
  required String fileName,
  String? expectedSha256,
  void Function(double progress)? onProgress,
}) {
  throw UnsupportedError('In-app update download is not supported on this platform');
}
