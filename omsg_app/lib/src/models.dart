class AppUser {
  final int id;
  final String? username;
  final String? phone;
  final String firstName;
  final String lastName;
  final String bio;
  final String? avatarUrl;
  final bool isOnline;
  final DateTime? lastSeenAt;
  final String? lastSeenLabel;

  const AppUser({
    required this.id,
    required this.username,
    required this.phone,
    required this.firstName,
    required this.lastName,
    required this.bio,
    required this.avatarUrl,
    this.isOnline = false,
    this.lastSeenAt,
    this.lastSeenLabel,
  });

  String get displayName {
    final full = [
      firstName,
      lastName,
    ].where((part) => part.trim().isNotEmpty).join(' ').trim();
    if (full.isNotEmpty) return full;
    final handle = username?.trim();
    if (handle != null && handle.isNotEmpty) return handle;
    final phoneValue = phone?.trim();
    if (phoneValue != null && phoneValue.isNotEmpty) return phoneValue;
    return 'Unknown User';
  }

  bool get hasProfileName => firstName.trim().isNotEmpty;

  bool get usernameLooksGenerated {
    final normalized = (username ?? '').trim().toLowerCase();
    final digitsOnlyTail = normalized.replaceFirst(RegExp(r'^user'), '');
    return normalized.startsWith('user') &&
        digitsOnlyTail.isNotEmpty &&
        RegExp(r'^[0-9]+$').hasMatch(digitsOnlyTail);
  }

  String? get publicHandle {
    final value = username?.trim();
    if (value == null || value.isEmpty) return null;
    return '@$value';
  }

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as int,
      username: json['username']?.toString(),
      phone: json['phone']?.toString(),
      firstName: (json['first_name'] ?? '').toString(),
      lastName: (json['last_name'] ?? '').toString(),
      bio: (json['bio'] ?? '').toString(),
      avatarUrl: json['avatar_url']?.toString(),
      isOnline: (json['is_online'] ?? false) == true,
      lastSeenAt: json['last_seen_at'] == null
          ? null
          : DateTime.tryParse(json['last_seen_at'].toString()),
      lastSeenLabel: json['last_seen_label']?.toString(),
    );
  }
}

class AuthTokens {
  final String accessToken;
  final String refreshToken;

  const AuthTokens({required this.accessToken, required this.refreshToken});
}

class AuthResult {
  final AuthTokens tokens;
  final AppUser user;
  final bool needsProfileSetup;

  const AuthResult({
    required this.tokens,
    required this.user,
    required this.needsProfileSetup,
  });
}

class PhoneCodeSession {
  final String phone;
  final String codeToken;
  final int expiresInSeconds;
  final bool isRegistered;

  const PhoneCodeSession({
    required this.phone,
    required this.codeToken,
    required this.expiresInSeconds,
    required this.isRegistered,
  });

  factory PhoneCodeSession.fromJson(Map<String, dynamic> json) {
    return PhoneCodeSession(
      phone: (json['phone'] ?? '').toString(),
      codeToken: (json['code_token'] ?? '').toString(),
      expiresInSeconds: (json['expires_in_seconds'] ?? 0) as int,
      isRegistered: (json['is_registered'] ?? false) as bool,
    );
  }
}

class UsernameCheckResult {
  final String username;
  final bool available;

  const UsernameCheckResult({required this.username, required this.available});

  factory UsernameCheckResult.fromJson(Map<String, dynamic> json) {
    return UsernameCheckResult(
      username: (json['username'] ?? '').toString(),
      available: (json['available'] ?? false) == true,
    );
  }
}

class ChatItem {
  final int id;
  final String title;
  final String type;
  final String? lastMessagePreview;
  final DateTime? lastMessageAt;
  final int unreadCount;
  final bool isArchived;
  final bool isPinned;
  final String? folder;
  final bool isSavedMessages;

  const ChatItem({
    required this.id,
    required this.title,
    required this.type,
    required this.lastMessagePreview,
    required this.lastMessageAt,
    required this.unreadCount,
    required this.isArchived,
    required this.isPinned,
    required this.folder,
    this.isSavedMessages = false,
  });

