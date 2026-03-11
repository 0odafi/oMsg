class DownloadedUpdatePackage {
  final String path;
  final int fileSizeBytes;
  final String sha256;

  const DownloadedUpdatePackage({
    required this.path,
    required this.fileSizeBytes,
    required this.sha256,
  });
}
