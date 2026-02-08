// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/room.dart';
import '../services/room_service.dart';
import '../services/user_service.dart';
import '../widgets/room_qr_dialog.dart';

class RoomSettingsScreen extends StatefulWidget {
  final Room room;
  final VoidCallback? onRoomLeft;
  final VoidCallback? onSettingsChanged;

  const RoomSettingsScreen({
    Key? key,
    required this.room,
    this.onRoomLeft,
    this.onSettingsChanged,
  }) : super(key: key);

  @override
  State<RoomSettingsScreen> createState() => _RoomSettingsScreenState();
}

class _RoomSettingsScreenState extends State<RoomSettingsScreen> {
  final RoomService _roomService = RoomService();
  final UserService _userService = UserService();
  final TextEditingController _descriptionController = TextEditingController();
  String _selectedSharingPreference = 'auto_share_all'; // Default to auto-share
  bool _shareNsfwContent = true; // Default to sharing NSFW content
  bool _isMuted = false;
  bool _isLoading = false;
  bool _isAdmin = false;
  bool _isEditingDescription = false;
  late Room _currentRoom; // Local copy that can be updated

  @override
  void initState() {
    super.initState();
    _currentRoom = widget.room; // Initialize with the passed room
    _descriptionController.text = _currentRoom.description ?? '';
    _loadRoomMemberSettings();
    _checkAdminStatus();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _loadRoomMemberSettings() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final members = await _roomService.getRoomMembers(_currentRoom.id);
      final currentUserId = Supabase.instance.client.auth.currentUser?.id;
      final currentMember = members.firstWhere(
        (member) => member.userId == currentUserId,
        orElse: () => throw Exception('User is not a member of this room'),
      );

      // Load NSFW sharing preference
      final nsfwSharingPreference = await _roomService.getNsfwSharingPreference(_currentRoom.id);
      
      setState(() {
        _selectedSharingPreference = currentMember.sharingPreference;
        _shareNsfwContent = nsfwSharingPreference;
        _isMuted = currentMember.muted;
      });
    } catch (e) {
      debugPrint('Error loading room member settings: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _checkAdminStatus() async {
    try {
      final isAdmin = await _roomService.isRoomAdmin(_currentRoom.id);
      setState(() {
        _isAdmin = isAdmin;
      });
    } catch (e) {
      debugPrint('Error checking admin status: $e');
    }
  }


  Future<void> _updateNsfwSharingPreference(bool shareNsfw) async {
    print('🎪 ROOM_SETTINGS: Updating NSFW sharing preference to: $shareNsfw');
    print('🎪 ROOM_SETTINGS: Room ID: ${_currentRoom.id}');
    
    try {
      // TODO: Implement backend support for per-room NSFW sharing preference
      // For now, we'll store this locally and integrate with room sharing logic
      await _roomService.updateNsfwSharingPreference(_currentRoom.id, shareNsfw);
      print('🎪 ROOM_SETTINGS: NSFW sharing preference updated successfully');
      
      setState(() {
        _shareNsfwContent = shareNsfw;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            shareNsfw ? 'NSFW content will be shared with this room' : 'NSFW content will not be shared with this room',
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: Theme.of(context).primaryColor,
        ),
      );
      
      widget.onSettingsChanged?.call();
    } catch (e) {
      print('🎪 ERROR: ROOM_SETTINGS - Failed to update NSFW sharing preference');
      print('🎪 ERROR: Exception: $e');
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update NSFW sharing preference: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // COMMENTED OUT FOR NOW - Mute functionality
  // Future<void> _toggleMute() async {
  //   try {
  //     final newMutedState = !_isMuted;
  //     await _roomService.muteRoom(_currentRoom.id, newMutedState);
  //     setState(() {
  //       _isMuted = newMutedState;
  //     });
  //     
  //     ScaffoldMessenger.of(context).showSnackBar(
  //       SnackBar(
  //         content: Text(
  //           newMutedState ? 'Room muted' : 'Room unmuted',
  //           style: const TextStyle(color: Colors.white),
  //         ),
  //         backgroundColor: Theme.of(context).primaryColor,
  //       ),
  //     );
  //     
  //     widget.onSettingsChanged?.call();
  //   } catch (e) {
  //     ScaffoldMessenger.of(context).showSnackBar(
  //       SnackBar(
  //         content: Text('Failed to ${_isMuted ? 'unmute' : 'mute'} room: $e'),
  //         backgroundColor: Colors.red,
  //       ),
  //     );
  //   }
  // }

  void _copyInviteLink() {
    final inviteUrl = _roomService.getRoomInviteUrl(_currentRoom.id);
    final shareText = 'Join my room, ${_currentRoom.name}\n\n$inviteUrl';
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

  void _showQRCode() {
    final inviteUrl = _roomService.getRoomInviteUrl(_currentRoom.id);
    RoomQRDialog.show(context, _currentRoom, inviteUrl);
  }

  Future<void> _toggleInvites() async {
    final currentState = _currentRoom.inviteCodeActive;
    final newState = !currentState;
    
    print('🎪 ROOM_SETTINGS: Toggling room invites');
    print('🎪 ROOM_SETTINGS: Room ID: ${_currentRoom.id}');
    print('🎪 ROOM_SETTINGS: Current state: $currentState');
    print('🎪 ROOM_SETTINGS: New state: $newState');
    print('🎪 ROOM_SETTINGS: User is admin: $_isAdmin');
    
    try {
      await _roomService.toggleRoomInvites(_currentRoom.id, newState);
      print('🎪 ROOM_SETTINGS: Invite toggle successful');
      
      // Update the local room state immediately for UI responsiveness
      setState(() {
        _currentRoom = Room(
          id: _currentRoom.id,
          name: _currentRoom.name,
          description: _currentRoom.description,
          avatarUrl: _currentRoom.avatarUrl,
          inviteCode: _currentRoom.inviteCode,
          inviteCodeActive: newState, // Update the toggle state
          memberCount: _currentRoom.memberCount,
          rqiScore: _currentRoom.rqiScore,
          globalRank: _currentRoom.globalRank,
          createdBy: _currentRoom.createdBy,
          createdAt: _currentRoom.createdAt,
          updatedAt: _currentRoom.updatedAt,
        );
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newState ? 'Room invites enabled' : 'Room invites disabled',
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: Theme.of(context).primaryColor,
        ),
      );
      
      // This will trigger the parent (MyRoomsSection) to refresh the room data
      widget.onSettingsChanged?.call();
    } catch (e) {
      print('🎪 ERROR: ROOM_SETTINGS - Failed to toggle room invites');
      print('🎪 ERROR: Exception: $e');
      print('🎪 ERROR: Exception type: ${e.runtimeType}');
      print('🎪 ERROR: Stack trace: ${StackTrace.current}');
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to toggle invites: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _toggleNsfw() async {
    final currentState = _currentRoom.nsfwEnabled;
    final newState = !currentState;
    
    print('🎪 ROOM_SETTINGS: Toggling room NSFW');
    print('🎪 ROOM_SETTINGS: Room ID: ${_currentRoom.id}');
    print('🎪 ROOM_SETTINGS: Current state: $currentState');
    print('🎪 ROOM_SETTINGS: New state: $newState');
    print('🎪 ROOM_SETTINGS: User is admin: $_isAdmin');
    
    try {
      await _roomService.toggleRoomNsfw(_currentRoom.id, newState);
      print('🎪 ROOM_SETTINGS: NSFW toggle successful');
      
      // Update the local room state immediately for UI responsiveness
      setState(() {
        _currentRoom = Room(
          id: _currentRoom.id,
          name: _currentRoom.name,
          description: _currentRoom.description,
          avatarUrl: _currentRoom.avatarUrl,
          inviteCode: _currentRoom.inviteCode,
          inviteCodeActive: _currentRoom.inviteCodeActive,
          nsfwEnabled: newState, // Update the NSFW state
          memberCount: _currentRoom.memberCount,
          rqiScore: _currentRoom.rqiScore,
          globalRank: _currentRoom.globalRank,
          createdBy: _currentRoom.createdBy,
          createdAt: _currentRoom.createdAt,
          updatedAt: _currentRoom.updatedAt,
        );
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newState ? 'NSFW questions enabled' : 'NSFW questions disabled',
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: Theme.of(context).primaryColor,
        ),
      );
      
      // This will trigger the parent (MyRoomsSection) to refresh the room data
      widget.onSettingsChanged?.call();
    } catch (e) {
      print('🎪 ERROR: ROOM_SETTINGS - Failed to toggle room NSFW');
      print('🎪 ERROR: Exception: $e');
      print('🎪 ERROR: Exception type: ${e.runtimeType}');
      print('🎪 ERROR: Stack trace: ${StackTrace.current}');
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to toggle NSFW setting: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _updateRoomDescription() async {
    final newDescription = _descriptionController.text.trim();
    
    try {
      await _roomService.updateRoomDescription(_currentRoom.id, newDescription);
      
      setState(() {
        _currentRoom = Room(
          id: _currentRoom.id,
          name: _currentRoom.name,
          description: newDescription,
          avatarUrl: _currentRoom.avatarUrl,
          inviteCode: _currentRoom.inviteCode,
          inviteCodeActive: _currentRoom.inviteCodeActive,
          nsfwEnabled: _currentRoom.nsfwEnabled,
          memberCount: _currentRoom.memberCount,
          rqiScore: _currentRoom.rqiScore,
          globalRank: _currentRoom.globalRank,
          createdBy: _currentRoom.createdBy,
          createdAt: _currentRoom.createdAt,
          updatedAt: _currentRoom.updatedAt,
        );
        _isEditingDescription = false;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Room description updated',
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: Theme.of(context).primaryColor,
        ),
      );
      
      widget.onSettingsChanged?.call();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update description: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _leaveRoom() async {
    final isRoomAdmin = _isAdmin;
    final actionTitle = isRoomAdmin ? 'Leave & Delete Room' : 'Leave Room';
    final confirmMessage = isRoomAdmin 
        ? 'Are you sure you want to leave "${_currentRoom.name}"?\n\nAs the admin, leaving will permanently delete the room and remove all members.'
        : 'Are you sure you want to leave "${_currentRoom.name}"?\n\nYou can only rejoin using the invite code.';
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(actionTitle),
        content: Text(confirmMessage),
        actions: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(isRoomAdmin ? 'Delete' : 'Leave'),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        if (isRoomAdmin) {
          print('🎪 ROOM_SETTINGS: Admin leaving room - will delete');
          print('🎪 ROOM_SETTINGS: Room ID: ${_currentRoom.id}');
          print('🎪 ROOM_SETTINGS: Room name: ${_currentRoom.name}');
          
          // Admin leaving deletes the room
          await _roomService.deleteRoom(_currentRoom.id);
          print('🎪 ROOM_SETTINGS: Room deletion successful');
          
          Navigator.pop(context); // Close settings screen
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Room "${_currentRoom.name}" deleted successfully',
                style: const TextStyle(color: Colors.white),
              ),
              backgroundColor: Theme.of(context).primaryColor,
            ),
          );
        } else {
          print('🎪 ROOM_SETTINGS: Regular member leaving room');
          print('🎪 ROOM_SETTINGS: Room ID: ${_currentRoom.id}');
          print('🎪 ROOM_SETTINGS: Room name: ${_currentRoom.name}');
          
          // Regular member just leaves
          await _roomService.leaveRoom(_currentRoom.id);
          print('🎪 ROOM_SETTINGS: Leave room successful');
          
          Navigator.pop(context); // Close settings screen
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Left "${_currentRoom.name}"',
                style: const TextStyle(color: Colors.white),
              ),
              backgroundColor: Theme.of(context).primaryColor,
            ),
          );
        }
        widget.onRoomLeft?.call();
      } catch (e) {
        final action = isRoomAdmin ? 'delete' : 'leave';
        print('🎪 ERROR: ROOM_SETTINGS - Failed to $action room');
        print('🎪 ERROR: Exception: $e');
        print('🎪 ERROR: Exception type: ${e.runtimeType}');
        print('🎪 ERROR: Stack trace: ${StackTrace.current}');
        
        final errorMessage = isRoomAdmin ? 'Failed to delete room: $e' : 'Failed to leave room: $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
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
        title: Text('${_currentRoom.name} Settings'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _isLoading 
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Room header
                  _buildRoomHeader(),
                  
                  const SizedBox(height: 32),
                  
                  // Room description section (admin only)
                  _buildDescriptionSection(),
                  
                  // Invite code section
                  _buildInviteCodeSection(),
                  
                  const SizedBox(height: 32),
                  
                  // NSFW settings section (admin only)
                  _buildNsfwSection(),
                  
                  const SizedBox(height: 32),
                  
                  // NSFW sharing preferences (only show if room has NSFW enabled and user has NSFW enabled)
                  _buildNsfwSharingSection(),
                  
                  const SizedBox(height: 32),
                  
                  // Room notifications - COMMENTED OUT FOR NOW
                  // _buildNotificationsSection(),
                  
                  // const SizedBox(height: 32),
                  
                  // Admin actions (if applicable)
                  _buildAdminActionsSection(),
                  
                  const SizedBox(height: 32),
                  
                  // Leave room
                  _buildLeaveRoomSection(),
                ],
              ),
            ),
    );
  }

  Widget _buildRoomHeader() {
    return Row(
      children: [
        Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: _currentRoom.isUnlocked ? Theme.of(context).primaryColor.withOpacity(0.1) : Colors.orange[100],
            borderRadius: BorderRadius.circular(30),
          ),
          child: Center(
            child: Text(
              '🎪',
              style: TextStyle(
                fontSize: 30,
                color: _currentRoom.isUnlocked ? Theme.of(context).primaryColor : Colors.orange[700],
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
                _currentRoom.name,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '${_currentRoom.memberCount} member${_currentRoom.memberCount != 1 ? 's' : ''}',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[600],
                ),
              ),
              if (!_currentRoom.isUnlocked)
                Text(
                  '${_currentRoom.membersNeeded} more needed to unlock',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.orange[700],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDescriptionSection() {
    // Only show description editing to admins
    if (!_isAdmin) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Room Description',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (!_isEditingDescription)
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    _isEditingDescription = true;
                  });
                },
                icon: const Icon(Icons.edit, size: 16),
                label: const Text('Edit'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        
        if (_isEditingDescription) ...[
          TextField(
            controller: _descriptionController,
            maxLines: 3,
            maxLength: 500,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: 'Enter room description...',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surface,
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton(
                  onPressed: _updateRoomDescription,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Save'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _descriptionController.text = _currentRoom.description ?? '';
                      _isEditingDescription = false;
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ] else ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
              ),
            ),
            child: Text(
              _currentRoom.description?.isNotEmpty == true 
                  ? _currentRoom.description!
                  : 'No description',
              style: TextStyle(
                fontSize: 16,
                color: _currentRoom.description?.isNotEmpty == true 
                    ? Theme.of(context).colorScheme.onSurface
                    : Colors.grey[500],
                fontStyle: _currentRoom.description?.isNotEmpty == true 
                    ? FontStyle.normal 
                    : FontStyle.italic,
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ],
    );
  }

  Widget _buildInviteCodeSection() {
    // Only show invite section to admins
    if (!_isAdmin) {
      return const SizedBox.shrink();
    }

    final inviteUrl = _roomService.getRoomInviteUrl(_currentRoom.id);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Room Invites',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        
        // Invite toggle
        SwitchListTile(
          title: const Text('Allow new members to join'),
          subtitle: Text(_currentRoom.inviteCodeActive 
              ? 'Anyone with the link can join' 
              : 'New member invites are disabled'),
          value: _currentRoom.inviteCodeActive,
          onChanged: (value) => _toggleInvites(),
          contentPadding: EdgeInsets.zero,
        ),
        
        if (_currentRoom.inviteCodeActive) ...[
          const SizedBox(height: 16),
          
          // QR Code share button
          Center(
            child: ElevatedButton.icon(
              onPressed: _showQRCode,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Share QR Code'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Theme.of(context).primaryColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Invite Link',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        inviteUrl,
                        style: const TextStyle(
                          fontSize: 14,
                          fontFamily: 'monospace',
                          color: Colors.white,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, color: Colors.white),
                      onPressed: _copyInviteLink,
                      tooltip: 'Copy invite link',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildNsfwSection() {
    // Only show NSFW section to admins who have NSFW enabled
    if (!_isAdmin || !_userService.showNSFWContent) {
      return const SizedBox.shrink();
    }
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Content Settings',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        
        // NSFW toggle
        SwitchListTile(
          title: const Text('Allow NSFW questions'),
          subtitle: Text(_currentRoom.nsfwEnabled 
              ? 'Members can see NSFW question responses in this room' 
              : 'NSFW questions are hidden from this room'),
          value: _currentRoom.nsfwEnabled,
          onChanged: (value) => _toggleNsfw(),
          contentPadding: EdgeInsets.zero,
        ),
        
        const SizedBox(height: 8),
        
        // Warning text for when NSFW is enabled
        if (_currentRoom.nsfwEnabled)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.warning, color: Colors.orange[700], size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Room members will be able to see how others responded to NSFW questions',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.orange[700],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }


  // COMMENTED OUT FOR NOW - Notifications section
  // Widget _buildNotificationsSection() {
  //   return Column(
  //     crossAxisAlignment: CrossAxisAlignment.start,
  //     children: [
  //       const Text(
  //         'Notifications',
  //         style: TextStyle(
  //           fontSize: 20,
  //           fontWeight: FontWeight.bold,
  //         ),
  //       ),
  //       const SizedBox(height: 12),
  //       
  //       SwitchListTile(
  //         title: const Text('Mute room'),
  //         subtitle: const Text('Stop receiving activity updates from this room'),
  //         value: _isMuted,
  //         onChanged: (value) => _toggleMute(),
  //         contentPadding: EdgeInsets.zero,
  //       ),
  //     ],
  //   );
  // }

  Widget _buildAdminActionsSection() {
    // Admin actions are now integrated into the leave room section
    return const SizedBox.shrink();
  }

  Widget _buildNsfwSharingSection() {
    // Only show if room has NSFW enabled and user has NSFW enabled
    if (!_currentRoom.nsfwEnabled || !_userService.showNSFWContent) {
      return const SizedBox.shrink();
    }
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'NSFW Response Sharing',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Control whether your NSFW responses are shared with this room',
          style: TextStyle(
            fontSize: 16,
            color: Colors.grey[600],
          ),
        ),
        const SizedBox(height: 16),
        
        SwitchListTile(
          title: Row(
            children: [
              Icon(Icons.explicit, color: Colors.orange, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text('Share my NSFW responses with this room'),
              ),
            ],
          ),
          subtitle: const Text('Control whether NSFW content is shared automatically with this room'),
          value: _shareNsfwContent,
          onChanged: (value) => _updateNsfwSharingPreference(value),
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }

  Widget _buildLeaveRoomSection() {
    final isRoomAdmin = _isAdmin;
    final actionTitle = isRoomAdmin ? 'Leave & Delete Room' : 'Leave Room';
    final actionSubtitle = isRoomAdmin 
        ? 'Permanently delete this room and remove all members'
        : 'You can rejoin using the invite code';
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Room Actions',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        
        ListTile(
          leading: Icon(
            isRoomAdmin ? Icons.delete_forever : Icons.exit_to_app, 
            color: Colors.red
          ),
          title: Text(
            actionTitle,
            style: const TextStyle(color: Colors.red),
          ),
          subtitle: Text(
            actionSubtitle,
            style: TextStyle(
              color: isRoomAdmin ? Colors.red : null,
            ),
          ),
          onTap: _leaveRoom,
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }
}