  factory ChatItem.fromJson(Map<String, dynamic> json) {
    final rawDate = json['last_message_at']?.toString();
    return ChatItem(
      id: json['id'] as int,
      title: (json['title'] ?? '').toString(),
      type: (json['type'] ?? '').toString(),
      lastMessagePreview: json['last_message_preview']?.toString(),
      lastMessageAt: rawDate == null || rawDate.isEmpty
          ? null
          : DateTime.tryParse(rawDate),
      unreadCount: (json['unread_count'] ?? 0) as int,
      isArchived: (json['is_archived'] ?? false) as bool,
      isPinned: (json['is_pinned'] ?? false) as bool,
      folder: json['folder']?.toString(),
      isSavedMessages: (json['is_saved_messages'] ?? false) == true,
    );
  }
}

class MessageSearchHit {
  final int chatId;
  final int messageId;
  final String chatTitle;
  final int senderId;
  final String content;
  final DateTime createdAt;

  const MessageSearchHit({
    required this.chatId,
    required this.messageId,
    required this.chatTitle,
    required this.senderId,
    required this.content,
    required this.createdAt,
  });

  factory MessageSearchHit.fromJson(Map<String, dynamic> json) {
    return MessageSearchHit(
      chatId: json['chat_id'] as int,
      messageId: json['message_id'] as int,
      chatTitle: (json['chat_title'] ?? '').toString(),
      senderId: json['sender_id'] as int,
      content: (json['content'] ?? '').toString(),
      createdAt: DateTime.parse((json['created_at'] ?? '').toString()),
    );
  }
}

class MessageItem {
  final int id;
  final int chatId;
  final int senderId;
  final String content;
  final String? clientMessageId;
  final DateTime createdAt;
  final String status;
  final DateTime? editedAt;
  final int? replyToMessageId;
  final int? forwardedFromMessageId;
  final String? forwardedFromSenderName;
  final String? forwardedFromChatTitle;
  final bool isSilent;
  final bool isPinned;
  final List<MessageReactionItem> reactions;
  final List<MessageAttachmentItem> attachments;

  const MessageItem({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.content,
    required this.clientMessageId,
    required this.createdAt,
    required this.status,
    required this.editedAt,
    this.replyToMessageId,
    this.forwardedFromMessageId,
    this.forwardedFromSenderName,
    this.forwardedFromChatTitle,
    this.isSilent = false,
    this.isPinned = false,
    this.reactions = const [],
    this.attachments = const [],
  });

  factory MessageItem.fromJson(Map<String, dynamic> json) {
    return MessageItem(
      id: json['id'] as int,
      chatId: json['chat_id'] as int,
      senderId: json['sender_id'] as int,
      content: (json['content'] ?? '').toString(),
      clientMessageId: json['client_message_id']?.toString(),
      createdAt: DateTime.parse((json['created_at'] ?? '').toString()),
      status: (json['status'] ?? 'sent').toString(),
      editedAt: json['edited_at'] == null
          ? null
          : DateTime.tryParse(json['edited_at'].toString()),
      replyToMessageId: json['reply_to_message_id'] as int?,
      forwardedFromMessageId: json['forwarded_from_message_id'] as int?,
      forwardedFromSenderName: json['forwarded_from_sender_name']?.toString(),
      forwardedFromChatTitle: json['forwarded_from_chat_title']?.toString(),
      isSilent: (json['is_silent'] ?? false) == true,
      isPinned: (json['is_pinned'] ?? false) == true,
      reactions: ((json['reactions'] as List?) ?? const [])
          .whereType<Map>()
          .map(
            (row) => MessageReactionItem.fromJson(row.cast<String, dynamic>()),
          )
          .toList(),
      attachments: ((json['attachments'] as List?) ?? const [])
          .whereType<Map>()
          .map(
            (row) =>
                MessageAttachmentItem.fromJson(row.cast<String, dynamic>()),
          )
          .toList(),
    );
  }

  bool get hasAttachments => attachments.isNotEmpty;

