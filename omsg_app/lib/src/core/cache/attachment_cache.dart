import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AttachmentDownloadEvent {
  final double? progress;
  final File? file;

  const AttachmentDownloadEvent({this.progress, this.file});
}

class CachedAttachmentEntry {
  final String url;
  final String filePath;
  final String fileName;
  final String mediaClass;
  final int? chatId;
  final String? chatTitle;
  final int? attachmentId;
  final int sizeBytes;
  final DateTime createdAt;
  final DateTime lastAccessedAt;

  const CachedAttachmentEntry({
    required this.url,
    required this.filePath,
    required this.fileName,
    required this.mediaClass,
    required this.chatId,
    required this.chatTitle,
    required this.attachmentId,
    required this.sizeBytes,
    required this.createdAt,
    required this.lastAccessedAt,
  });

  factory CachedAttachmentEntry.fromJson(Map<String, dynamic> json) {
    return CachedAttachmentEntry(
      url: (json['url'] ?? '').toString(),
      filePath: (json['file_path'] ?? '').toString(),
      fileName: (json['file_name'] ?? '').toString(),
      mediaClass: (json['media_class'] ?? 'file').toString(),
      chatId: json['chat_id'] as int?,
      chatTitle: json['chat_title']?.toString(),
      attachmentId: json['attachment_id'] as int?,
      sizeBytes: (json['size_bytes'] ?? 0) as int,
      createdAt: DateTime.tryParse((json['created_at'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      lastAccessedAt:
          DateTime.tryParse((json['last_accessed_at'] ?? '').toString()) ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'url': url,
      'file_path': filePath,
      'file_name': fileName,
      'media_class': mediaClass,
      'chat_id': chatId,
      'chat_title': chatTitle,
      'attachment_id': attachmentId,
      'size_bytes': sizeBytes,
      'created_at': createdAt.toUtc().toIso8601String(),
      'last_accessed_at': lastAccessedAt.toUtc().toIso8601String(),
    };
  }

  CachedAttachmentEntry copyWith({
    String? filePath,
    String? fileName,
    String? mediaClass,
    int? chatId,
    Object? chatTitle = _sentinelValue,
    int? attachmentId,
    int? sizeBytes,
    DateTime? createdAt,
    DateTime? lastAccessedAt,
  }) {
    return CachedAttachmentEntry(
      url: url,
      filePath: filePath ?? this.filePath,
      fileName: fileName ?? this.fileName,
      mediaClass: mediaClass ?? this.mediaClass,
      chatId: chatId ?? this.chatId,
      chatTitle: identical(chatTitle, _sentinelValue)
          ? this.chatTitle
          : chatTitle as String?,
      attachmentId: attachmentId ?? this.attachmentId,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      createdAt: createdAt ?? this.createdAt,
      lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
    );
  }
}

const Object _sentinelValue = Object();

class CachedAttachmentStats {
  final int totalBytes;
  final int totalItems;
  final int photoItems;
  final int videoItems;
  final int audioItems;
  final int fileItems;

  const CachedAttachmentStats({
    required this.totalBytes,
    required this.totalItems,
    required this.photoItems,
    required this.videoItems,
    required this.audioItems,
    required this.fileItems,
  });

  static const empty = CachedAttachmentStats(
    totalBytes: 0,
    totalItems: 0,
    photoItems: 0,
    videoItems: 0,
    audioItems: 0,
    fileItems: 0,
  );
}

class CachedChatStorageBucket {
  final int? chatId;
  final String chatTitle;
  final int totalBytes;
  final int totalItems;
  final int photoItems;
  final int videoItems;
  final int audioItems;
  final int fileItems;

  const CachedChatStorageBucket({
    required this.chatId,
    required this.chatTitle,
    required this.totalBytes,
    required this.totalItems,
    required this.photoItems,
    required this.videoItems,
    required this.audioItems,
    required this.fileItems,
  });
}

class AstraAttachmentCache {
  AstraAttachmentCache._();

  static final AstraAttachmentCache instance = AstraAttachmentCache._();
  static const String _indexPrefsKey = 'omsgAttachmentCacheIndexV2';

  final BaseCacheManager _cache = CacheManager(
    Config(
      'omsgAttachmentCache',
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 512,
    ),
  );

  Future<File?> getCachedFile(String url) async {
    final cached = await _cache.getFileFromCache(url);
    final file = cached?.file;
    if (file != null) {
      await _recordDownloadedFile(url, file);
    }
    return file;
  }

  Stream<AttachmentDownloadEvent> download(
    String url, {
    String? mediaClass,
    String? fileName,
    int? chatId,
    String? chatTitle,
    int? attachmentId,
  }) async* {
    await for (final response in _cache.getFileStream(
      url,
      withProgress: true,
    )) {
      if (response is DownloadProgress) {
        yield AttachmentDownloadEvent(progress: response.progress);
      } else if (response is FileInfo) {
        await _recordDownloadedFile(
          url,
          response.file,
          mediaClass: mediaClass,
          fileName: fileName,
          chatId: chatId,
          chatTitle: chatTitle,
          attachmentId: attachmentId,
        );
        yield AttachmentDownloadEvent(file: response.file, progress: 1);
      }
    }
  }

  Future<List<CachedAttachmentEntry>> listEntries({
    String? mediaClass,
    int? chatId,
  }) async {
    final index = await _loadIndexMap();
    final staleUrls = <String>[];
    final result = <CachedAttachmentEntry>[];

    for (final entry in index.values) {
      final file = File(entry.filePath);
      if (!await file.exists()) {
        staleUrls.add(entry.url);
        continue;
      }
      if (mediaClass != null && mediaClass.isNotEmpty && entry.mediaClass != mediaClass) {
        continue;
      }
      if (chatId != null && entry.chatId != chatId) {
        continue;
      }
      result.add(entry);
    }

    if (staleUrls.isNotEmpty) {
      for (final url in staleUrls) {
        index.remove(url);
      }
      await _saveIndexMap(index);
    }

    result.sort((a, b) => b.lastAccessedAt.compareTo(a.lastAccessedAt));
    return result;
  }

  Future<CachedAttachmentStats> stats() async {
    final entries = await listEntries();
    if (entries.isEmpty) return CachedAttachmentStats.empty;

    var totalBytes = 0;
    var photoItems = 0;
    var videoItems = 0;
    var audioItems = 0;
    var fileItems = 0;

    for (final entry in entries) {
      totalBytes += entry.sizeBytes;
      switch (entry.mediaClass) {
        case 'image':
          photoItems += 1;
          break;
        case 'video':
          videoItems += 1;
          break;
        case 'audio':
        case 'voice':
          audioItems += 1;
          break;
        default:
          fileItems += 1;
          break;
      }
    }

    return CachedAttachmentStats(
      totalBytes: totalBytes,
      totalItems: entries.length,
      photoItems: photoItems,
      videoItems: videoItems,
      audioItems: audioItems,
      fileItems: fileItems,
    );
  }

  Future<void> deleteEntry(String url) async {
    final index = await _loadIndexMap();
    final entry = index.remove(url);
    if (entry != null) {
      final file = File(entry.filePath);
      if (await file.exists()) {
        await file.delete();
      }
    }
    await _cache.removeFile(url);
    await _saveIndexMap(index);
  }

  Future<void> clearByMediaClass(String mediaClass) async {
    final entries = await listEntries(mediaClass: mediaClass);
    for (final entry in entries) {
      await deleteEntry(entry.url);
    }
  }

  Future<void> clearByChat(int chatId, {String? mediaClass}) async {
    final entries = await listEntries(chatId: chatId, mediaClass: mediaClass);
    for (final entry in entries) {
      await deleteEntry(entry.url);
    }
  }

  Future<List<CachedChatStorageBucket>> statsByChats({String? mediaClass}) async {
    final entries = await listEntries(mediaClass: mediaClass);
    if (entries.isEmpty) return const [];

    final buckets = <String, List<CachedAttachmentEntry>>{};
    for (final entry in entries) {
      final key = '${entry.chatId ?? 0}:${entry.chatTitle ?? 'Downloads'}';
      buckets.putIfAbsent(key, () => <CachedAttachmentEntry>[]).add(entry);
    }

    final result = <CachedChatStorageBucket>[];
    for (final rows in buckets.values) {
      final first = rows.first;
      var totalBytes = 0;
      var photoItems = 0;
      var videoItems = 0;
      var audioItems = 0;
      var fileItems = 0;
      for (final row in rows) {
        totalBytes += row.sizeBytes;
        switch (row.mediaClass) {
          case 'image':
            photoItems += 1;
            break;
          case 'video':
            videoItems += 1;
            break;
          case 'audio':
          case 'voice':
            audioItems += 1;
            break;
          default:
            fileItems += 1;
            break;
        }
      }
      result.add(
        CachedChatStorageBucket(
          chatId: first.chatId,
          chatTitle: (first.chatTitle ?? 'Downloaded files').trim().isEmpty
              ? 'Downloaded files'
              : first.chatTitle!.trim(),
          totalBytes: totalBytes,
          totalItems: rows.length,
          photoItems: photoItems,
          videoItems: videoItems,
          audioItems: audioItems,
          fileItems: fileItems,
        ),
      );
    }
    result.sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
    return result;
  }

  Future<void> pruneOlderThan(Duration age, {String? mediaClass}) async {
    final now = DateTime.now().toUtc();
    final entries = await listEntries(mediaClass: mediaClass);
    for (final entry in entries) {
      if (now.difference(entry.lastAccessedAt) >= age) {
        await deleteEntry(entry.url);
      }
    }
  }

  Future<void> clear() async {
    await _cache.emptyCache();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_indexPrefsKey);
  }

  Future<void> _recordDownloadedFile(
    String url,
    File file, {
    String? mediaClass,
    String? fileName,
    int? chatId,
    String? chatTitle,
    int? attachmentId,
  }) async {
    if (!await file.exists()) return;

    final index = await _loadIndexMap();
    final existing = index[url];
    final now = DateTime.now().toUtc();
    final stat = await file.stat();

    index[url] = CachedAttachmentEntry(
      url: url,
      filePath: file.path,
      fileName: fileName?.trim().isNotEmpty == true
          ? fileName!.trim()
          : existing?.fileName ?? _deriveFileName(url, file),
      mediaClass: (mediaClass ?? existing?.mediaClass ?? _inferMediaClass(url))
          .trim()
          .toLowerCase(),
      chatId: chatId ?? existing?.chatId,
      chatTitle: chatTitle?.trim().isNotEmpty == true
          ? chatTitle!.trim()
          : existing?.chatTitle,
      attachmentId: attachmentId ?? existing?.attachmentId,
      sizeBytes: stat.size,
      createdAt: existing?.createdAt ?? now,
      lastAccessedAt: now,
    );

    await _saveIndexMap(index);
  }

  Future<Map<String, CachedAttachmentEntry>> _loadIndexMap() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_indexPrefsKey);
    if (raw == null || raw.isEmpty) {
      return <String, CachedAttachmentEntry>{};
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return <String, CachedAttachmentEntry>{};
      }
      final result = <String, CachedAttachmentEntry>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final entry = CachedAttachmentEntry.fromJson(
          item.cast<String, dynamic>(),
        );
        if (entry.url.isEmpty) continue;
        result[entry.url] = entry;
      }
      return result;
    } catch (_) {
      return <String, CachedAttachmentEntry>{};
    }
  }

  Future<void> _saveIndexMap(Map<String, CachedAttachmentEntry> index) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = index.values
        .map((entry) => entry.toJson())
        .toList(growable: false);
    await prefs.setString(_indexPrefsKey, jsonEncode(payload));
  }

  String _deriveFileName(String url, File file) {
    final parsed = Uri.tryParse(url);
    final fromUrl = parsed?.pathSegments.isNotEmpty == true
        ? parsed!.pathSegments.last
        : '';
    if (fromUrl.isNotEmpty) {
      return Uri.decodeComponent(fromUrl);
    }
    final segments = file.path.split(RegExp(r'[\\/]'));
    return segments.isEmpty ? 'downloaded_file' : segments.last;
  }

  String _inferMediaClass(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('/image/') ||
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp')) {
      return 'image';
    }
    if (lower.contains('/video/') ||
        lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.webm')) {
      return 'video';
    }
    if (lower.contains('/voice/') || lower.endsWith('.ogg') || lower.endsWith('.opus')) {
      return 'voice';
    }
    if (lower.contains('/audio/') ||
        lower.endsWith('.mp3') ||
        lower.endsWith('.m4a') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.flac') ||
        lower.endsWith('.aac')) {
      return 'audio';
    }
    return 'file';
  }
}
