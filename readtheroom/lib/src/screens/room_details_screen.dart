// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/room.dart';
import '../services/room_service.dart';
import 'room_settings_screen.dart';

class RoomDetailsScreen extends StatefulWidget {
  final Room room;

  const RoomDetailsScreen({
    Key? key,
    required this.room,
  }) : super(key: key);

  @override
  State<RoomDetailsScreen> createState() => _RoomDetailsScreenState();
}

class _RoomDetailsScreenState extends State<RoomDetailsScreen> {
  final RoomService _roomService = RoomService();
  final SupabaseClient supabase = Supabase.instance.client;
  
  Room? _currentRoom;
  int? _userRankInRoom;
  bool _isLoadingRanking = false;

  @override
  void initState() {
    super.initState();
    _currentRoom = widget.room;
    _loadUserRanking();
  }

  Room get currentRoom => _currentRoom ?? widget.room;

  Future<void> _loadUserRanking() async {
    setState(() {
      _isLoadingRanking = true;
    });

    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) {
        print('🎪 RoomDetails: No user ID found');
        return;
      }

      print('🎪 RoomDetails: Loading user rank for room: ${widget.room.id}');

      // Get user's rank within this specific room
      final roomRankingResponse = await supabase
          .rpc('get_user_rank_in_room', params: {
            'target_room_id': widget.room.id,
            'target_user_id': userId,
          });

      final userRoomRank = roomRankingResponse as int?;
      print('🎪 RoomDetails: User rank in room: $userRoomRank');

      setState(() {
        _userRankInRoom = userRoomRank;
      });
    } catch (e) {
      print('🎪 RoomDetails: Error loading user ranking: $e');
    } finally {
      setState(() {
        _isLoadingRanking = false;
      });
    }
  }

  Future<void> _refreshRoomData() async {
    try {
      // Refresh the room data to get latest stats
      final updatedRoom = await _roomService.getRoom(widget.room.id);
      
      setState(() {
        _currentRoom = updatedRoom;
      });
      
      // Reload user ranking
      await _loadUserRanking();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Room data refreshed'),
            duration: const Duration(seconds: 1),
            backgroundColor: Theme.of(context).primaryColor,
          ),
        );
      }
    } catch (e) {
      print('🎪 RoomDetails: Error refreshing room data: $e');
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to refresh room data'),
            duration: Duration(seconds: 2),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('🎪 ${currentRoom.name}'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshRoomData,
            tooltip: 'Refresh room data',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshRoomData,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Room header card
              _buildRoomHeaderCard(),
              
              const SizedBox(height: 16),
              
              // Room stats card
              _buildRoomStatsCard(),
              
              const SizedBox(height: 16),
              
              // Your ranking card
              _buildUserRankingCard(),
              
              const SizedBox(height: 24),
              
              // Explanation section
              _buildExplanationSection(),
              
              const SizedBox(height: 24),
              
              // Action buttons
              _buildActionButtons(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoomHeaderCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: currentRoom.isUnlocked 
                        ? Theme.of(context).primaryColor.withOpacity(0.2)
                        : Colors.orange.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: Center(
                    child: Text(
                      '🎪',
                      style: TextStyle(
                        fontSize: 30,
                        color: currentRoom.isUnlocked 
                            ? Theme.of(context).primaryColor
                            : Colors.orange[700],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        currentRoom.name,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.people,
                            size: 16,
                            color: Colors.grey[600],
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${currentRoom.memberCount} member${currentRoom.memberCount != 1 ? 's' : ''}',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            
            if (currentRoom.description != null && currentRoom.description!.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                currentRoom.description!,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[700],
                  height: 1.4,
                ),
              ),
            ],
            
            if (!currentRoom.isUnlocked) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.lock, color: Colors.orange[700], size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${currentRoom.membersNeeded} more member${currentRoom.membersNeeded != 1 ? 's' : ''} needed to unlock room features',
                        style: TextStyle(
                          color: Colors.orange[700],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRoomStatsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.analytics,
                  color: Theme.of(context).primaryColor,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'Room Statistics',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).primaryColor,
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 16),
            
            // Room Quality Index
            if (currentRoom.rqiScore != null) ...[
              _buildStatRow(
                icon: Icons.star,
                label: 'Room Quality Index',
                value: currentRoom.rqiScore!.toStringAsFixed(1),
                color: Theme.of(context).primaryColor,
              ),
              const SizedBox(height: 12),
            ],
            
            // Global Ranking
            if (currentRoom.globalRank != null) ...[
              _buildStatRow(
                icon: Icons.emoji_events,
                label: 'Global Ranking',
                value: '#${currentRoom.globalRank} worldwide',
                color: Colors.amber[700]!,
              ),
              const SizedBox(height: 12),
            ],
            
            // Member count
            _buildStatRow(
              icon: Icons.group,
              label: 'Total Members',
              value: '${currentRoom.memberCount}',
              color: Theme.of(context).primaryColor,
            ),
            
            // Show default message if no stats available
            if (currentRoom.rqiScore == null && currentRoom.globalRank == null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.grey[600], size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Room statistics will appear once more members join and participate',
                        style: TextStyle(
                          color: Colors.grey[600],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatRow({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 12),
        Text(
          label,
          style: TextStyle(
            fontSize: 16,
            color: Colors.grey[700],
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildUserRankingCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.person,
                  color: Theme.of(context).primaryColor,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'Camo Quality Ranking',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).primaryColor,
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 16),
            
            if (_isLoadingRanking)
              Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Loading your ranking...',
                    style: TextStyle(
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              )
            else if (_userRankInRoom != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.leaderboard,
                      color: Theme.of(context).primaryColor,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'You are ranked #$_userRankInRoom in this room!',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).primaryColor,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.grey[600], size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Your ranking will appear once you participate more in room discussions',
                        style: TextStyle(
                          color: Colors.grey[600],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildExplanationSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.filter_list,
                  color: Theme.of(context).primaryColor,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'Filters and Comparisons',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).primaryColor,
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 12),
            
            Text(
              'If more than 5 people in this room answer the same question, you will be able to apply this room as a filter to the global responses.',
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).textTheme.bodyLarge?.color,
                height: 1.5,
              ),
            ),
            
            const SizedBox(height: 8),
            
            Text(
              'This lets you see how your group thinks differently from the rest of the world!',
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).textTheme.bodyMedium?.color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => _openSettings(),
        icon: const Icon(Icons.settings),
        label: const Text('Settings'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Theme.of(context).primaryColor,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }


  void _openSettings() {
    // Navigate to room settings (existing functionality)
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => RoomSettingsScreen(
          room: currentRoom,
          onRoomLeft: () {
            Navigator.of(context).pop(); // Go back if user leaves room
          },
          onSettingsChanged: () {
            _refreshRoomData(); // Refresh data if settings changed
          },
        ),
      ),
    );
  }
}