  MessageItem copyWith({
    int? id,
    int? chatId,
    int? senderId,
    String? content,
    Object? clientMessageId = _sentinel,
    DateTime? createdAt,
    String? status,
    DateTime? editedAt,
    Object? replyToMessageId = _sentinel,
    Object? forwardedFromMessageId = _sentinel,
    Object? forwardedFromSenderName = _sentinel,
    Object? forwardedFromChatTitle = _sentinel,
    bool? isSilent,
    bool? isPinned,
    List<MessageReactionItem>? reactions,
    List<MessageAttachmentItem>? attachments,
  }) {
    return MessageItem(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      senderId: senderId ?? this.senderId,
      content: content ?? this.content,
      clientMessageId: clientMessageId == _sentinel
          ? this.clientMessageId
          : clientMessageId as String?,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      editedAt: editedAt ?? this.editedAt,
      replyToMessageId: replyToMessageId == _sentinel
          ? this.replyToMessageId
          : replyToMessageId as int?,
      forwardedFromMessageId: forwardedFromMessageId == _sentinel
          ? this.forwardedFromMessageId
          : forwardedFromMessageId as int?,
      forwardedFromSenderName: forwardedFromSenderName == _sentinel
          ? this.forwardedFromSenderName
          : forwardedFromSenderName as String?,
      forwardedFromChatTitle: forwardedFromChatTitle == _sentinel
          ? this.forwardedFromChatTitle
          : forwardedFromChatTitle as String?,
      isSilent: isSilent ?? this.isSilent,
      isPinned: isPinned ?? this.isPinned,
      reactions: reactions ?? this.reactions,
      attachments: attachments ?? this.attachments,
    );
  }
}

class MessageReactionItem {
  final String emoji;
  final int count;
  final bool reactedByMe;

  const MessageReactionItem({
    required this.emoji,
    required this.count,
    required this.reactedByMe,
  });

  factory MessageReactionItem.fromJson(Map<String, dynamic> json) {
    return MessageReactionItem(
      emoji: (json['emoji'] ?? '').toString(),
      count: (json['count'] ?? 0) as int,
      reactedByMe: (json['reacted_by_me'] ?? false) == true,
    );
  }
}

class MessageAttachmentItem {
  final int id;
  final String fileName;
  final String mimeType;
  final String mediaKind;
  final int sizeBytes;
  final String url;
  final bool isImage;
  final bool isAudio;
  final bool isVideo;
  final bool isVoice;
  final int? width;
  final int? height;
  final int? durationSeconds;
  final String? thumbnailUrl;

  const MessageAttachmentItem({
    required this.id,
    required this.fileName,
    required this.mimeType,
    required this.mediaKind,
    required this.sizeBytes,
    required this.url,
    required this.isImage,
    required this.isAudio,
    required this.isVideo,
    required this.isVoice,
    required this.width,
    required this.height,
    required this.durationSeconds,
    required this.thumbnailUrl,
  });

  factory MessageAttachmentItem.fromJson(Map<String, dynamic> json) {
    final mimeType = (json['mime_type'] ?? '').toString();
    final normalizedMime = mimeType.toLowerCase();
    final mediaKind = (json['media_kind'] ?? 'file').toString();
    return MessageAttachmentItem(
      id: json['id'] as int,
      fileName: (json['file_name'] ?? '').toString(),
      mimeType: mimeType,
      mediaKind: mediaKind,
      sizeBytes: (json['size_bytes'] ?? 0) as int,
      url: (json['url'] ?? '').toString(),
      isImage: (json['is_image'] ?? mediaKind == 'image') == true,
      isAudio: (json['is_audio'] ??
              mediaKind == 'audio' ||
              mediaKind == 'voice' ||
              normalizedMime.startsWith('audio/')) ==
          true,
      isVideo: (json['is_video'] ??
              mediaKind == 'video' ||
              normalizedMime.startsWith('video/')) ==
          true,
      isVoice: (json['is_voice'] ?? mediaKind == 'voice') == true,
      width: json['width'] as int?,
      height: json['height'] as int?,
      durationSeconds: json['duration_seconds'] as int?,
      thumbnailUrl: json['thumbnail_url']?.toString(),
    );
  }

  String get displayLabel {
    if (fileName.trim().isNotEmpty) return fileName.trim();
    return isVoice
        ? 'Voice message'
        : isAudio
        ? 'Audio'
        : isVideo
        ? 'Video'
        : 'Attachment';
  }

