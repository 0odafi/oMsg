import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

const String kDefaultApiBaseUrl = String.fromEnvironment(
  'OMSG_API_BASE_URL',
  defaultValue: String.fromEnvironment(
    'ASTRALINK_API_BASE_URL',
    defaultValue: 'https://volds.ru',
  ),
);

class ApiException implements Exception {
  final String message;
  final int? statusCode;

  const ApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

String normalizeBaseUrl(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return kDefaultApiBaseUrl;
  return trimmed.endsWith('/')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

String webSocketBase(String baseUrl) {
  if (baseUrl.startsWith('https://')) {
    return 'wss://${baseUrl.substring(8)}';
  }
  if (baseUrl.startsWith('http://')) {
    return 'ws://${baseUrl.substring(7)}';
  }
  return 'wss://$baseUrl';
}

String resolveApiUrl(String baseUrl, String pathOrUrl) {
  final trimmed = pathOrUrl.trim();
  if (trimmed.isEmpty) return normalizeBaseUrl(baseUrl);
  final parsed = Uri.tryParse(trimmed);
  if (parsed != null && parsed.hasScheme) return trimmed;

  final normalizedBase = normalizeBaseUrl(baseUrl);
  if (trimmed.startsWith('/')) {
    return '$normalizedBase$trimmed';
  }
  return '$normalizedBase/$trimmed';
}

String normalizePublicUsername(String value) {
  return value.trim().replaceFirst(RegExp(r'^@+'), '').toLowerCase();
}

String? publicProfileUsernameFromUri(Uri uri) {
  final pathSegments = uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (uri.scheme == 'omsg') {
    if (uri.host.toLowerCase() == 'u' && pathSegments.isNotEmpty) {
      final username = normalizePublicUsername(pathSegments.first);
      return username.isEmpty ? null : username;
    }
    if (pathSegments.length >= 2 && pathSegments.first.toLowerCase() == 'u') {
      final username = normalizePublicUsername(pathSegments[1]);
      return username.isEmpty ? null : username;
    }
    return null;
  }

  if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      pathSegments.length >= 2 &&
      pathSegments.first.toLowerCase() == 'u') {
    final username = normalizePublicUsername(pathSegments[1]);
    return username.isEmpty ? null : username;
  }
  return null;
}

String runtimePlatformKey() {
  if (kIsWeb) return 'web';
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return 'android';
    case TargetPlatform.windows:
      return 'windows';
    default:
      return 'web';
  }
}

typedef RefreshTokenHandler = Future<AuthTokens?> Function(String refreshToken);

class AstraApi {
  final String baseUrl;
  final RefreshTokenHandler? onRefreshToken;

  const AstraApi({required this.baseUrl, this.onRefreshToken});

  String publicProfileUrl(String username) {
    final normalized = normalizePublicUsername(username);
    final uri = Uri.parse(baseUrl);
    return uri
        .replace(path: '/u/$normalized', queryParameters: null, fragment: null)
        .toString();
  }

  String resolveUrl(String pathOrUrl) {
    return resolveApiUrl(baseUrl, pathOrUrl);
  }

  Future<PhoneCodeSession> requestPhoneCode(String phone) async {
    final response = await _request(
      'POST',
      '/api/auth/request-code',
      body: {'phone': phone},
    );
    return PhoneCodeSession.fromJson(_jsonMap(response));
  }

  Future<AuthResult> verifyPhoneCode({
    required String phone,
    required String codeToken,
    required String code,
    String? firstName,
    String? lastName,
  }) async {
    final payload = <String, dynamic>{
      'phone': phone,
      'code_token': codeToken,
      'code': code,
    };
    if (firstName != null && firstName.trim().isNotEmpty) {
      payload['first_name'] = firstName.trim();
    }
    if (lastName != null && lastName.trim().isNotEmpty) {
      payload['last_name'] = lastName.trim();
    }

    final response = await _request(
      'POST',
      '/api/auth/verify-code',
      body: payload,
    );
    final json = _jsonMap(response);
    return _authResultFromJson(json);
  }

