import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../api.dart';
import '../../../models.dart';
import '../../audio/presentation/audio_mini_player.dart';
import '../../chats/presentation/chats_tab.dart';
import '../../chats/presentation/media_viewers.dart';
import '../../contacts/presentation/contacts_tab.dart';
import '../../profile/presentation/profile_tab.dart';
import '../../settings/presentation/settings_tab.dart';

class HomeShell extends ConsumerStatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final AppUser user;
  final String appVersion;
  final String updateChannel;
  final Future<void> Function(AppUser user) onUserUpdated;
  final Future<void> Function(String channel) onUpdateChannelChanged;
  final Future<void> Function() onLogout;

  const HomeShell({
    super.key,
    required this.api,
    required this.getTokens,
    required this.user,
    required this.appVersion,
    required this.updateChannel,
    required this.onUserUpdated,
    required this.onUpdateChannelChanged,
    required this.onLogout,
  });

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      ChatsTab(api: widget.api, getTokens: widget.getTokens, me: widget.user),
      ContactsTab(
        api: widget.api,
        getTokens: widget.getTokens,
        me: widget.user,
      ),
      SettingsTab(
        api: widget.api,
        getTokens: widget.getTokens,
        appVersion: widget.appVersion,
        updateChannel: widget.updateChannel,
        onUpdateChannelChanged: widget.onUpdateChannelChanged,
        onLogout: widget.onLogout,
      ),
      ProfileTab(
        api: widget.api,
        getTokens: widget.getTokens,
        me: widget.user,
        onUserUpdated: widget.onUserUpdated,
      ),
    ];

    return Scaffold(
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: KeyedSubtree(key: ValueKey(_index), child: pages[_index]),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AudioMiniPlayerBar(
            onOpenFullPlayer: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ChatAudioPlayerPage(),
                ),
              );
            },
          ),
          NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (value) => setState(() => _index = value),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                label: 'Chats',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_search_outlined),
                label: 'Contacts',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                label: 'Settings',
              ),
              NavigationDestination(
                icon: Icon(Icons.account_circle_outlined),
                label: 'Profile',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