  String get previewLabel {
    if (isVoice) return 'Voice message';
    if (isVideo) return 'Video';
    if (isAudio) return 'Audio';
    if (isImage) return 'Photo';
    return 'File';
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'file_name': fileName,
      'mime_type': mimeType,
      'media_kind': mediaKind,
      'size_bytes': sizeBytes,
      'url': url,
      'is_image': isImage,
      'is_audio': isAudio,
      'is_video': isVideo,
      'is_voice': isVoice,
      'width': width,
      'height': height,
      'duration_seconds': durationSeconds,
      'thumbnail_url': thumbnailUrl,
    };
  }
}

class MessageContextPage {
  final List<MessageItem> items;
  final int anchorMessageId;
  final int? nextBeforeId;

  const MessageContextPage({
    required this.items,
    required this.anchorMessageId,
    required this.nextBeforeId,
  });

  factory MessageContextPage.fromJson(Map<String, dynamic> json) {
    return MessageContextPage(
      items: ((json['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((row) => MessageItem.fromJson(row.cast<String, dynamic>()))
          .toList(),
      anchorMessageId: json['anchor_message_id'] as int,
      nextBeforeId: json['next_before_id'] as int?,
    );
  }
}

class ScheduledMessageItem {
  final int id;
  final int chatId;
  final int senderId;
  final String content;
  final DateTime scheduledFor;
  final bool sendWhenUserOnline;
  final DateTime createdAt;
  final DateTime? sentAt;
  final String status;
  final int? replyToMessageId;
  final int? forwardedFromMessageId;
  final List<MessageAttachmentItem> attachments;

  const ScheduledMessageItem({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.content,
    required this.scheduledFor,
    required this.sendWhenUserOnline,
    required this.createdAt,
    required this.sentAt,
    required this.status,
    required this.replyToMessageId,
    required this.forwardedFromMessageId,
    required this.attachments,
  });

  factory ScheduledMessageItem.fromJson(Map<String, dynamic> json) {
    return ScheduledMessageItem(
      id: json['id'] as int,
      chatId: json['chat_id'] as int,
      senderId: json['sender_id'] as int,
      content: (json['content'] ?? '').toString(),
      scheduledFor: DateTime.parse((json['scheduled_for'] ?? '').toString()),
      sendWhenUserOnline: (json['send_when_user_online'] ?? false) == true,
      createdAt: DateTime.parse((json['created_at'] ?? '').toString()),
      sentAt: json['sent_at'] == null
          ? null
          : DateTime.tryParse(json['sent_at'].toString()),
      status: (json['status'] ?? 'pending').toString(),
      replyToMessageId: json['reply_to_message_id'] as int?,
      forwardedFromMessageId: json['forwarded_from_message_id'] as int?,
      attachments: ((json['attachments'] as List?) ?? const [])
          .whereType<Map>()
          .map(
            (row) =>
                MessageAttachmentItem.fromJson(row.cast<String, dynamic>()),
          )
          .toList(),
    );
  }

  bool get hasAttachments => attachments.isNotEmpty;
}

class MessageCursorPage {
  final List<MessageItem> items;
  final int? nextBeforeId;

  const MessageCursorPage({required this.items, required this.nextBeforeId});

  factory MessageCursorPage.fromJson(Map<String, dynamic> json) {
    return MessageCursorPage(
      items: ((json['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((row) => MessageItem.fromJson(row.cast<String, dynamic>()))
          .toList(),
      nextBeforeId: json['next_before_id'] as int?,
    );
  }
}

class SharedMediaItem {
  final int messageId;
  final DateTime messageCreatedAt;
  final int senderId;
  final String content;
  final MessageAttachmentItem attachment;

  const SharedMediaItem({
    required this.messageId,
    required this.messageCreatedAt,
    required this.senderId,
    required this.content,
    required this.attachment,
  });

  factory SharedMediaItem.fromJson(Map<String, dynamic> json) {
    return SharedMediaItem(
      messageId: json['message_id'] as int,
      messageCreatedAt: DateTime.parse(
        (json['message_created_at'] ?? '').toString(),
      ),
      senderId: json['sender_id'] as int,
      content: (json['content'] ?? '').toString(),
      attachment: MessageAttachmentItem.fromJson(
        (json['attachment'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
    );
  }
}

const Object _sentinel = Object();

class ReleaseInfo {
  final String platform;
  final String channel;
  final String? generatedAt;
  final String latestVersion;
  final String minimumSupportedVersion;
  final bool mandatory;
  final String downloadUrl;
  final String notes;
  final String packageKind;
  final String installStrategy;
  final bool inAppDownloadSupported;
  final bool restartRequired;
  final int? fileSizeBytes;
  final String? sha256;

  const ReleaseInfo({
    required this.platform,
    required this.channel,
    required this.generatedAt,
    required this.latestVersion,
    required this.minimumSupportedVersion,
    required this.mandatory,
    required this.downloadUrl,
    required this.notes,
    required this.packageKind,
    required this.installStrategy,
    required this.inAppDownloadSupported,
    required this.restartRequired,
    required this.fileSizeBytes,
    required this.sha256,
  });

  factory ReleaseInfo.fromJson(Map<String, dynamic> json) {
    return ReleaseInfo(
      platform: (json['platform'] ?? '').toString(),
      channel: (json['channel'] ?? 'stable').toString(),
      generatedAt: json['generated_at']?.toString(),
      latestVersion: (json['latest_version'] ?? '').toString(),
      minimumSupportedVersion: (json['minimum_supported_version'] ?? '')
          .toString(),
      mandatory: (json['mandatory'] ?? false) as bool,
      downloadUrl: (json['download_url'] ?? '').toString(),
      notes: (json['notes'] ?? '').toString(),
      packageKind: (json['package_kind'] ?? 'package').toString(),
      installStrategy: (json['install_strategy'] ?? 'external').toString(),
      inAppDownloadSupported: (json['in_app_download_supported'] ?? false) == true,
      restartRequired: (json['restart_required'] ?? true) == true,
      fileSizeBytes: json['file_size_bytes'] as int?,
      sha256: json['sha256']?.toString(),
    );
  }
}

class UserPrivacySettings {
  final String phoneVisibility;
  final String phoneSearchVisibility;
  final String lastSeenVisibility;
  final bool showApproximateLastSeen;
  final String allowGroupInvites;

  const UserPrivacySettings({
    required this.phoneVisibility,
    required this.phoneSearchVisibility,
    required this.lastSeenVisibility,
    required this.showApproximateLastSeen,
    required this.allowGroupInvites,
  });

  factory UserPrivacySettings.fromJson(Map<String, dynamic> json) {
    return UserPrivacySettings(
      phoneVisibility: (json['phone_visibility'] ?? 'everyone').toString(),
      phoneSearchVisibility:
          (json['phone_search_visibility'] ?? 'everyone').toString(),
      lastSeenVisibility: (json['last_seen_visibility'] ?? 'everyone')
          .toString(),
      showApproximateLastSeen:
          (json['show_approximate_last_seen'] ?? true) == true,
      allowGroupInvites:
          (json['allow_group_invites'] ?? 'everyone').toString(),
    );
  }
}

class UserDataStorageSettings {
  final int keepMediaDays;
  final int storageLimitMb;
  final bool autoDownloadPhotos;
  final bool autoDownloadVideos;
  final bool autoDownloadMusic;
  final bool autoDownloadFiles;
  final int? defaultAutoDeleteSeconds;

  const UserDataStorageSettings({
    required this.keepMediaDays,
    required this.storageLimitMb,
    required this.autoDownloadPhotos,
    required this.autoDownloadVideos,
    required this.autoDownloadMusic,
    required this.autoDownloadFiles,
    required this.defaultAutoDeleteSeconds,
  });

  factory UserDataStorageSettings.fromJson(Map<String, dynamic> json) {
    return UserDataStorageSettings(
      keepMediaDays: (json['keep_media_days'] ?? 30) as int,
      storageLimitMb: (json['storage_limit_mb'] ?? 2048) as int,
      autoDownloadPhotos: (json['auto_download_photos'] ?? true) == true,
      autoDownloadVideos: (json['auto_download_videos'] ?? true) == true,
      autoDownloadMusic: (json['auto_download_music'] ?? true) == true,
      autoDownloadFiles: (json['auto_download_files'] ?? false) == true,
      defaultAutoDeleteSeconds: json['default_auto_delete_seconds'] as int?,
    );
  }
}

class UserSettingsBundle {
  final UserPrivacySettings privacy;
  final UserDataStorageSettings dataStorage;
  final int blockedUsersCount;

  const UserSettingsBundle({
    required this.privacy,
    required this.dataStorage,
    required this.blockedUsersCount,
  });

  factory UserSettingsBundle.fromJson(Map<String, dynamic> json) {
    return UserSettingsBundle(
      privacy: UserPrivacySettings.fromJson(
        (json['privacy'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      dataStorage: UserDataStorageSettings.fromJson(
        (json['data_storage'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      blockedUsersCount: (json['blocked_users_count'] ?? 0) as int,
    );
  }
}

class AuthSessionItem {
  final String sessionId;
  final String? deviceName;
  final String? platform;
  final String? userAgent;
  final String? ipAddress;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  final DateTime expiresAt;
  final bool isCurrent;

  const AuthSessionItem({
    required this.sessionId,
    required this.deviceName,
    required this.platform,
    required this.userAgent,
    required this.ipAddress,
    required this.createdAt,
    required this.lastUsedAt,
    required this.expiresAt,
    required this.isCurrent,
  });

  factory AuthSessionItem.fromJson(Map<String, dynamic> json) {
    return AuthSessionItem(
      sessionId: (json['session_id'] ?? '').toString(),
      deviceName: json['device_name']?.toString(),
      platform: json['platform']?.toString(),
      userAgent: json['user_agent']?.toString(),
      ipAddress: json['ip_address']?.toString(),
      createdAt: DateTime.parse((json['created_at'] ?? '').toString()),
      lastUsedAt: json['last_used_at'] == null
          ? null
          : DateTime.tryParse(json['last_used_at'].toString()),
      expiresAt: DateTime.parse((json['expires_at'] ?? '').toString()),
      isCurrent: (json['is_current'] ?? false) == true,
    );
  }

  String get title {
    final explicit = deviceName?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final platformLabel = platform?.trim();
    if (platformLabel != null && platformLabel.isNotEmpty) {
      return 'oMsg $platformLabel';
    }
    return 'oMsg session';
  }

  String get subtitle {
    final parts = <String>[];
    final platformLabel = platform?.trim();
    if (platformLabel != null && platformLabel.isNotEmpty) {
      parts.add(platformLabel);
    }
    final ipLabel = ipAddress?.trim();
    if (ipLabel != null && ipLabel.isNotEmpty) {
      parts.add(ipLabel);
    }
    final agent = userAgent?.trim();
    if (agent != null && agent.isNotEmpty) {
      parts.add(agent);
    }
    if (parts.isEmpty) return 'Active session';
    return parts.join(' • ');
  }
}

class BlockedUserItem {
  final AppUser user;
  final DateTime blockedAt;

  const BlockedUserItem({required this.user, required this.blockedAt});

  factory BlockedUserItem.fromJson(Map<String, dynamic> json) {
    return BlockedUserItem(
      user: AppUser.fromJson(
        (json['user'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      blockedAt: DateTime.parse((json['blocked_at'] ?? '').toString()),
    );
  }
}

class PrivacyExceptionItem {
  final int id;
  final String settingKey;
  final String mode;
  final int targetUserId;
  final AppUser user;
  final DateTime createdAt;

  const PrivacyExceptionItem({
    required this.id,
    required this.settingKey,
    required this.mode,
    required this.targetUserId,
    required this.user,
    required this.createdAt,
  });

  bool get isAllow => mode == 'allow';
  bool get isDisallow => mode == 'disallow';

  factory PrivacyExceptionItem.fromJson(Map<String, dynamic> json) {
    return PrivacyExceptionItem(
      id: json['id'] as int,
      settingKey: (json['setting_key'] ?? '').toString(),
      mode: (json['mode'] ?? '').toString(),
      targetUserId: json['target_user_id'] as int,
      user: AppUser.fromJson(
        (json['user'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      createdAt: DateTime.parse((json['created_at'] ?? '').toString()),
    );
  }
}