  Future<AuthResult> refreshSession(String refreshToken) async {
    final response = await _request(
      'POST',
      '/api/auth/refresh',
      body: {'refresh_token': refreshToken},
    );
    return _authResultFromJson(_jsonMap(response));
  }

  Future<AppUser> me({
    required String accessToken,
    String? refreshToken,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/users/me',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return AppUser.fromJson(_jsonMap(response));
  }

  Future<AppUser> updateMe({
    required String accessToken,
    String? refreshToken,
    String? username,
    String? firstName,
    String? lastName,
    String? bio,
  }) async {
    final payload = <String, dynamic>{};
    if (username != null) payload['username'] = username;
    if (firstName != null) payload['first_name'] = firstName;
    if (lastName != null) payload['last_name'] = lastName;
    if (bio != null) payload['bio'] = bio;

    final response = await _authorizedRequest(
      'PATCH',
      '/api/users/me',
      accessToken: accessToken,
      refreshToken: refreshToken,
      body: payload,
    );
    return AppUser.fromJson(_jsonMap(response));
  }

  Future<UsernameCheckResult> checkUsername({
    required String accessToken,
    String? refreshToken,
    required String username,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/users/username-check?username=${Uri.encodeQueryComponent(username)}',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return UsernameCheckResult.fromJson(_jsonMap(response));
  }

  Future<List<ChatItem>> listChats({
    required String accessToken,
    String? refreshToken,
    bool includeArchived = false,
    bool archivedOnly = false,
    bool pinnedOnly = false,
    String? folder,
  }) async {
    final params = <String, String>{
      if (includeArchived) 'include_archived': 'true',
      if (archivedOnly) 'archived_only': 'true',
      if (pinnedOnly) 'pinned_only': 'true',
      if (folder != null && folder.trim().isNotEmpty) 'folder': folder.trim(),
    };
    final query = params.entries
        .map(
          (entry) =>
              '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
        )
        .join('&');
    final response = await _authorizedRequest(
      'GET',
      '/api/chats${query.isEmpty ? '' : '?$query'}',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return _jsonList(response).map((item) => ChatItem.fromJson(item)).toList();
  }

  Future<ChatItem> openSavedMessagesChat({
    required String accessToken,
    String? refreshToken,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/chats/saved',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return ChatItem.fromJson(_jsonMap(response));
  }

  Future<ChatItem> openPrivateChat({
    required String accessToken,
    String? refreshToken,
    required String query,
  }) async {
    final encodedQuery = Uri.encodeQueryComponent(query);
    final response = await _authorizedRequest(
      'POST',
      '/api/chats/private?query=$encodedQuery',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return ChatItem.fromJson(_jsonMap(response));
  }

  Future<List<MessageItem>> listMessages({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    int limit = 100,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/chats/$chatId/messages?limit=$limit',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return _jsonList(
      response,
    ).map((item) => MessageItem.fromJson(item)).toList();
  }

  Future<MessageCursorPage> listMessagesCursor({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    int limit = 50,
    int? beforeId,
  }) async {
    final query = StringBuffer('limit=$limit');
    if (beforeId != null) {
      query.write('&before_id=$beforeId');
    }
    final response = await _authorizedRequest(
      'GET',
      '/api/chats/$chatId/messages/cursor?$query',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return MessageCursorPage.fromJson(_jsonMap(response));
  }

  Future<List<ScheduledMessageItem>> listScheduledMessages({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    int limit = 100,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/chats/$chatId/scheduled-messages?limit=$limit',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return _jsonList(
      response,
    ).map((item) => ScheduledMessageItem.fromJson(item)).toList();
  }

  Future<ScheduledMessageItem> scheduleMessage({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    required String content,
    DateTime? scheduledFor,
    bool sendWhenUserOnline = false,
    int? replyToMessageId,
    int? forwardFromMessageId,
    List<int> attachmentIds = const [],
  }) async {
    final payload = <String, dynamic>{'content': content};
    if (scheduledFor != null) {
      payload['scheduled_for'] = scheduledFor.toUtc().toIso8601String();
    }
    if (sendWhenUserOnline) {
      payload['send_when_user_online'] = true;
    }
    if (replyToMessageId != null) {
      payload['reply_to_message_id'] = replyToMessageId;
    }
    if (attachmentIds.isNotEmpty) {
      payload['attachment_ids'] = attachmentIds;
    }
    if (forwardFromMessageId != null) {
      payload['forward_from_message_id'] = forwardFromMessageId;
    }
    final response = await _authorizedRequest(
      'POST',
      '/api/chats/$chatId/scheduled-messages',
      accessToken: accessToken,
      refreshToken: refreshToken,
      body: payload,
    );
    return ScheduledMessageItem.fromJson(_jsonMap(response));
  }

  Future<bool> deleteScheduledMessage({
    required String accessToken,
    String? refreshToken,
    required int scheduledMessageId,
  }) async {
    final response = await _authorizedRequest(
      'DELETE',
      '/api/chats/scheduled-messages/$scheduledMessageId',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return (_jsonMap(response)['removed'] ?? false) == true;
  }

  Future<void> updateChatState({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    bool? isArchived,
    bool? isPinned,
    String? folder,
  }) async {
    final payload = <String, dynamic>{};
    if (isArchived != null) payload['is_archived'] = isArchived;
    if (isPinned != null) payload['is_pinned'] = isPinned;
    if (folder != null) payload['folder'] = folder;

    await _authorizedRequest(
      'PATCH',
      '/api/chats/$chatId/state',
      accessToken: accessToken,
      refreshToken: refreshToken,
      body: payload,
    );
  }

  Future<MessageItem> sendMessage({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    required String content,
    int? replyToMessageId,
    int? forwardFromMessageId,
    List<int> attachmentIds = const [],
    String? clientMessageId,
    bool isSilent = false,
  }) async {
    final payload = <String, dynamic>{'content': content};
    if (replyToMessageId != null) {
      payload['reply_to_message_id'] = replyToMessageId;
    }
    if (attachmentIds.isNotEmpty) {
      payload['attachment_ids'] = attachmentIds;
    }
    if (forwardFromMessageId != null) {
      payload['forward_from_message_id'] = forwardFromMessageId;
    }
    if (clientMessageId != null && clientMessageId.trim().isNotEmpty) {
      payload['client_message_id'] = clientMessageId.trim();
    }
    if (isSilent) {
      payload['is_silent'] = true;
    }
    final response = await _authorizedRequest(
      'POST',
      '/api/chats/$chatId/messages',
      accessToken: accessToken,
      refreshToken: refreshToken,
      body: payload,
    );
    return MessageItem.fromJson(_jsonMap(response));
  }

  Future<List<SharedMediaItem>> listSharedMedia({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    String? kind,
    int limit = 200,
  }) async {
    final query = StringBuffer('limit=$limit');
    if (kind != null && kind.trim().isNotEmpty) {
      query.write('&kind=${Uri.encodeQueryComponent(kind.trim())}');
    }
    final response = await _authorizedRequest(
      'GET',
      '/api/chats/$chatId/media?$query',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return _jsonList(response)
        .map((item) => SharedMediaItem.fromJson(item))
        .toList();
  }

  Future<MessageItem> updateMessage({
    required String accessToken,
    String? refreshToken,
    required int messageId,
    required String content,
  }) async {
    final response = await _authorizedRequest(
      'PATCH',
      '/api/chats/messages/$messageId',
      accessToken: accessToken,
      refreshToken: refreshToken,
      body: {'content': content},
    );
    return MessageItem.fromJson(_jsonMap(response));
  }

  Future<bool> deleteMessage({
    required String accessToken,
    String? refreshToken,
    required int messageId,
    String scope = 'all',
  }) async {
    final response = await _authorizedRequest(
      'DELETE',
      '/api/chats/messages/$messageId?scope=${Uri.encodeQueryComponent(scope)}',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    final json = _jsonMap(response);
    return (json['removed'] ?? false) == true;
  }

  Future<int> clearChatHistory({
    required String accessToken,
    String? refreshToken,
    required int chatId,
  }) async {
    final response = await _authorizedRequest(
      'POST',
      '/api/chats/$chatId/history/clear',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return (_jsonMap(response)['removed_count'] ?? 0) as int;
  }

  Future<void> pinMessage({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    required int messageId,
  }) async {
    await _authorizedRequest(
      'POST',
      '/api/chats/$chatId/messages/$messageId/pin',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
  }

  Future<void> unpinMessage({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    required int messageId,
  }) async {
    await _authorizedRequest(
      'DELETE',
      '/api/chats/$chatId/messages/$messageId/pin',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
  }

  Future<void> addReaction({
    required String accessToken,
    String? refreshToken,
    required int messageId,
    required String emoji,
  }) async {
    await _authorizedRequest(
      'POST',
      '/api/chats/messages/$messageId/reactions',
      accessToken: accessToken,
      refreshToken: refreshToken,
      body: {'emoji': emoji},
    );
  }

  Future<void> removeReaction({
    required String accessToken,
    String? refreshToken,
    required int messageId,
    required String emoji,
  }) async {
    await _authorizedRequest(
      'DELETE',
      '/api/chats/messages/$messageId/reactions?emoji=${Uri.encodeQueryComponent(emoji)}',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
  }

  Future<MessageAttachmentItem> uploadChatMedia({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    required String fileName,
    String? filePath,
    Uint8List? bytes,
    String? kindHint,
    String? clientUploadId,
  }) async {
    final firstTry = await _uploadChatMediaRequest(
      accessToken: accessToken,
      chatId: chatId,
      fileName: fileName,
      filePath: filePath,
      bytes: bytes,
      kindHint: kindHint,
      clientUploadId: clientUploadId,
    );
    if (firstTry.statusCode != 401) {
      return MessageAttachmentItem.fromJson(_jsonMap(firstTry));
    }

    if (refreshToken == null ||
        refreshToken.isEmpty ||
        onRefreshToken == null) {
      throw const ApiException('Session expired', statusCode: 401);
    }

    final nextTokens = await onRefreshToken!.call(refreshToken);
    if (nextTokens == null) {
      throw const ApiException('Session expired', statusCode: 401);
    }

    final retried = await _uploadChatMediaRequest(
      accessToken: nextTokens.accessToken,
      chatId: chatId,
      fileName: fileName,
      filePath: filePath,
      bytes: bytes,
      kindHint: kindHint,
      clientUploadId: clientUploadId,
    );
    return MessageAttachmentItem.fromJson(_jsonMap(retried));
  }

  Future<UserSettingsBundle> mySettings({
    required String accessToken,
    String? refreshToken,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/users/me/settings',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return UserSettingsBundle.fromJson(_jsonMap(response));
  }

  Future<List<AuthSessionItem>> authSessions({
    required String accessToken,
    String? refreshToken,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/auth/sessions',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return _jsonList(response)
        .map((item) => AuthSessionItem.fromJson(item))
        .toList();
  }

  Future<bool> revokeAuthSession({
    required String accessToken,
    String? refreshToken,
    required String sessionId,
  }) async {
    final response = await _authorizedRequest(
      'DELETE',
      '/api/auth/sessions/${Uri.encodeComponent(sessionId)}',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return (_jsonMap(response)['removed'] ?? false) == true;
  }

  Future<int> revokeOtherAuthSessions({
    required String accessToken,
    String? refreshToken,
  }) async {
    final response = await _authorizedRequest(
      'POST',
      '/api/auth/sessions/revoke-others',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return (_jsonMap(response)['revoked'] ?? 0) as int;
  }

  Future<UserPrivacySettings> updateMyPrivacySettings({
    required String accessToken,
    String? refreshToken,
    String? phoneVisibility,
    String? phoneSearchVisibility,
    String? lastSeenVisibility,
    bool? showApproximateLastSeen,
    String? allowGroupInvites,
  }) async {
    final payload = <String, dynamic>{};
    if (phoneVisibility != null) payload['phone_visibility'] = phoneVisibility;
    if (phoneSearchVisibility != null) {
      payload['phone_search_visibility'] = phoneSearchVisibility;
    }
    if (lastSeenVisibility != null) {
      payload['last_seen_visibility'] = lastSeenVisibility;
    }
    if (showApproximateLastSeen != null) {
      payload['show_approximate_last_seen'] = showApproximateLastSeen;
    }
    if (allowGroupInvites != null) {
      payload['allow_group_invites'] = allowGroupInvites;
    }
    final response = await _authorizedRequest(
      'PATCH',
      '/api/users/me/settings/privacy',
      accessToken: accessToken,
      refreshToken: refreshToken,
      body: payload,
    );
    return UserPrivacySettings.fromJson(_jsonMap(response));
  }

  Future<UserDataStorageSettings> updateMyDataStorageSettings({
    required String accessToken,
    String? refreshToken,
    int? keepMediaDays,
    int? storageLimitMb,
    bool? autoDownloadPhotos,
    bool? autoDownloadVideos,
    bool? autoDownloadMusic,
    bool? autoDownloadFiles,
    int? defaultAutoDeleteSeconds,
  }) async {
    final payload = <String, dynamic>{};
    if (keepMediaDays != null) payload['keep_media_days'] = keepMediaDays;
    if (storageLimitMb != null) payload['storage_limit_mb'] = storageLimitMb;
    if (autoDownloadPhotos != null) {
      payload['auto_download_photos'] = autoDownloadPhotos;
    }
    if (autoDownloadVideos != null) {
      payload['auto_download_videos'] = autoDownloadVideos;
    }
    if (autoDownloadMusic != null) {
      payload['auto_download_music'] = autoDownloadMusic;
    }
    if (autoDownloadFiles != null) {
      payload['auto_download_files'] = autoDownloadFiles;
    }
    if (defaultAutoDeleteSeconds != null) {
      payload['default_auto_delete_seconds'] = defaultAutoDeleteSeconds;
    }
    final response = await _authorizedRequest(
      'PATCH',
      '/api/users/me/settings/data-storage',
      accessToken: accessToken,
      refreshToken: refreshToken,
      body: payload,
    );
    return UserDataStorageSettings.fromJson(_jsonMap(response));
  }

  Future<List<BlockedUserItem>> blockedUsers({
    required String accessToken,
    String? refreshToken,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/users/blocks',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return _jsonList(
      response,
    ).map((item) => BlockedUserItem.fromJson(item)).toList();
  }

  Future<BlockedUserItem> blockUser({
    required String accessToken,
    String? refreshToken,
    required int userId,
  }) async {
    final response = await _authorizedRequest(
      'POST',
      '/api/users/blocks/$userId',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return BlockedUserItem.fromJson(_jsonMap(response));
  }

  Future<bool> unblockUser({
    required String accessToken,
    String? refreshToken,
    required int userId,
  }) async {
    final response = await _authorizedRequest(
      'DELETE',
      '/api/users/blocks/$userId',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return (_jsonMap(response)['removed'] ?? false) == true;
  }

  Future<List<PrivacyExceptionItem>> privacyExceptions({
    required String accessToken,
    String? refreshToken,
    String? settingKey,
  }) async {
    final query = settingKey == null || settingKey.trim().isEmpty
        ? ''
        : '?setting_key=${Uri.encodeQueryComponent(settingKey.trim())}';
    final response = await _authorizedRequest(
      'GET',
      '/api/users/me/settings/privacy-exceptions$query',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return _jsonList(
      response,
    ).map((item) => PrivacyExceptionItem.fromJson(item)).toList();
  }

  Future<PrivacyExceptionItem> upsertPrivacyException({
    required String accessToken,
    String? refreshToken,
    required String settingKey,
    required String mode,
    required int targetUserId,
  }) async {
    final response = await _authorizedRequest(
      'POST',
      '/api/users/me/settings/privacy-exceptions',
      accessToken: accessToken,
      refreshToken: refreshToken,
      body: {
        'setting_key': settingKey,
        'mode': mode,
        'target_user_id': targetUserId,
      },
    );
    return PrivacyExceptionItem.fromJson(_jsonMap(response));
  }

  Future<bool> deletePrivacyException({
    required String accessToken,
    String? refreshToken,
    required String settingKey,
    required int targetUserId,
  }) async {
    final response = await _authorizedRequest(
      'DELETE',
      '/api/users/me/settings/privacy-exceptions?setting_key=${Uri.encodeQueryComponent(settingKey)}&target_user_id=$targetUserId',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return (_jsonMap(response)['removed'] ?? false) == true;
  }

  Future<List<AppUser>> searchUsers({
    required String accessToken,
    String? refreshToken,
    required String query,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/users/search?q=${Uri.encodeQueryComponent(query)}',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return _jsonList(response).map((item) => AppUser.fromJson(item)).toList();
  }

  Future<AppUser> lookupUser({
    required String accessToken,
    String? refreshToken,
    required String query,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/users/lookup?q=${Uri.encodeQueryComponent(query)}',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return AppUser.fromJson(_jsonMap(response));
  }

  Future<AppUser> publicProfile(String username) async {
    final response = await _request(
      'GET',
      '/api/public/users/${Uri.encodeComponent(normalizePublicUsername(username))}',
    );
    return AppUser.fromJson(_jsonMap(response));
  }

  Future<List<MessageSearchHit>> searchChatMessages({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    required String query,
    int limit = 30,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/chats/$chatId/messages/search?q=${Uri.encodeQueryComponent(query)}&limit=$limit',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return _jsonList(
      response,
    ).map((item) => MessageSearchHit.fromJson(item)).toList();
  }

  Future<MessageContextPage> messageContext({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    required int messageId,
    int beforeLimit = 20,
    int afterLimit = 20,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/chats/$chatId/messages/context/$messageId?before_limit=$beforeLimit&after_limit=$afterLimit',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return MessageContextPage.fromJson(_jsonMap(response));
  }

  Future<List<MessageSearchHit>> searchMessages({
    required String accessToken,
    String? refreshToken,
    required String query,
    int limit = 30,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/chats/messages/search?q=${Uri.encodeQueryComponent(query)}&limit=$limit',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return _jsonList(
      response,
    ).map((item) => MessageSearchHit.fromJson(item)).toList();
  }

  Future<ReleaseInfo?> latestRelease({
    required String platform,
    required String channel,
  }) async {
    final response = await _request(
      'GET',
      '/api/releases/latest/$platform?channel=${Uri.encodeQueryComponent(channel)}',
      allowedStatusCodes: {404},
    );
    if (response.statusCode == 404) return null;
    return ReleaseInfo.fromJson(_jsonMap(response));
  }

  Future<http.Response> _authorizedRequest(
    String method,
    String path, {
    required String accessToken,
    String? refreshToken,
    Map<String, dynamic>? body,
  }) async {
    final firstTry = await _request(
      method,
      path,
      body: body,
      headers: {'Authorization': 'Bearer $accessToken'},
      allowedStatusCodes: {401},
    );
    if (firstTry.statusCode != 401) return firstTry;

    if (refreshToken == null ||
        refreshToken.isEmpty ||
        onRefreshToken == null) {
      throw const ApiException('Session expired', statusCode: 401);
    }

    final nextTokens = await onRefreshToken!.call(refreshToken);
    if (nextTokens == null) {
      throw const ApiException('Session expired', statusCode: 401);
    }

    return _request(
      method,
      path,
      body: body,
      headers: {'Authorization': 'Bearer ${nextTokens.accessToken}'},
    );
  }

  Map<String, String> _clientMetadataHeaders() {
    final platform = runtimePlatformKey();
    final deviceName = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'oMsg Android',
      TargetPlatform.iOS => 'oMsg iOS',
      TargetPlatform.windows => 'oMsg Windows',
      TargetPlatform.macOS => 'oMsg macOS',
      TargetPlatform.linux => 'oMsg Linux',
      _ => kIsWeb ? 'oMsg Web' : 'oMsg Device',
    };
    return {
      'X-oMsg-Client-Platform': platform,
      'X-oMsg-Device-Name': deviceName,
    };
  }

  Future<http.Response> _uploadChatMediaRequest({
    required String accessToken,
    required int chatId,
    required String fileName,
    String? filePath,
    Uint8List? bytes,
    String? kindHint,
    String? clientUploadId,
  }) async {
    http.MultipartFile multipartFile;
    if (!kIsWeb && filePath != null && filePath.trim().isNotEmpty) {
      multipartFile = await http.MultipartFile.fromPath(
        'file',
        filePath,
        filename: fileName,
      );
    } else if (bytes != null) {
      multipartFile = http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: fileName,
      );
    } else {
      throw const ApiException('Selected file is unavailable');
    }

    final query = StringBuffer('chat_id=$chatId');
    final hint = kindHint?.trim();
    if (hint != null && hint.isNotEmpty) {
      query.write('&kind_hint=${Uri.encodeQueryComponent(hint)}');
    }
    final uploadId = clientUploadId?.trim();
    if (uploadId != null && uploadId.isNotEmpty) {
      query.write('&client_upload_id=${Uri.encodeQueryComponent(uploadId)}');
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/api/media/upload?$query'),
    )
      ..headers.addAll(_clientMetadataHeaders())
      ..headers['Accept'] = 'application/json'
      ..headers['Authorization'] = 'Bearer $accessToken'
      ..files.add(multipartFile);

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    if (response.statusCode == 401) {
      return response;
    }
    throw ApiException(
      _extractErrorMessage(response),
      statusCode: response.statusCode,
    );
  }

  Future<http.Response> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    Set<int> allowedStatusCodes = const {},
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final mergedHeaders = <String, String>{
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
      ..._clientMetadataHeaders(),
      ...?headers,
    };

    late http.Response response;
    switch (method) {
      case 'GET':
        response = await http.get(uri, headers: mergedHeaders);
        break;
      case 'POST':
        response = await http.post(
          uri,
          headers: mergedHeaders,
          body: body == null ? null : jsonEncode(body),
        );
        break;
      case 'PATCH':
        response = await http.patch(
          uri,
          headers: mergedHeaders,
          body: body == null ? null : jsonEncode(body),
        );
        break;
      case 'DELETE':
        response = await http.delete(
          uri,
          headers: mergedHeaders,
          body: body == null ? null : jsonEncode(body),
        );
        break;
      default:
        throw ApiException('Unsupported method: $method');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    if (allowedStatusCodes.contains(response.statusCode)) {
      return response;
    }

    throw ApiException(
      _extractErrorMessage(response),
      statusCode: response.statusCode,
    );
  }

  AuthResult _authResultFromJson(Map<String, dynamic> json) {
    return AuthResult(
      tokens: AuthTokens(
        accessToken: (json['access_token'] ?? '').toString(),
        refreshToken: (json['refresh_token'] ?? '').toString(),
      ),
      needsProfileSetup: (json['needs_profile_setup'] ?? false) == true,
      user: AppUser.fromJson((json['user'] as Map).cast<String, dynamic>()),
    );
  }

  Map<String, dynamic> _jsonMap(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw const ApiException('Invalid API response');
  }

  List<Map<String, dynamic>> _jsonList(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw const ApiException('Invalid API response');
    }
    return decoded
        .map((item) => (item as Map).cast<String, dynamic>())
        .toList();
  }

  String _extractErrorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final detail = decoded['detail'];
        if (detail is String && detail.trim().isNotEmpty) return detail;
        if (detail is List && detail.isNotEmpty) {
          return detail.first.toString();
        }
      }
    } catch (_) {
      // ignore parse errors
    }

    if (response.statusCode == 404) return 'Not found';
    if (response.statusCode == 401) return 'Session expired';
    return 'Request failed (${response.statusCode})';
  }
}
