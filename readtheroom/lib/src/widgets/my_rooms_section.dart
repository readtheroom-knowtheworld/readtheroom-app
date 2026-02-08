// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/room.dart';
import '../services/room_service.dart';
import '../screens/create_room_screen.dart';
import '../screens/join_room_screen.dart';
import '../screens/room_settings_screen.dart';
import '../screens/room_details_screen.dart';
import '../utils/theme_utils.dart';
import 'room_qr_dialog.dart';
import '../services/room_event_service.dart';
import 'dart:async';

class MyRoomsSection extends StatefulWidget {
  const MyRoomsSection({Key? key}) : super(key: key);

  @override
  MyRoomsSectionState createState() => MyRoomsSectionState();
}

class MyRoomsSectionState extends State<MyRoomsSection> {
  final RoomService _roomService = RoomService();
  List<Room> _userRooms = [];
  bool _isLoading = false;
  bool _isExpanded = false;
  Map<String, dynamic>? _networkRankData;
  StreamSubscription<Room>? _roomJoinedSubscription;

  @override
  void initState() {
    super.initState();
    _loadUserRooms();
    _loadNetworkRank();
    
    // Listen for room join events from anywhere in the app
    _roomJoinedSubscription = RoomEventService().onRoomJoined.listen((room) {
      print('🎪 MyRoomsSection - Received room joined event: ${room.name}');
      _refreshAfterRoomJoin(room);
    });
  }

