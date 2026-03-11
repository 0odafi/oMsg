import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_file/open_file.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../api.dart';
import '../../../core/cache/attachment_cache.dart';
import '../../../core/ui/adaptive_size.dart';
import '../../../core/ui/app_appearance.dart';
import '../../../models.dart';
import '../application/app_preferences.dart';
import '../data/update_downloader.dart';

class SettingsTab extends ConsumerStatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final String appVersion;
  final String updateChannel;
  final Future<void> Function(String channel) onUpdateChannelChanged;
  final Future<void> Function() onLogout;

  const SettingsTab({
    super.key,
    required this.api,
    required this.getTokens,
    required this.appVersion,
    required this.updateChannel,
    required this.onUpdateChannelChanged,
    required this.onLogout,
  });

  @override
  ConsumerState<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<SettingsTab> {
  bool _loadingSettings = false;
  bool _checkingUpdate = false;
  bool _downloadingUpdate = false;
  double? _downloadProgress;
  ReleaseInfo? _latest;
  UserSettingsBundle? _settings;
  bool _loadingSessions = false;
  List<AuthSessionItem> _sessions = const [];
  CachedAttachmentStats _cacheStats = CachedAttachmentStats.empty;
  bool _loadingCacheStats = false;
  DownloadedUpdatePackage? _downloadedUpdate;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadSessions(silent: true);
    _refreshCacheStats();
  }

  Future<void> _loadSettings() async {
    final tokens = widget.getTokens();
    if (tokens == null || _loadingSettings) return;
    setState(() => _loadingSettings = true);
    try {
      final bundle = await widget.api.mySettings(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
      if (!mounted) return;
      setState(() => _settings = bundle);
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) {
        setState(() => _loadingSettings = false);
      }
    }
  }

  Future<void> _loadSessions({bool silent = false}) async {
    final tokens = widget.getTokens();
    if (tokens == null || _loadingSessions) return;
    if (!silent) {
      setState(() => _loadingSessions = true);
    } else {
      _loadingSessions = true;
    }
    try {
      final rows = await widget.api.authSessions(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
      if (!mounted) return;
      setState(() => _sessions = rows);
    } catch (error) {
      if (!silent) {
        _showSnack(error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _loadingSessions = false);
      } else {
        _loadingSessions = false;
      }
    }
  }

  Future<void> _showSessionsManager() async {
    final tokens = widget.getTokens();
    if (tokens == null) {
      _showSnack('Session expired');
      return;
    }
    await _loadSessions(silent: true);
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final localRows = List<AuthSessionItem>.from(_sessions);
        return StatefulBuilder(
          builder: (context, setSheetState) {
            AuthSessionItem? currentSession;
            for (final item in localRows) {
              if (item.isCurrent) {
                currentSession = item;
                break;
              }
            }
            final otherSessions = localRows.where((item) => !item.isCurrent).toList();
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: context.sp(12),
                  right: context.sp(12),
                  top: context.sp(12),
                  bottom: context.sp(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Devices',
                      style: TextStyle(
                        fontSize: context.sp(18),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: context.sp(6)),
                    Text(
                      '${localRows.length} active session(s)',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    SizedBox(height: context.sp(10)),
                    if (currentSession != null) ...[
                      Text(
                        'This device',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: context.sp(14),
                        ),
                      ),
                      SizedBox(height: context.sp(6)),
                      _SessionTile(
                        session: currentSession,
                        trailing: Chip(
                          label: const Text('Current'),
                          avatar: const Icon(Icons.smartphone_rounded),
                        ),
                      ),
                      SizedBox(height: context.sp(10)),
                    ],
                    Row(
                      children: [
                        Text(
                          'Other sessions',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: context.sp(14),
                          ),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: otherSessions.isEmpty
                              ? null
                              : () async {
                                  try {
                                    final revoked = await widget.api
                                        .revokeOtherAuthSessions(
                                      accessToken: tokens.accessToken,
                                      refreshToken: tokens.refreshToken,
                                    );
                                    localRows.removeWhere(
                                      (item) => !item.isCurrent,
                                    );
                                    setSheetState(() {});
                                    if (!mounted) return;
                                    setState(() => _sessions = List<AuthSessionItem>.from(localRows));
                                    _showSnack('Terminated $revoked other session(s)');
                                  } catch (error) {
                                    _showSnack(error.toString());
                                  }
                                },
                          icon: const Icon(Icons.logout_rounded),
                          label: const Text('Terminate all others'),
                        ),
                      ],
                    ),
                    SizedBox(height: context.sp(6)),
                    if (otherSessions.isEmpty)
                      Padding(
                        padding: EdgeInsets.all(context.sp(20)),
                        child: Text(
                          'No other active sessions',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: otherSessions.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final session = otherSessions[index];
                            return _SessionTile(
                              session: session,
                              trailing: IconButton(
                                tooltip: 'Terminate session',
                                onPressed: () async {
                                  try {
                                    final removed = await widget.api.revokeAuthSession(
                                      accessToken: tokens.accessToken,
                                      refreshToken: tokens.refreshToken,
                                      sessionId: session.sessionId,
                                    );
                                    if (!removed) return;
                                    localRows.removeWhere(
                                      (item) => item.sessionId == session.sessionId,
                                    );
                                    setSheetState(() {});
                                    if (!mounted) return;
                                    setState(() => _sessions = List<AuthSessionItem>.from(localRows));
                                    _showSnack('Session terminated');
                                  } catch (error) {
                                    _showSnack(error.toString());
                                  }
                                },
                                icon: const Icon(Icons.close_rounded),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _checkUpdates() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      final release = await widget.api.latestRelease(
        platform: runtimePlatformKey(),
        channel: widget.updateChannel,
      );
      if (!mounted) return;
      setState(() => _latest = release);
      if (release == null) {
        _showSnack('No release found for ${runtimePlatformKey()}');
        return;
      }
      if (_isVersionNewer(release.latestVersion, widget.appVersion)) {
        _showSnack('Update available: ${release.latestVersion}');
      } else {
        _showSnack('You are on latest version');
      }
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _openDownloadExternally() async {
    final link = _latest?.downloadUrl;
    if (link == null || link.isEmpty) return;
    final uri = Uri.parse(widget.api.resolveUrl(link));
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      _showSnack('Cannot open download link');
    }
  }

  Future<void> _downloadUpdateInApp() async {
    final release = _latest;
    if (release == null || _downloadingUpdate) return;

    if (kIsWeb) {
      await _openDownloadExternally();
      return;
    }

    final downloadUrl = widget.api.resolveUrl(release.downloadUrl);
    final uri = Uri.parse(downloadUrl);
    final fileName = uri.pathSegments.isEmpty
        ? 'omsg_update_${release.latestVersion}'
        : uri.pathSegments.last;

    setState(() {
      _downloadingUpdate = true;
      _downloadProgress = 0;
      _downloadedUpdate = null;
    });

    try {
      final package = await downloadUpdatePackage(
        downloadUrl: downloadUrl,
        fileName: fileName,
        expectedSha256: release.sha256,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _downloadProgress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _downloadProgress = 1;
        _downloadedUpdate = package;
      });
      _showSnack(release.sha256?.trim().isNotEmpty == true ? 'Update downloaded and verified' : 'Update downloaded inside the app');
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) {
        setState(() => _downloadingUpdate = false);
      }
    }
  }

  Future<void> _installDownloadedUpdate() async {
    final path = _downloadedUpdate?.path;
    if (path == null || path.isEmpty) return;
    final result = await OpenFile.open(path);
    if (result.type != ResultType.done && mounted) {
      _showSnack('Could not open downloaded package');
    }
  }

  Future<void> _updatePrivacy({
    String? phoneVisibility,
    String? phoneSearchVisibility,
    String? lastSeenVisibility,
    bool? showApproximateLastSeen,
    String? allowGroupInvites,
  }) async {
    final tokens = widget.getTokens();
    final current = _settings;
    if (tokens == null || current == null) return;
    try {
      final updated = await widget.api.updateMyPrivacySettings(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        phoneVisibility: phoneVisibility,
        phoneSearchVisibility: phoneSearchVisibility,
        lastSeenVisibility: lastSeenVisibility,
        showApproximateLastSeen: showApproximateLastSeen,
        allowGroupInvites: allowGroupInvites,
      );
      if (!mounted) return;
      setState(() {
        _settings = UserSettingsBundle(
          privacy: updated,
          dataStorage: current.dataStorage,
          blockedUsersCount: current.blockedUsersCount,
        );
      });
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _updateDataStorage({
    int? keepMediaDays,
    int? storageLimitMb,
    bool? autoDownloadPhotos,
    bool? autoDownloadVideos,
    bool? autoDownloadMusic,
    bool? autoDownloadFiles,
    int? defaultAutoDeleteSeconds,
  }) async {
    final tokens = widget.getTokens();
    final current = _settings;
    if (tokens == null || current == null) return;
    try {
      final updated = await widget.api.updateMyDataStorageSettings(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        keepMediaDays: keepMediaDays,
        storageLimitMb: storageLimitMb,
        autoDownloadPhotos: autoDownloadPhotos,
        autoDownloadVideos: autoDownloadVideos,
        autoDownloadMusic: autoDownloadMusic,
        autoDownloadFiles: autoDownloadFiles,
        defaultAutoDeleteSeconds: defaultAutoDeleteSeconds,
      );
      if (!mounted) return;
      setState(() {
        _settings = UserSettingsBundle(
          privacy: current.privacy,
          dataStorage: updated,
          blockedUsersCount: current.blockedUsersCount,
        );
      });
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _refreshCacheStats() async {
    if (_loadingCacheStats) return;
    if (mounted) {
      setState(() => _loadingCacheStats = true);
    }
    try {
      final stats = await AstraAttachmentCache.instance.stats();
      if (!mounted) return;
      setState(() => _cacheStats = stats);
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) {
        setState(() => _loadingCacheStats = false);
      }
    }
  }

  Future<void> _clearAttachmentCache() async {
    try {
      await AstraAttachmentCache.instance.clear();
      await _refreshCacheStats();
      _showSnack('Downloaded media cache cleared');
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _clearAttachmentMediaClass(String mediaClass) async {
    try {
      await AstraAttachmentCache.instance.clearByMediaClass(mediaClass);
      await _refreshCacheStats();
      _showSnack('${_mediaClassLabel(mediaClass)} removed from local storage');
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _applyKeepMediaRuleNow() async {
    final keepDays = _settings?.dataStorage.keepMediaDays;
    if (keepDays == null) return;
    try {
      await AstraAttachmentCache.instance.pruneOlderThan(Duration(days: keepDays));
      await _refreshCacheStats();
      _showSnack('Applied keep media rule to downloaded files');
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  String _mediaClassLabel(String mediaClass) {
    switch (mediaClass) {
      case 'image':
        return 'Photos';
      case 'video':
        return 'Videos';
      case 'audio':
      case 'voice':
        return 'Audio';
      default:
        return 'Files';
    }
  }

  IconData _mediaClassIcon(String mediaClass) {
    switch (mediaClass) {
      case 'image':
        return Icons.photo_library_outlined;
      case 'video':
        return Icons.smart_display_outlined;
      case 'audio':
      case 'voice':
        return Icons.headphones_rounded;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  Future<void> _openCachedFile(CachedAttachmentEntry entry) async {
    final result = await OpenFile.open(entry.filePath);
    if (result.type != ResultType.done && mounted) {
      _showSnack('Could not open downloaded file');
    }
  }

  Future<void> _showDownloadedMediaManager() async {
    List<CachedAttachmentEntry> rows;
    try {
      rows = await AstraAttachmentCache.instance.listEntries();
    } catch (error) {
      _showSnack(error.toString());
      return;
    }

    if (!mounted) return;
    final queryController = TextEditingController();
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) {
          final localRows = List<CachedAttachmentEntry>.from(rows);
          var activeFilter = 'all';
          var sortMode = 'recent';
          var query = '';

          bool matchesFilter(CachedAttachmentEntry entry) {
            if (activeFilter == 'all') return true;
            if (activeFilter == 'audio') {
              return entry.mediaClass == 'audio' || entry.mediaClass == 'voice';
            }
            return entry.mediaClass == activeFilter;
          }

          int compareEntries(CachedAttachmentEntry left, CachedAttachmentEntry right) {
            switch (sortMode) {
              case 'largest':
                return right.sizeBytes.compareTo(left.sizeBytes);
              case 'oldest':
                return left.lastAccessedAt.compareTo(right.lastAccessedAt);
              case 'name':
                return left.fileName.toLowerCase().compareTo(right.fileName.toLowerCase());
              default:
                return right.lastAccessedAt.compareTo(left.lastAccessedAt);
            }
          }

          List<CachedAttachmentEntry> buildVisibleRows() {
            final normalizedQuery = query.trim().toLowerCase();
            final filtered = localRows.where((entry) {
              if (!matchesFilter(entry)) return false;
              if (normalizedQuery.isEmpty) return true;
              return entry.fileName.toLowerCase().contains(normalizedQuery) ||
                  (entry.chatTitle ?? '').toLowerCase().contains(normalizedQuery);
            }).toList();
            filtered.sort(compareEntries);
            return filtered;
          }

          return StatefulBuilder(
            builder: (context, setSheetState) {
              final visibleRows = buildVisibleRows();
              final visibleBytes = visibleRows.fold<int>(0, (sum, item) => sum + item.sizeBytes);
              return SafeArea(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: context.sp(12),
                    right: context.sp(12),
                    top: context.sp(12),
                    bottom: context.sp(12),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Downloaded media',
                        style: TextStyle(
                          fontSize: context.sp(18),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: context.sp(6)),
                      Text(
                        '${visibleRows.length} shown of ${localRows.length} item(s) • ${_formatStorageBytes(visibleBytes)}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      SizedBox(height: context.sp(10)),
                      TextField(
                        controller: queryController,
                        onChanged: (value) => setSheetState(() => query = value),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search_rounded),
                          hintText: 'Search by file or chat',
                        ),
                      ),
                      SizedBox(height: context.sp(10)),
                      Wrap(
                        spacing: context.sp(8),
                        runSpacing: context.sp(8),
                        children: [
                          _StorageFilterChip(
                            label: 'All',
                            selected: activeFilter == 'all',
                            onSelected: () => setSheetState(() => activeFilter = 'all'),
                          ),
                          _StorageFilterChip(
                            label: 'Photos',
                            selected: activeFilter == 'image',
                            onSelected: () => setSheetState(() => activeFilter = 'image'),
                          ),
                          _StorageFilterChip(
                            label: 'Videos',
                            selected: activeFilter == 'video',
                            onSelected: () => setSheetState(() => activeFilter = 'video'),
                          ),
                          _StorageFilterChip(
                            label: 'Audio',
                            selected: activeFilter == 'audio',
                            onSelected: () => setSheetState(() => activeFilter = 'audio'),
                          ),
                          _StorageFilterChip(
                            label: 'Files',
                            selected: activeFilter == 'file',
                            onSelected: () => setSheetState(() => activeFilter = 'file'),
                          ),
                        ],
                      ),
                      SizedBox(height: context.sp(10)),
                      DropdownButtonFormField<String>(
                        value: sortMode,
                        decoration: const InputDecoration(labelText: 'Sort by'),
                        items: const [
                          DropdownMenuItem(value: 'recent', child: Text('Recently used')),
                          DropdownMenuItem(value: 'largest', child: Text('Largest first')),
                          DropdownMenuItem(value: 'name', child: Text('Name')),
                          DropdownMenuItem(value: 'oldest', child: Text('Oldest first')),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setSheetState(() => sortMode = value);
                          }
                        },
                      ),
                      SizedBox(height: context.sp(10)),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                await _applyKeepMediaRuleNow();
                                final fresh = await AstraAttachmentCache.instance.listEntries();
                                localRows
                                  ..clear()
                                  ..addAll(fresh);
                                if (!context.mounted) return;
                                setSheetState(() {});
                              },
                              icon: const Icon(Icons.auto_delete_outlined),
                              label: const Text('Apply keep-media rule'),
                            ),
                          ),
                          SizedBox(width: context.sp(8)),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: visibleRows.isEmpty
                                  ? null
                                  : () async {
                                      for (final entry in List<CachedAttachmentEntry>.from(visibleRows)) {
                                        await AstraAttachmentCache.instance.deleteEntry(entry.url);
                                      }
                                      localRows.removeWhere((entry) =>
                                          visibleRows.any((visible) => visible.url == entry.url));
                                      if (!context.mounted) return;
                                      setSheetState(() {});
                                      await _refreshCacheStats();
                                    },
                              icon: const Icon(Icons.delete_sweep_outlined),
                              label: Text(
                                activeFilter == 'all' && query.trim().isEmpty
                                    ? 'Clear all shown'
                                    : 'Clear filtered',
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: context.sp(10)),
                      if (visibleRows.isEmpty)
                        Padding(
                          padding: EdgeInsets.all(context.sp(20)),
                          child: Text(
                            'No downloaded items match this filter',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: visibleRows.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final entry = visibleRows[index];
                              return ListTile(
                                leading: CircleAvatar(
                                  child: Icon(_mediaClassIcon(entry.mediaClass)),
                                ),
                                title: Text(
                                  entry.fileName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${_mediaClassLabel(entry.mediaClass)} • ${_formatStorageBytes(entry.sizeBytes)} • ${entry.chatTitle ?? 'Downloads'} • ${_formatStorageMoment(entry.lastAccessedAt)}',
                                ),
                                trailing: Wrap(
                                  spacing: context.sp(4),
                                  children: [
                                    IconButton(
                                      tooltip: 'Open',
                                      onPressed: () => _openCachedFile(entry),
                                      icon: const Icon(Icons.open_in_new_rounded),
                                    ),
                                    IconButton(
                                      tooltip: 'Delete',
                                      onPressed: () async {
                                        await AstraAttachmentCache.instance.deleteEntry(entry.url);
                                        localRows.removeWhere((row) => row.url == entry.url);
                                        if (!context.mounted) return;
                                        setSheetState(() {});
                                        await _refreshCacheStats();
                                      },
                                      icon: const Icon(Icons.delete_outline_rounded),
                                    ),
                                  ],
                                ),
                                onTap: () => _openCachedFile(entry),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      queryController.dispose();
    }
  }

  Future<void> _showChatDownloadEntries(CachedChatStorageBucket bucket) async {
    if (bucket.chatId == null) {
      _showSnack('This storage bucket cannot be managed by chat');
      return;
    }
    final rows = await AstraAttachmentCache.instance.listEntries(chatId: bucket.chatId);
    if (!mounted) return;
    final queryController = TextEditingController();
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) {
          final localRows = List<CachedAttachmentEntry>.from(rows);
          var activeFilter = 'all';
          var sortMode = 'recent';
          var query = '';

          bool matchesFilter(CachedAttachmentEntry entry) {
            if (activeFilter == 'all') return true;
            if (activeFilter == 'audio') {
              return entry.mediaClass == 'audio' || entry.mediaClass == 'voice';
            }
            return entry.mediaClass == activeFilter;
          }

          int compareEntries(CachedAttachmentEntry left, CachedAttachmentEntry right) {
            switch (sortMode) {
              case 'largest':
                return right.sizeBytes.compareTo(left.sizeBytes);
              case 'name':
                return left.fileName.toLowerCase().compareTo(right.fileName.toLowerCase());
              case 'oldest':
                return left.lastAccessedAt.compareTo(right.lastAccessedAt);
              default:
                return right.lastAccessedAt.compareTo(left.lastAccessedAt);
            }
          }

          List<CachedAttachmentEntry> buildVisibleRows() {
            final normalizedQuery = query.trim().toLowerCase();
            final filtered = localRows.where((entry) {
              if (!matchesFilter(entry)) return false;
              if (normalizedQuery.isEmpty) return true;
              return entry.fileName.toLowerCase().contains(normalizedQuery);
            }).toList();
            filtered.sort(compareEntries);
            return filtered;
          }

          return StatefulBuilder(
            builder: (context, setSheetState) {
              final visibleRows = buildVisibleRows();
              final visibleBytes = visibleRows.fold<int>(0, (sum, item) => sum + item.sizeBytes);
              return SafeArea(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: context.sp(12),
                    right: context.sp(12),
                    top: context.sp(12),
                    bottom: context.sp(12),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        bucket.chatTitle,
                        style: TextStyle(
                          fontSize: context.sp(18),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: context.sp(6)),
                      Text(
                        '${visibleRows.length} shown • ${_formatStorageBytes(visibleBytes)}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      SizedBox(height: context.sp(10)),
                      TextField(
                        controller: queryController,
                        onChanged: (value) => setSheetState(() => query = value),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search_rounded),
                          hintText: 'Search files in this chat',
                        ),
                      ),
                      SizedBox(height: context.sp(10)),
                      Wrap(
                        spacing: context.sp(8),
                        runSpacing: context.sp(8),
                        children: [
                          _StorageFilterChip(
                            label: 'All',
                            selected: activeFilter == 'all',
                            onSelected: () => setSheetState(() => activeFilter = 'all'),
                          ),
                          _StorageFilterChip(
                            label: 'Photos',
                            selected: activeFilter == 'image',
                            onSelected: () => setSheetState(() => activeFilter = 'image'),
                          ),
                          _StorageFilterChip(
                            label: 'Videos',
                            selected: activeFilter == 'video',
                            onSelected: () => setSheetState(() => activeFilter = 'video'),
                          ),
                          _StorageFilterChip(
                            label: 'Audio',
                            selected: activeFilter == 'audio',
                            onSelected: () => setSheetState(() => activeFilter = 'audio'),
                          ),
                          _StorageFilterChip(
                            label: 'Files',
                            selected: activeFilter == 'file',
                            onSelected: () => setSheetState(() => activeFilter = 'file'),
                          ),
                        ],
                      ),
                      SizedBox(height: context.sp(10)),
                      DropdownButtonFormField<String>(
                        value: sortMode,
                        decoration: const InputDecoration(labelText: 'Sort by'),
                        items: const [
                          DropdownMenuItem(value: 'recent', child: Text('Recently used')),
                          DropdownMenuItem(value: 'largest', child: Text('Largest first')),
                          DropdownMenuItem(value: 'name', child: Text('Name')),
                          DropdownMenuItem(value: 'oldest', child: Text('Oldest first')),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setSheetState(() => sortMode = value);
                          }
                        },
                      ),
                      SizedBox(height: context.sp(10)),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: visibleRows.isEmpty
                                  ? null
                                  : () async {
                                      for (final entry in List<CachedAttachmentEntry>.from(visibleRows)) {
                                        await AstraAttachmentCache.instance.deleteEntry(entry.url);
                                      }
                                      localRows.removeWhere((entry) =>
                                          visibleRows.any((visible) => visible.url == entry.url));
                                      if (!context.mounted) return;
                                      setSheetState(() {});
                                      await _refreshCacheStats();
                                    },
                              icon: const Icon(Icons.delete_sweep_outlined),
                              label: const Text('Clear shown'),
                            ),
                          ),
                          SizedBox(width: context.sp(8)),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: localRows.isEmpty
                                  ? null
                                  : () async {
                                      await AstraAttachmentCache.instance.clearByChat(bucket.chatId!);
                                      localRows.clear();
                                      if (!context.mounted) return;
                                      setSheetState(() {});
                                      await _refreshCacheStats();
                                    },
                              icon: const Icon(Icons.forum_outlined),
                              label: const Text('Clear whole chat'),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: context.sp(10)),
                      if (visibleRows.isEmpty)
                        Padding(
                          padding: EdgeInsets.all(context.sp(20)),
                          child: const Text('No downloads in this chat'),
                        )
                      else
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: visibleRows.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final entry = visibleRows[index];
                              return ListTile(
                                leading: CircleAvatar(
                                  child: Icon(_mediaClassIcon(entry.mediaClass)),
                                ),
                                title: Text(
                                  entry.fileName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${_mediaClassLabel(entry.mediaClass)} • ${_formatStorageBytes(entry.sizeBytes)} • ${_formatStorageMoment(entry.lastAccessedAt)}',
                                ),
                                trailing: IconButton(
                                  tooltip: 'Delete',
                                  onPressed: () async {
                                    await AstraAttachmentCache.instance.deleteEntry(entry.url);
                                    localRows.removeWhere((row) => row.url == entry.url);
                                    if (!context.mounted) return;
                                    setSheetState(() {});
                                    await _refreshCacheStats();
                                  },
                                  icon: const Icon(Icons.delete_outline_rounded),
                                ),
                                onTap: () => _openCachedFile(entry),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      queryController.dispose();
    }
  }

  Future<void> _showDownloadsByChatsManager() async {
    List<CachedChatStorageBucket> buckets;
    try {
      buckets = await AstraAttachmentCache.instance.statsByChats();
    } catch (error) {
      _showSnack(error.toString());
      return;
    }
    if (!mounted) return;
    final queryController = TextEditingController();
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) {
          final localBuckets = List<CachedChatStorageBucket>.from(buckets);
          var activeFilter = 'all';
          var sortMode = 'largest';
          var query = '';

          bool matchesFilter(CachedChatStorageBucket bucket) {
            switch (activeFilter) {
              case 'image':
                return bucket.photoItems > 0;
              case 'video':
                return bucket.videoItems > 0;
              case 'audio':
                return bucket.audioItems > 0;
              case 'file':
                return bucket.fileItems > 0;
              default:
                return true;
            }
          }

          int compareBuckets(CachedChatStorageBucket left, CachedChatStorageBucket right) {
            switch (sortMode) {
              case 'name':
                return left.chatTitle.toLowerCase().compareTo(right.chatTitle.toLowerCase());
              case 'items':
                return right.totalItems.compareTo(left.totalItems);
              default:
                return right.totalBytes.compareTo(left.totalBytes);
            }
          }

          List<CachedChatStorageBucket> buildVisibleBuckets() {
            final normalizedQuery = query.trim().toLowerCase();
            final filtered = localBuckets.where((bucket) {
              if (!matchesFilter(bucket)) return false;
              if (normalizedQuery.isEmpty) return true;
              return bucket.chatTitle.toLowerCase().contains(normalizedQuery);
            }).toList();
            filtered.sort(compareBuckets);
            return filtered;
          }

          return StatefulBuilder(
            builder: (context, setSheetState) {
              final visibleBuckets = buildVisibleBuckets();
              final visibleBytes = visibleBuckets.fold<int>(0, (sum, item) => sum + item.totalBytes);
              return SafeArea(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: context.sp(12),
                    right: context.sp(12),
                    top: context.sp(12),
                    bottom: context.sp(12),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Storage by chats',
                        style: TextStyle(
                          fontSize: context.sp(18),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: context.sp(6)),
                      Text(
                        '${visibleBuckets.length} chats • ${_formatStorageBytes(visibleBytes)}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      SizedBox(height: context.sp(10)),
                      TextField(
                        controller: queryController,
                        onChanged: (value) => setSheetState(() => query = value),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search_rounded),
                          hintText: 'Search chats',
                        ),
                      ),
                      SizedBox(height: context.sp(10)),
                      Wrap(
                        spacing: context.sp(8),
                        runSpacing: context.sp(8),
                        children: [
                          _StorageFilterChip(
                            label: 'All',
                            selected: activeFilter == 'all',
                            onSelected: () => setSheetState(() => activeFilter = 'all'),
                          ),
                          _StorageFilterChip(
                            label: 'Photos',
                            selected: activeFilter == 'image',
                            onSelected: () => setSheetState(() => activeFilter = 'image'),
                          ),
                          _StorageFilterChip(
                            label: 'Videos',
                            selected: activeFilter == 'video',
                            onSelected: () => setSheetState(() => activeFilter = 'video'),
                          ),
                          _StorageFilterChip(
                            label: 'Audio',
                            selected: activeFilter == 'audio',
                            onSelected: () => setSheetState(() => activeFilter = 'audio'),
                          ),
                          _StorageFilterChip(
                            label: 'Files',
                            selected: activeFilter == 'file',
                            onSelected: () => setSheetState(() => activeFilter = 'file'),
                          ),
                        ],
                      ),
                      SizedBox(height: context.sp(10)),
                      DropdownButtonFormField<String>(
                        value: sortMode,
                        decoration: const InputDecoration(labelText: 'Sort by'),
                        items: const [
                          DropdownMenuItem(value: 'largest', child: Text('Largest first')),
                          DropdownMenuItem(value: 'items', child: Text('Most items')),
                          DropdownMenuItem(value: 'name', child: Text('Name')),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setSheetState(() => sortMode = value);
                          }
                        },
                      ),
                      SizedBox(height: context.sp(12)),
                      if (visibleBuckets.isEmpty)
                        Padding(
                          padding: EdgeInsets.all(context.sp(20)),
                          child: const Text('No chat downloads match this filter'),
                        )
                      else
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: visibleBuckets.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final bucket = visibleBuckets[index];
                              return ListTile(
                                leading: CircleAvatar(
                                  child: const Icon(Icons.forum_outlined),
                                ),
                                title: Text(bucket.chatTitle),
                                subtitle: Text(
                                  '${bucket.totalItems} item(s) • ${_formatStorageBytes(bucket.totalBytes)} • ${bucket.photoItems} photos • ${bucket.videoItems} videos • ${bucket.audioItems} audio • ${bucket.fileItems} files',
                                ),
                                trailing: IconButton(
                                  tooltip: 'Clear chat media',
                                  onPressed: bucket.chatId == null
                                      ? null
                                      : () async {
                                          await AstraAttachmentCache.instance.clearByChat(bucket.chatId!);
                                          localBuckets.removeWhere((row) => row.chatId == bucket.chatId);
                                          if (!context.mounted) return;
                                          setSheetState(() {});
                                          await _refreshCacheStats();
                                        },
                                  icon: const Icon(Icons.delete_sweep_outlined),
                                ),
                                onTap: () async {
                                  await _showChatDownloadEntries(bucket);
                                  final fresh = await AstraAttachmentCache.instance.statsByChats();
                                  localBuckets
                                    ..clear()
                                    ..addAll(fresh);
                                  if (!context.mounted) return;
                                  setSheetState(() {});
                                },
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      queryController.dispose();
    }
  }

  Future<void> _showBlockedUsersSheet() async {
    final tokens = widget.getTokens();
    if (tokens == null) {
      _showSnack('Session expired');
      return;
    }

    List<BlockedUserItem> blocked;
    try {
      blocked = await widget.api.blockedUsers(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
    } catch (error) {
      _showSnack(error.toString());
      return;
    }

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final rows = List<BlockedUserItem>.from(blocked);
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: context.sp(12),
                  right: context.sp(12),
                  top: context.sp(12),
                  bottom: context.sp(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Blocked users',
                      style: TextStyle(
                        fontSize: context.sp(18),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: context.sp(10)),
                    if (rows.isEmpty)
                      Padding(
                        padding: EdgeInsets.all(context.sp(20)),
                        child: const Text('No blocked users'),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: rows.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            return ListTile(
                              leading: CircleAvatar(
                                child: Text(
                                  (row.user.displayName.trim().isEmpty
                                          ? '?'
                                          : row.user.displayName.characters.first)
                                      .toUpperCase(),
                                ),
                              ),
                              title: Text(row.user.displayName),
                              subtitle: Text(
                                row.user.publicHandle ?? row.user.phone ?? '',
                              ),
                              trailing: TextButton(
                                onPressed: () async {
                                  final removed = await widget.api.unblockUser(
                                    accessToken: tokens.accessToken,
                                    refreshToken: tokens.refreshToken,
                                    userId: row.user.id,
                                  );
                                  if (!removed || !context.mounted) return;
                                  setSheetState(() => rows.removeAt(index));
                                  if (mounted && _settings != null) {
                                    setState(() {
                                      _settings = UserSettingsBundle(
                                        privacy: _settings!.privacy,
                                        dataStorage: _settings!.dataStorage,
                                        blockedUsersCount:
                                            ((_settings!.blockedUsersCount - 1)
                                                .clamp(0, 1 << 31))
                                            .toInt(),
                                      );
                                    });
                                  }
                                },
                                child: const Text('Unblock'),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<AppUser?> _pickUserForPrivacyException({
    required String settingKey,
    required String mode,
  }) async {
    final tokens = widget.getTokens();
    if (tokens == null) {
      _showSnack('Session expired');
      return null;
    }

    final queryController = TextEditingController();
    var results = <AppUser>[];
    var loading = false;
    String? errorText;

    try {
      return await showDialog<AppUser>(
        context: context,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              Future<void> performSearch() async {
                final query = queryController.text.trim();
                if (query.isEmpty) {
                  setDialogState(() {
                    results = const <AppUser>[];
                    errorText = 'Enter a name, username, or phone';
                  });
                  return;
                }
                setDialogState(() {
                  loading = true;
                  errorText = null;
                });
                try {
                  final found = await widget.api.searchUsers(
                    accessToken: tokens.accessToken,
                    refreshToken: tokens.refreshToken,
                    query: query,
                  );
                  if (!context.mounted) return;
                  setDialogState(() {
                    results = found;
                    errorText = found.isEmpty ? 'No users found' : null;
                  });
                } catch (error) {
                  if (!context.mounted) return;
                  setDialogState(() => errorText = error.toString());
                } finally {
                  if (context.mounted) {
                    setDialogState(() => loading = false);
                  }
                }
              }

              return AlertDialog(
                title: Text(
                  mode == 'allow'
                      ? 'Always allow for ${_privacySettingShortLabel(settingKey)}'
                      : 'Never allow for ${_privacySettingShortLabel(settingKey)}',
                ),
                content: SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: queryController,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        decoration: const InputDecoration(
                          hintText: 'Search users',
                          prefixIcon: Icon(Icons.search_rounded),
                        ),
                        onSubmitted: (_) => unawaited(performSearch()),
                      ),
                      SizedBox(height: context.sp(12)),
                      if (loading)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: CircularProgressIndicator(),
                        )
                      else if (errorText != null)
                        Padding(
                          padding: EdgeInsets.all(context.sp(12)),
                          child: Text(
                            errorText!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      else if (results.isEmpty)
                        Padding(
                          padding: EdgeInsets.all(context.sp(12)),
                          child: const Text('Search for a user to add'),
                        )
                      else
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: results.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final user = results[index];
                              return ListTile(
                                leading: CircleAvatar(
                                  child: Text(
                                    (user.displayName.trim().isEmpty
                                            ? '?'
                                            : user.displayName.characters.first)
                                        .toUpperCase(),
                                  ),
                                ),
                                title: Text(user.displayName),
                                subtitle: Text(
                                  user.publicHandle ?? user.phone ?? '',
                                ),
                                onTap: () => Navigator.of(context).pop(user),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: loading ? null : () => unawaited(performSearch()),
                    child: const Text('Search'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      queryController.dispose();
    }
  }

  Future<void> _showPrivacyExceptionManager({
    required String settingKey,
    required String title,
    required String description,
  }) async {
    final tokens = widget.getTokens();
    if (tokens == null) {
      _showSnack('Session expired');
      return;
    }

    List<PrivacyExceptionItem> rows;
    try {
      rows = await widget.api.privacyExceptions(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        settingKey: settingKey,
      );
    } catch (error) {
      _showSnack(error.toString());
      return;
    }

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final localRows = List<PrivacyExceptionItem>.from(rows);
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final allowRows = localRows.where((item) => item.isAllow).toList();
            final disallowRows = localRows
                .where((item) => item.isDisallow)
                .toList();

            Future<void> addException(String mode) async {
              final picked = await _pickUserForPrivacyException(
                settingKey: settingKey,
                mode: mode,
              );
              if (picked == null) return;
              try {
                final saved = await widget.api.upsertPrivacyException(
                  accessToken: tokens.accessToken,
                  refreshToken: tokens.refreshToken,
                  settingKey: settingKey,
                  mode: mode,
                  targetUserId: picked.id,
                );
                localRows.removeWhere(
                  (item) => item.targetUserId == saved.targetUserId,
                );
                localRows.add(saved);
                if (!context.mounted) return;
                setSheetState(() {});
              } catch (error) {
                _showSnack(error.toString());
              }
            }

            Future<void> removeException(PrivacyExceptionItem item) async {
              try {
                final removed = await widget.api.deletePrivacyException(
                  accessToken: tokens.accessToken,
                  refreshToken: tokens.refreshToken,
                  settingKey: settingKey,
                  targetUserId: item.targetUserId,
                );
                if (!removed || !context.mounted) return;
                localRows.removeWhere((row) => row.id == item.id);
                setSheetState(() {});
              } catch (error) {
                _showSnack(error.toString());
              }
            }

            Widget buildSection({
              required String heading,
              required IconData icon,
              required List<PrivacyExceptionItem> items,
              required String emptyLabel,
            }) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: context.sp(18)),
                      SizedBox(width: context.sp(8)),
                      Text(
                        heading,
                        style: TextStyle(
                          fontSize: context.sp(14),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: context.sp(8)),
                  if (items.isEmpty)
                    Padding(
                      padding: EdgeInsets.only(bottom: context.sp(8)),
                      child: Text(
                        emptyLabel,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    Column(
                      children: items
                          .map(
                            (item) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: CircleAvatar(
                                child: Text(
                                  (item.user.displayName.trim().isEmpty
                                          ? '?'
                                          : item.user.displayName.characters
                                              .first)
                                      .toUpperCase(),
                                ),
                              ),
                              title: Text(item.user.displayName),
                              subtitle: Text(
                                item.user.publicHandle ?? item.user.phone ?? '',
                              ),
                              trailing: IconButton(
                                tooltip: 'Remove',
                                onPressed: () => removeException(item),
                                icon: const Icon(Icons.close_rounded),
                              ),
                            ),
                          )
                          .toList(growable: false),
                    ),
                ],
              );
            }

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: context.sp(12),
                  right: context.sp(12),
                  top: context.sp(12),
                  bottom: context.sp(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: context.sp(18),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: context.sp(6)),
                    Text(
                      description,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    SizedBox(height: context.sp(12)),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => addException('allow'),
                            icon: const Icon(Icons.visibility_rounded),
                            label: const Text('Always allow'),
                          ),
                        ),
                        SizedBox(width: context.sp(8)),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => addException('disallow'),
                            icon: const Icon(Icons.visibility_off_rounded),
                            label: const Text('Never allow'),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: context.sp(12)),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          buildSection(
                            heading: 'Always allow',
                            icon: Icons.visibility_rounded,
                            items: allowRows,
                            emptyLabel: 'No users here yet',
                          ),
                          SizedBox(height: context.sp(8)),
                          buildSection(
                            heading: 'Never allow',
                            icon: Icons.visibility_off_rounded,
                            items: disallowRows,
                            emptyLabel: 'No users here yet',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _privacySettingShortLabel(String settingKey) {
    switch (settingKey) {
      case 'phone_visibility':
        return 'phone number';
      case 'phone_search_visibility':
        return 'phone search';
      case 'last_seen_visibility':
        return 'last seen';
      case 'allow_group_invites':
        return 'group invites';
      default:
        return settingKey;
    }
  }

  bool _isVersionNewer(String candidate, String current) {
    final a = _normalizeVersion(candidate);
    final b = _normalizeVersion(current);
    for (var i = 0; i < a.length; i++) {
      if (a[i] > b[i]) return true;
      if (a[i] < b[i]) return false;
    }
    return false;
  }

  List<int> _normalizeVersion(String raw) {
    final split = raw.split('+');
    final core = split.first;
    final build = split.length > 1 ? int.tryParse(split[1]) ?? 0 : 0;
    final parts = core
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return [parts[0], parts[1], parts[2], build];
  }

  String _shortHash(String value) {
    final normalized = value.trim();
    if (normalized.length <= 16) {
      return normalized;
    }
    return '${normalized.substring(0, 8)}...${normalized.substring(normalized.length - 8)}';
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(appPreferencesProvider);
    final appearance = prefs.appearance;
    final hasUpdate =
        _latest != null &&
        _isVersionNewer(_latest!.latestVersion, widget.appVersion);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: EdgeInsets.all(context.sp(12)),
        children: [
          Card(
            child: Padding(
              padding: EdgeInsets.all(context.sp(14)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Appearance',
                    style: TextStyle(
                      fontSize: context.sp(18),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: context.sp(6)),
                  Text(
                    'Chat palette, message scale, and list density.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  SizedBox(height: context.sp(12)),
                  _AppearancePreview(appearance: appearance),
                  SizedBox(height: context.sp(16)),
                  Text(
                    'Surface',
                    style: TextStyle(
                      fontSize: context.sp(14),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: context.sp(8)),
                  Wrap(
                    spacing: context.sp(8),
                    runSpacing: context.sp(8),
                    children: [
                      for (final preset in ChatSurfacePreset.values)
                        ChoiceChip(
                          label: Text(preset.label),
                          selected: appearance.chatSurfacePreset == preset,
                          onSelected: (_) {
                            ref
                                .read(appPreferencesProvider)
                                .setChatSurfacePreset(preset);
                          },
                        ),
                    ],
                  ),
                  SizedBox(height: context.sp(16)),
                  Text(
                    'Accent',
                    style: TextStyle(
                      fontSize: context.sp(14),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: context.sp(8)),
                  Wrap(
                    spacing: context.sp(8),
                    runSpacing: context.sp(8),
                    children: [
                      for (final preset in ChatAccentPreset.values)
                        ChoiceChip(
                          avatar: CircleAvatar(
                            radius: context.sp(9),
                            backgroundColor: AppAppearanceData(
                              chatSurfacePreset: appearance.chatSurfacePreset,
                              chatAccentPreset: preset,
                              messageTextScale: appearance.messageTextScale,
                              compactChatList: appearance.compactChatList,
                            ).accentColor,
                          ),
                          label: Text(preset.label),
                          selected: appearance.chatAccentPreset == preset,
                          onSelected: (_) {
                            ref
                                .read(appPreferencesProvider)
                                .setChatAccentPreset(preset);
                          },
                        ),
                    ],
                  ),
                  SizedBox(height: context.sp(16)),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Message text size',
                          style: TextStyle(
                            fontSize: context.sp(14),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        '${(appearance.messageTextScale * 100).round()}%',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    min: 0.9,
                    max: 1.3,
                    divisions: 8,
                    value: appearance.messageTextScale,
                    onChanged: (value) {
                      ref
                          .read(appPreferencesProvider)
                          .setMessageTextScale(value);
                    },
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Compact chat list'),
                    subtitle: const Text(
                      'Reduce vertical space in the chat inbox.',
                    ),
                    value: appearance.compactChatList,
                    onChanged: (value) {
                      ref
                          .read(appPreferencesProvider)
                          .setCompactChatList(value);
                    },
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: context.sp(10)),
          _PrivacySettingsCard(
            settings: _settings,
            loading: _loadingSettings,
            onReload: _loadSettings,
            onPrivacyChanged: _updatePrivacy,
            onManagePrivacyExceptions: _showPrivacyExceptionManager,
            onShowBlockedUsers: _showBlockedUsersSheet,
          ),
          SizedBox(height: context.sp(10)),
          _DataStorageSettingsCard(
            settings: _settings,
            loading: _loadingSettings,
            cacheStats: _cacheStats,
            loadingCacheStats: _loadingCacheStats,
            onReload: _loadSettings,
            onDataChanged: _updateDataStorage,
            onClearCache: _clearAttachmentCache,
            onManageDownloads: _showDownloadedMediaManager,
            onManageDownloadsByChats: _showDownloadsByChatsManager,
            onApplyKeepRuleNow: _applyKeepMediaRuleNow,
          ),
          SizedBox(height: context.sp(10)),
          _DevicesSessionsCard(
            sessions: _sessions,
            loading: _loadingSessions,
            onReload: () => _loadSessions(),
            onManageSessions: _showSessionsManager,
          ),
          SizedBox(height: context.sp(10)),
          Card(
            child: Padding(
              padding: EdgeInsets.all(context.sp(14)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Updates',
                    style: TextStyle(
                      fontSize: context.sp(18),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: context.sp(10)),
                  Text('Current version: ${widget.appVersion}'),
                  SizedBox(height: context.sp(10)),
                  DropdownButtonFormField<String>(
                    value: widget.updateChannel,
                    items: const [
                      DropdownMenuItem(value: 'stable', child: Text('stable')),
                      DropdownMenuItem(value: 'beta', child: Text('beta')),
                    ],
                    onChanged: (value) async {
                      if (value == null) return;
                      await widget.onUpdateChannelChanged(value);
                      if (mounted) setState(() {});
                    },
                    decoration: const InputDecoration(labelText: 'Channel'),
                  ),
                  SizedBox(height: context.sp(10)),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _checkingUpdate ? null : _checkUpdates,
                          child: _checkingUpdate
                              ? SizedBox(
                                  width: context.sp(16),
                                  height: context.sp(16),
                                  child: const CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Check updates'),
                        ),
                      ),
                    ],
                  ),
                  if (_latest != null) ...[
                    SizedBox(height: context.sp(10)),
                    Text('Latest: ${_latest!.latestVersion}'),
                    if (_latest!.generatedAt != null &&
                        _latest!.generatedAt!.trim().isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: context.sp(4)),
                        child: Text('Manifest: ${_latest!.generatedAt}'),
                      ),
                    Padding(
                      padding: EdgeInsets.only(top: context.sp(4)),
                      child: Text(
                        'Package: ${_latest!.packageKind} • install: ${_latest!.installStrategy}',
                      ),
                    ),
                    if (_latest!.notes.trim().isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: context.sp(4)),
                        child: Text('Notes: ${_latest!.notes}'),
                      ),
                    if (_latest!.fileSizeBytes != null)
                      Padding(
                        padding: EdgeInsets.only(top: context.sp(4)),
                        child: Text(
                          'Package size: ${_formatStorageBytes(_latest!.fileSizeBytes!)}',
                        ),
                      ),
                    if (_latest!.sha256 != null && _latest!.sha256!.trim().isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: context.sp(4)),
                        child: Text(
                          'SHA-256: ${_shortHash(_latest!.sha256!)}',
                        ),
                      ),
                    if (_downloadProgress != null) ...[
                      SizedBox(height: context.sp(10)),
                      LinearProgressIndicator(value: _downloadProgress),
                      SizedBox(height: context.sp(6)),
                      Text(
                        _downloadingUpdate
                            ? 'Downloading ${(100 * (_downloadProgress ?? 0)).round()}%'
                            : _downloadedUpdate != null
                            ? ((_latest!.sha256?.trim().isNotEmpty == true)
                                  ? 'Downloaded package is verified and ready'
                                  : 'Downloaded package is ready')
                            : 'Download progress is unavailable',
                      ),
                    ],
                    SizedBox(height: context.sp(8)),
                    Wrap(
                      spacing: context.sp(8),
                      runSpacing: context.sp(8),
                      children: [
                        FilledButton.tonal(
                          onPressed: hasUpdate && !_downloadingUpdate
                              ? (_latest!.inAppDownloadSupported
                                    ? _downloadUpdateInApp
                                    : _openDownloadExternally)
                              : null,
                          child: Text(
                            _latest!.inAppDownloadSupported
                                ? 'Download inside app'
                                : 'Open download link',
                          ),
                        ),
                        OutlinedButton(
                          onPressed: _downloadedUpdate == null
                              ? null
                              : _installDownloadedUpdate,
                          child: const Text('Install downloaded update'),
                        ),
                      ],
                    ),
                    if (_latest!.restartRequired)
                      Padding(
                        padding: EdgeInsets.only(top: context.sp(8)),
                        child: Text(
                          'After installer handoff the app can be restarted while keeping local authorization tokens.',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (_downloadedUpdate != null)
                      Padding(
                        padding: EdgeInsets.only(top: context.sp(8)),
                        child: Text(
                          'Installer: ${_downloadedUpdate!.path}\n'
                          'Downloaded: ${_formatStorageBytes(_downloadedUpdate!.fileSizeBytes)} - SHA-256 ${_shortHash(_downloadedUpdate!.sha256)}',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(height: context.sp(10)),
          Card(
            child: ListTile(
              leading: const Icon(Icons.logout_rounded),
              title: const Text('Log out'),
              subtitle: const Text('Keep local appearance settings'),
              onTap: widget.onLogout,
            ),
          ),
        ],
      ),
    );
  }
}

class _PrivacySettingsCard extends StatelessWidget {
  final UserSettingsBundle? settings;
  final bool loading;
  final Future<void> Function() onReload;
  final Future<void> Function({
    String? phoneVisibility,
    String? phoneSearchVisibility,
    String? lastSeenVisibility,
    bool? showApproximateLastSeen,
    String? allowGroupInvites,
  }) onPrivacyChanged;
  final Future<void> Function({
    required String settingKey,
    required String title,
    required String description,
  }) onManagePrivacyExceptions;
  final Future<void> Function() onShowBlockedUsers;

  const _PrivacySettingsCard({
    required this.settings,
    required this.loading,
    required this.onReload,
    required this.onPrivacyChanged,
    required this.onManagePrivacyExceptions,
    required this.onShowBlockedUsers,
  });

  @override
  Widget build(BuildContext context) {
    final bundle = settings;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(context.sp(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Privacy & Security',
              style: TextStyle(
                fontSize: context.sp(18),
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: context.sp(6)),
            Text(
              'Phone number visibility, searchability, last seen mode, group invites, and block list.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: context.sp(10)),
            if (loading && bundle == null)
              const Center(child: CircularProgressIndicator())
            else if (bundle == null)
              FilledButton.tonal(
                onPressed: onReload,
                child: const Text('Load settings'),
              )
            else ...[
              _AudienceSelector(
                label: 'Who can see my phone number',
                subtitle: 'Matches Telegram-style phone visibility control.',
                value: bundle.privacy.phoneVisibility,
                onChanged: (value) => onPrivacyChanged(phoneVisibility: value),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.rule_folder_outlined),
                title: const Text('Phone number exceptions'),
                subtitle: const Text('Always allow / never allow specific users.'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => onManagePrivacyExceptions(
                  settingKey: 'phone_visibility',
                  title: 'Phone number exceptions',
                  description:
                      'Override the base phone visibility rule for selected users.',
                ),
              ),
              SizedBox(height: context.sp(10)),
              _AudienceSelector(
                label: 'Who can find me by my number',
                subtitle: 'Controls phone lookup and search by number.',
                value: bundle.privacy.phoneSearchVisibility,
                onChanged: (value) =>
                    onPrivacyChanged(phoneSearchVisibility: value),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.manage_search_rounded),
                title: const Text('Phone search exceptions'),
                subtitle: const Text('Override phone-based lookup for specific users.'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => onManagePrivacyExceptions(
                  settingKey: 'phone_search_visibility',
                  title: 'Phone search exceptions',
                  description:
                      'Allow or deny phone-number search for selected users.',
                ),
              ),
              SizedBox(height: context.sp(10)),
              _AudienceSelector(
                label: 'Last seen & online',
                subtitle: 'Choose visibility for exact or approximate last seen.',
                value: bundle.privacy.lastSeenVisibility,
                onChanged: (value) => onPrivacyChanged(lastSeenVisibility: value),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.access_time_rounded),
                title: const Text('Last seen exceptions'),
                subtitle: const Text('Allow or hide last seen for selected users.'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => onManagePrivacyExceptions(
                  settingKey: 'last_seen_visibility',
                  title: 'Last seen exceptions',
                  description:
                      'Override the base last seen and online visibility rule.',
                ),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show approximate last seen'),
                subtitle: const Text(
                  'Expose “recently / within a week / within a month” instead of exact time.',
                ),
                value: bundle.privacy.showApproximateLastSeen,
                onChanged: (value) =>
                    onPrivacyChanged(showApproximateLastSeen: value),
              ),
              SizedBox(height: context.sp(6)),
              _AudienceSelector(
                label: 'Who can add me to groups',
                subtitle: 'Foundation for invite and anti-spam controls.',
                value: bundle.privacy.allowGroupInvites,
                onChanged: (value) => onPrivacyChanged(allowGroupInvites: value),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.group_add_rounded),
                title: const Text('Group invite exceptions'),
                subtitle: const Text('Override group invite permissions per user.'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => onManagePrivacyExceptions(
                  settingKey: 'allow_group_invites',
                  title: 'Group invite exceptions',
                  description:
                      'Choose users who can always invite you or never invite you.',
                ),
              ),
              SizedBox(height: context.sp(10)),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.block_rounded),
                title: const Text('Blocked users'),
                subtitle: Text('${bundle.blockedUsersCount} user(s)'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: onShowBlockedUsers,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DataStorageSettingsCard extends StatelessWidget {
  final UserSettingsBundle? settings;
  final bool loading;
  final CachedAttachmentStats cacheStats;
  final bool loadingCacheStats;
  final Future<void> Function() onReload;
  final Future<void> Function({
    int? keepMediaDays,
    int? storageLimitMb,
    bool? autoDownloadPhotos,
    bool? autoDownloadVideos,
    bool? autoDownloadMusic,
    bool? autoDownloadFiles,
    int? defaultAutoDeleteSeconds,
  }) onDataChanged;
  final Future<void> Function() onClearCache;
  final Future<void> Function() onManageDownloads;
  final Future<void> Function() onManageDownloadsByChats;
  final Future<void> Function() onApplyKeepRuleNow;

  const _DataStorageSettingsCard({
    required this.settings,
    required this.loading,
    required this.cacheStats,
    required this.loadingCacheStats,
    required this.onReload,
    required this.onDataChanged,
    required this.onClearCache,
    required this.onManageDownloads,
    required this.onManageDownloadsByChats,
    required this.onApplyKeepRuleNow,
  });

  @override
  Widget build(BuildContext context) {
    final bundle = settings;
    final limitBytes = bundle == null
        ? 0
        : bundle.dataStorage.storageLimitMb * 1024 * 1024;
    final usageFraction = limitBytes <= 0
        ? 0.0
        : (cacheStats.totalBytes / limitBytes).clamp(0.0, 1.0);
    return Card(
      child: Padding(
        padding: EdgeInsets.all(context.sp(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Data & Storage',
              style: TextStyle(
                fontSize: context.sp(18),
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: context.sp(6)),
            Text(
              'Auto-download, media retention, default auto-delete timer, storage limit, and local download manager.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: context.sp(10)),
            if (loading && bundle == null)
              const Center(child: CircularProgressIndicator())
            else if (bundle == null)
              FilledButton.tonal(
                onPressed: onReload,
                child: const Text('Load settings'),
              )
            else ...[
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(context.sp(12)),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(context.sp(16)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Downloaded media',
                          style: TextStyle(
                            fontSize: context.sp(14),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        if (loadingCacheStats)
                          SizedBox(
                            width: context.sp(16),
                            height: context.sp(16),
                            child: const CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          Text(
                            _formatStorageBytes(cacheStats.totalBytes),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: context.sp(10)),
                    Wrap(
                      spacing: context.sp(8),
                      runSpacing: context.sp(8),
                      children: [
                        _StorageSummaryChip(
                          icon: Icons.photo_library_outlined,
                          label: '${cacheStats.photoItems} photos',
                        ),
                        _StorageSummaryChip(
                          icon: Icons.smart_display_outlined,
                          label: '${cacheStats.videoItems} videos',
                        ),
                        _StorageSummaryChip(
                          icon: Icons.headphones_rounded,
                          label: '${cacheStats.audioItems} audio',
                        ),
                        _StorageSummaryChip(
                          icon: Icons.insert_drive_file_outlined,
                          label: '${cacheStats.fileItems} files',
                        ),
                      ],
                    ),
                    SizedBox(height: context.sp(12)),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Using ${_formatStorageBytes(cacheStats.totalBytes)} of ${_formatStorageBytes(limitBytes)} local limit',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '${(usageFraction * 100).round()}%',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: context.sp(6)),
                    LinearProgressIndicator(value: usageFraction),
                    if (usageFraction >= 0.9)
                      Padding(
                        padding: EdgeInsets.only(top: context.sp(6)),
                        child: Text(
                          'Local media storage is close to the configured limit.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(height: context.sp(10)),
              DropdownButtonFormField<int>(
                value: bundle.dataStorage.keepMediaDays,
                decoration: const InputDecoration(labelText: 'Keep media for'),
                items: const [
                  DropdownMenuItem(value: 7, child: Text('7 days')),
                  DropdownMenuItem(value: 30, child: Text('30 days')),
                  DropdownMenuItem(value: 90, child: Text('90 days')),
                  DropdownMenuItem(value: 365, child: Text('1 year')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    onDataChanged(keepMediaDays: value);
                  }
                },
              ),
              SizedBox(height: context.sp(10)),
              DropdownButtonFormField<int>(
                value: bundle.dataStorage.storageLimitMb,
                decoration: const InputDecoration(labelText: 'Storage limit'),
                items: const [
                  DropdownMenuItem(value: 512, child: Text('512 MB')),
                  DropdownMenuItem(value: 1024, child: Text('1 GB')),
                  DropdownMenuItem(value: 2048, child: Text('2 GB')),
                  DropdownMenuItem(value: 4096, child: Text('4 GB')),
                  DropdownMenuItem(value: 8192, child: Text('8 GB')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    onDataChanged(storageLimitMb: value);
                  }
                },
              ),
              SizedBox(height: context.sp(10)),
              DropdownButtonFormField<int>(
                value: bundle.dataStorage.defaultAutoDeleteSeconds ?? 0,
                decoration: const InputDecoration(
                  labelText: 'Default auto-delete timer',
                ),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Off')),
                  DropdownMenuItem(value: 86400, child: Text('1 day')),
                  DropdownMenuItem(value: 604800, child: Text('1 week')),
                  DropdownMenuItem(value: 2592000, child: Text('1 month')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    onDataChanged(
                      defaultAutoDeleteSeconds: value == 0 ? 0 : value,
                    );
                  }
                },
              ),
              SizedBox(height: context.sp(10)),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-download photos'),
                value: bundle.dataStorage.autoDownloadPhotos,
                onChanged: (value) => onDataChanged(autoDownloadPhotos: value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-download videos'),
                value: bundle.dataStorage.autoDownloadVideos,
                onChanged: (value) => onDataChanged(autoDownloadVideos: value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-download music & voice'),
                value: bundle.dataStorage.autoDownloadMusic,
                onChanged: (value) => onDataChanged(autoDownloadMusic: value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-download files'),
                value: bundle.dataStorage.autoDownloadFiles,
                onChanged: (value) => onDataChanged(autoDownloadFiles: value),
              ),
              SizedBox(height: context.sp(8)),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onManageDownloads,
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('Manage downloads'),
                    ),
                  ),
                  SizedBox(width: context.sp(8)),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onManageDownloadsByChats,
                      icon: const Icon(Icons.forum_outlined),
                      label: const Text('Storage by chats'),
                    ),
                  ),
                ],
              ),
              SizedBox(height: context.sp(8)),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onApplyKeepRuleNow,
                      icon: const Icon(Icons.auto_delete_outlined),
                      label: const Text('Apply keep rule now'),
                    ),
                  ),
                  SizedBox(width: context.sp(8)),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onClearCache,
                      icon: const Icon(Icons.delete_sweep_outlined),
                      label: const Text('Clear cache'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DevicesSessionsCard extends StatelessWidget {
  final List<AuthSessionItem> sessions;
  final bool loading;
  final Future<void> Function() onReload;
  final Future<void> Function() onManageSessions;

  const _DevicesSessionsCard({
    required this.sessions,
    required this.loading,
    required this.onReload,
    required this.onManageSessions,
  });

  @override
  Widget build(BuildContext context) {
    final currentSession = sessions.where((item) => item.isCurrent).length;
    final otherSessions = sessions.where((item) => !item.isCurrent).length;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(context.sp(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Devices',
              style: TextStyle(
                fontSize: context.sp(18),
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: context.sp(6)),
            Text(
              'Manage active sessions, remote logout, and this device state.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: context.sp(10)),
            if (loading)
              const Center(child: CircularProgressIndicator())
            else
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.devices_rounded),
                title: const Text('Active sessions'),
                subtitle: Text(
                  sessions.isEmpty
                      ? 'Load devices and active sessions'
                      : '$currentSession current • $otherSessions other',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: onManageSessions,
              ),
            if (!loading && sessions.isEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonal(
                  onPressed: onReload,
                  child: const Text('Load sessions'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final AuthSessionItem session;
  final Widget? trailing;

  const _SessionTile({required this.session, this.trailing});

  @override
  Widget build(BuildContext context) {
    final lastUsed = session.lastUsedAt == null
        ? 'Unknown activity'
        : 'Last active ${_formatStorageMoment(session.lastUsedAt!)}';
    final created = 'Signed in ${_formatStorageMoment(session.createdAt)}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        child: Icon(
          session.isCurrent
              ? Icons.smartphone_rounded
              : Icons.devices_other_rounded,
        ),
      ),
      title: Text(
        session.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${session.subtitle}\n$lastUsed • $created',
      ),
      isThreeLine: true,
      trailing: trailing,
    );
  }
}

class _StorageFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onSelected;

  const _StorageFilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
    );
  }
}

class _StorageSummaryChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _StorageSummaryChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: context.sp(16)),
      label: Text(label),
    );
  }
}

String _formatStorageBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}

String _formatStorageMoment(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final date = DateTime(local.year, local.month, local.day);
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (date == today) {
    return 'Today $time';
  }
  if (date == today.subtract(const Duration(days: 1))) {
    return 'Yesterday $time';
  }
  return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year} $time';
}

class _AudienceSelector extends StatelessWidget {
  final String label;
  final String subtitle;
  final String value;
  final ValueChanged<String?> onChanged;

  const _AudienceSelector({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      value: value,
      decoration: InputDecoration(
        labelText: label,
        helperText: subtitle,
      ),
      items: const [
        DropdownMenuItem(value: 'everyone', child: Text('Everybody')),
        DropdownMenuItem(value: 'contacts', child: Text('My contacts')),
        DropdownMenuItem(value: 'nobody', child: Text('Nobody')),
      ],
      onChanged: onChanged,
    );
  }
}

class _AppearancePreview extends StatelessWidget {
  final AppAppearanceData appearance;

  const _AppearancePreview({required this.appearance});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(context.sp(12)),
      decoration: BoxDecoration(
        gradient: appearance.chatBackgroundGradient,
        borderRadius: BorderRadius.circular(context.sp(18)),
        border: Border.all(color: appearance.outlineColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Preview',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: context.sp(14),
            ),
          ),
          SizedBox(height: context.sp(12)),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              constraints: BoxConstraints(maxWidth: context.sp(180)),
              padding: EdgeInsets.symmetric(
                horizontal: context.sp(12),
                vertical: context.sp(8),
              ),
              decoration: BoxDecoration(
                color: appearance.incomingBubbleColor,
                borderRadius: BorderRadius.circular(context.sp(14)),
                border: Border.all(color: appearance.incomingBubbleBorderColor),
              ),
              child: Text(
                'Incoming bubble',
                style: TextStyle(fontSize: context.sp(14)),
              ),
            ),
          ),
          SizedBox(height: context.sp(8)),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: BoxConstraints(maxWidth: context.sp(190)),
              padding: EdgeInsets.symmetric(
                horizontal: context.sp(12),
                vertical: context.sp(8),
              ),
              decoration: BoxDecoration(
                color: appearance.outgoingBubbleColor,
                borderRadius: BorderRadius.circular(context.sp(14)),
                border: Border.all(color: appearance.outgoingBubbleBorderColor),
              ),
              child: Text(
                'Accent bubble ${appearance.chatAccentPreset.label}',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: context.sp(14)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
