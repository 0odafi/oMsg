import 'package:flutter/material.dart';

enum ChatSurfacePreset { ocean, graphite, amoled }

enum ChatAccentPreset { blue, violet, emerald, amber }

extension ChatSurfacePresetLabel on ChatSurfacePreset {
  String get label {
    switch (this) {
      case ChatSurfacePreset.ocean:
        return 'Ocean';
      case ChatSurfacePreset.graphite:
        return 'Graphite';
      case ChatSurfacePreset.amoled:
        return 'AMOLED';
    }
  }
}

extension ChatAccentPresetLabel on ChatAccentPreset {
  String get label {
    switch (this) {
      case ChatAccentPreset.blue:
        return 'Blue';
      case ChatAccentPreset.violet:
        return 'Violet';
      case ChatAccentPreset.emerald:
        return 'Emerald';
      case ChatAccentPreset.amber:
        return 'Amber';
    }
  }
}

@immutable
class AppAppearanceData {
  final ChatSurfacePreset chatSurfacePreset;
  final ChatAccentPreset chatAccentPreset;
  final double messageTextScale;
  final bool compactChatList;

  const AppAppearanceData({
    required this.chatSurfacePreset,
    required this.chatAccentPreset,
    required this.messageTextScale,
    required this.compactChatList,
  });

  const AppAppearanceData.defaults()
    : chatSurfacePreset = ChatSurfacePreset.ocean,
      chatAccentPreset = ChatAccentPreset.blue,
      messageTextScale = 1.0,
      compactChatList = false;

  AppAppearanceData copyWith({
    ChatSurfacePreset? chatSurfacePreset,
    ChatAccentPreset? chatAccentPreset,
    double? messageTextScale,
    bool? compactChatList,
  }) {
    return AppAppearanceData(
      chatSurfacePreset: chatSurfacePreset ?? this.chatSurfacePreset,
      chatAccentPreset: chatAccentPreset ?? this.chatAccentPreset,
      messageTextScale: messageTextScale ?? this.messageTextScale,
      compactChatList: compactChatList ?? this.compactChatList,
    );
  }

  Color get accentColor {
    switch (chatAccentPreset) {
      case ChatAccentPreset.blue:
        return const Color(0xFF58B8FF);
      case ChatAccentPreset.violet:
        return const Color(0xFFC56FFF);
      case ChatAccentPreset.emerald:
        return const Color(0xFF4DD8A7);
      case ChatAccentPreset.amber:
        return const Color(0xFFFFC464);
    }
  }

  Color get accentColorMuted {
    return Color.alphaBlend(
      accentColor.withValues(alpha: 0.18),
      surfaceRaisedColor,
    );
  }

  Color get accentColorStrong {
    return Color.alphaBlend(
      accentColor.withValues(alpha: 0.34),
      surfaceRaisedColor,
    );
  }

  Color get scaffoldColor {
    switch (chatSurfacePreset) {
      case ChatSurfacePreset.ocean:
        return const Color(0xFF09111D);
      case ChatSurfacePreset.graphite:
        return const Color(0xFF101216);
      case ChatSurfacePreset.amoled:
        return const Color(0xFF040404);
    }
  }

  Color get scaffoldAccentColor {
    switch (chatSurfacePreset) {
      case ChatSurfacePreset.ocean:
        return const Color(0xFF101C2C);
      case ChatSurfacePreset.graphite:
        return const Color(0xFF171A20);
      case ChatSurfacePreset.amoled:
        return const Color(0xFF0A0A0A);
    }
  }

  Color get surfaceColor {
    switch (chatSurfacePreset) {
      case ChatSurfacePreset.ocean:
        return const Color(0xFF131C2A);
      case ChatSurfacePreset.graphite:
        return const Color(0xFF171A1F);
      case ChatSurfacePreset.amoled:
        return const Color(0xFF0C0C0D);
    }
  }

  Color get surfaceRaisedColor {
    switch (chatSurfacePreset) {
      case ChatSurfacePreset.ocean:
        return const Color(0xFF1A2433);
      case ChatSurfacePreset.graphite:
        return const Color(0xFF1F232A);
      case ChatSurfacePreset.amoled:
        return const Color(0xFF111214);
    }
  }

  Color get outlineColor {
    switch (chatSurfacePreset) {
      case ChatSurfacePreset.ocean:
        return const Color(0xFF2C3B4E);
      case ChatSurfacePreset.graphite:
        return const Color(0xFF32363E);
      case ChatSurfacePreset.amoled:
        return const Color(0xFF232326);
    }
  }

  LinearGradient get chatBackgroundGradient {
    switch (chatSurfacePreset) {
      case ChatSurfacePreset.ocean:
        return LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF0B1626),
            const Color(0xFF0E1B30),
            accentColor.withValues(alpha: 0.08),
          ],
        );
      case ChatSurfacePreset.graphite:
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF101114),
            const Color(0xFF16181C),
            accentColor.withValues(alpha: 0.05),
          ],
        );
      case ChatSurfacePreset.amoled:
        return LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF010101),
            const Color(0xFF060607),
            accentColor.withValues(alpha: 0.04),
          ],
        );
    }
  }

  Color get outgoingBubbleColor {
    return Color.alphaBlend(accentColor.withValues(alpha: 0.28), surfaceColor);
  }

  Color get outgoingBubbleBorderColor {
    return Color.alphaBlend(accentColor.withValues(alpha: 0.42), outlineColor);
  }

  Color get incomingBubbleColor => surfaceRaisedColor;

  Color get incomingBubbleBorderColor => outlineColor;

  Color get chipFillColor =>
      Color.alphaBlend(accentColor.withValues(alpha: 0.12), surfaceRaisedColor);

  Color get navBarColor =>
      Color.alphaBlend(accentColor.withValues(alpha: 0.08), surfaceColor);
}