  @override
  void dispose() {
    _roomJoinedSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadUserRooms({bool isRetry = false}) async {
    print('🎪 MyRoomsSection - Loading user rooms... (retry: $isRetry)');
    if (!isRetry) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      final rooms = await _roomService.getUserRooms();
      print('🎪 MyRoomsSection - Loaded ${rooms.length} rooms');
      print('🎪 MyRoomsSection - Room names: ${rooms.map((r) => r.name).join(", ")}');
      setState(() {
        _userRooms = rooms;
      });
      print('🎪 MyRoomsSection - UI updated with ${_userRooms.length} rooms');
    } catch (e) {
      print('🎪 ERROR: MyRoomsSection - Error loading user rooms: $e');
      // Handle error silently or show a snackbar
      debugPrint('Error loading user rooms: $e');
    } finally {
      if (!isRetry) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _refreshAfterRoomJoin(Room joinedRoom) async {
    print('🎪 MyRoomsSection - Refreshing after room join: ${joinedRoom.name}');
    
    // First attempt - immediate refresh
    await _loadUserRooms();
    await _loadNetworkRank();
    
    // Check if the joined room is now in the list
    final isRoomInList = _userRooms.any((room) => room.id == joinedRoom.id);
    
    if (!isRoomInList) {
      print('🎪 MyRoomsSection - Room not found after first load, retrying in 1 second...');
      // Retry after a short delay to handle database timing issues
      Future.delayed(const Duration(seconds: 1), () async {
        if (mounted) {
          await _loadUserRooms(isRetry: true);
          await _loadNetworkRank();
          
          final isRoomInListAfterRetry = _userRooms.any((room) => room.id == joinedRoom.id);
          if (isRoomInListAfterRetry) {
            print('🎪 MyRoomsSection - Room found after retry: ${joinedRoom.name}');
          } else {
            print('🎪 MyRoomsSection - Room still not found after retry: ${joinedRoom.name}');
          }
        }
      });
    } else {
      print('🎪 MyRoomsSection - Room found immediately: ${joinedRoom.name}');
    }
  }

  Future<void> _loadNetworkRank() async {
    print('🎪 MyRoomsSection - Loading network rank...');
    try {
      final rankData = await _roomService.getUserNetworkRank();
      print('🎪 MyRoomsSection - Network rank data: $rankData');
      if (mounted) {
        setState(() {
          _networkRankData = rankData;
        });
      }
    } catch (e) {
      print('🎪 ERROR: MyRoomsSection - Error loading network rank: $e');
      // Silently handle error - network rank is optional
    }
  }

  // Public method to refresh room data from parent widgets
  Future<void> refreshRooms() async {
    print('🎪 MyRoomsSection - Public refresh called');
    await Future.wait([
      _loadUserRooms(),
      _loadNetworkRank(),
    ]);
  }

  Future<void> _createRoom() async {
    print('🎪 MyRoomsSection - Navigating to create room screen');
    final result = await Navigator.of(context).push<Room>(
      MaterialPageRoute(
        builder: (context) => const CreateRoomScreen(),
      ),
    );

    print('🎪 MyRoomsSection - Create room result: $result');
    if (result != null) {
      print('🎪 MyRoomsSection - Room created, refreshing rooms list');
      // Refresh the rooms list and network rank
      _loadUserRooms();
      _loadNetworkRank();
    } else {
      print('🎪 MyRoomsSection - Room creation was cancelled or failed');
    }
  }

  Future<void> _joinRoom() async {
    final result = await Navigator.of(context).push<Room>(
      MaterialPageRoute(
        builder: (context) => const JoinRoomScreen(),
      ),
    );

    if (result != null) {
      // Notify other widgets that a room was joined (this will trigger our own listener too)
      RoomEventService().notifyRoomJoined(result);
    }
  }

  void _copyInviteLink(Room room) {
    final inviteUrl = _roomService.getRoomInviteUrl(room.id);
    final shareText = 'Join my room, ${room.name}\n\n$inviteUrl';
    Clipboard.setData(ClipboardData(text: shareText));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Invite link copied to clipboard',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Theme.of(context).primaryColor,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showRoomQRCode(Room room) {
    final inviteUrl = _roomService.getRoomInviteUrl(room.id);
    RoomQRDialog.show(context, room, inviteUrl);
  }

  Future<bool> _isRoomAdmin(Room room) async {
    try {
      return await _roomService.isRoomAdmin(room.id);
    } catch (e) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: ThemeUtils.getDropdownBackgroundColor(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
      ),
      child: ExpansionTile(
        leading: const Icon(Icons.group),
        title: Text(
          'My Rooms',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: _userRooms.isNotEmpty
            ? Text('${_userRooms.length} room${_userRooms.length != 1 ? 's' : ''}')
            : null,
        onExpansionChanged: (isExpanded) {
          setState(() {
            _isExpanded = isExpanded;
          });
        },
        children: [
          // Network Rank Display
          if (_networkRankData != null && 
              _networkRankData!['totalNetworkUsers'] > 0 &&
              _userRooms.isNotEmpty)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).primaryColor.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.emoji_events,
                        color: Theme.of(context).primaryColor,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Your Camo Counter is #${_networkRankData!['rank']} in your network!',
                          style: TextStyle(
                            color: Theme.of(context).primaryColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        Icons.groups,
                        color: Theme.of(context).primaryColor.withOpacity(0.7),
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'There are ${_networkRankData!['totalNetworkUsers']} chameleons in network',
                        style: TextStyle(
                          color: Theme.of(context).primaryColor.withOpacity(0.8),
                          fontWeight: FontWeight.w400,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          
          // Action buttons
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _createRoom,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Create'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).primaryColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _joinRoom,
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('Join'),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // Loading indicator
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Center(
                child: CircularProgressIndicator(),
              ),
            ),
          
          // Empty state
          if (!_isLoading && _userRooms.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Icon(
                    Icons.group_outlined,
                    size: 48,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'No rooms yet',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Create your first room or join one with an invite code',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[500],
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          
          // Rooms list
          if (!_isLoading && _userRooms.isNotEmpty)
            ...(_userRooms.map((room) => _buildRoomTile(room)).toList()),
        ],
      ),
    );
  }

  Widget _buildRoomTile(Room room) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: room.isUnlocked ? Theme.of(context).primaryColor.withOpacity(0.1) : Colors.orange[100],
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(
          child: Text(
            '🎪',
            style: TextStyle(
              fontSize: 20,
              color: room.isUnlocked ? Theme.of(context).primaryColor : Colors.orange[700],
            ),
          ),
        ),
      ),
      title: Text(
        room.name,
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${room.memberCount} member${room.memberCount != 1 ? 's' : ''}'),
          if (!room.isUnlocked)
            Text(
              '${room.membersNeeded} more needed to unlock',
              style: TextStyle(
                fontSize: 12,
                color: Colors.orange[700],
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Invite link button (only for admins when invites are enabled)
          FutureBuilder<bool>(
            future: _isRoomAdmin(room),
            builder: (context, snapshot) {
              final isAdmin = snapshot.data ?? false;
              if (!isAdmin || !room.inviteCodeActive) {
                return const SizedBox.shrink();
              }
              return IconButton(
                icon: const Icon(Icons.share, size: 20),
                onPressed: () => _showRoomQRCode(room),
                tooltip: 'Share room',
              );
            },
          ),
          // Room settings
          IconButton(
            icon: const Icon(Icons.settings, size: 20),
            onPressed: () => _showRoomSettings(room),
            tooltip: 'Room settings',
          ),
        ],
      ),
      onTap: () {
        // Navigate to room details/management screen
        _navigateToRoomDetails(room);
      },
    );
  }

  void _showRoomSettings(Room room) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => RoomSettingsScreen(
          room: room,
          onRoomLeft: () {
            _loadUserRooms(); // Refresh the rooms list
          },
          onSettingsChanged: () {
            _loadUserRooms(); // Refresh the rooms list
          },
        ),
      ),
    );
  }


  void _navigateToRoomDetails(Room room) {
    print('🎪 MyRoomsSection - Navigating to room details for: ${room.name}');
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => RoomDetailsScreen(room: room),
      ),
    );
  }
}
