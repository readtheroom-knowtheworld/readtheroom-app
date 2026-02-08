// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/room_service.dart';

class JoinRoomScreen extends StatefulWidget {
  final String? prefilledRoomId; // For deep linking
  
  const JoinRoomScreen({Key? key, this.prefilledRoomId}) : super(key: key);

  @override
  State<JoinRoomScreen> createState() => _JoinRoomScreenState();
}

class _JoinRoomScreenState extends State<JoinRoomScreen> {
  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();
  final _roomService = RoomService();
  
  bool _isLoading = false;
  String _selectedSharingPreference = 'auto_share_all'; // Default to auto-share

  @override
  void initState() {
    super.initState();
    // Pre-fill room ID if provided via deep link
    if (widget.prefilledRoomId != null) {
      _codeController.text = widget.prefilledRoomId!;
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _joinRoom() async {
    if (!_formKey.currentState!.validate()) return;

    print('🎪 Join room button pressed');
    print('🎪 Room ID: "${_codeController.text.trim()}"');

    setState(() {
      _isLoading = true;
    });

    try {
      print('🎪 Starting room join...');
      final room = await _roomService.joinRoomWithCode(
        _codeController.text.trim(),
      );

      print('🎪 Room join successful, room ID: ${room.id}');
      
      // Set the sharing preference for the new member
      if (_selectedSharingPreference != 'manual') {
        print('🎪 Setting sharing preference to: $_selectedSharingPreference');
        await _roomService.updateSharingPreference(room.id, _selectedSharingPreference);
      }

      if (mounted) {
        Navigator.of(context).pop(room);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Successfully joined "${room.name}"!',
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: Theme.of(context).primaryColor,
          ),
        );
      }
    } catch (e) {
      print('🎪 ERROR: Room join failed in UI: $e');
      print('🎪 ERROR: Exception type in UI: ${e.runtimeType}');
      
      if (mounted) {
        String errorMessage = e.toString();
        if (errorMessage.contains('Room not found') || errorMessage.contains('invites are disabled')) {
          errorMessage = 'Room not found or invites are disabled.';
        } else if (errorMessage.contains('already a member')) {
          errorMessage = 'You\'re already a member of this room.';
        }
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboardData?.text != null) {
        final text = clipboardData!.text!.trim();
        
        // Extract UUID from URL if it's a readtheroom.site link
        final urlMatch = RegExp(r'https?://readtheroom\.site/rooms/([a-f0-9-]{36})').firstMatch(text);
        if (urlMatch != null) {
          _codeController.text = urlMatch.group(1)!;
        } else {
          // Otherwise try to extract UUID directly
          final uuidMatch = RegExp(r'\b[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\b').firstMatch(text);
          if (uuidMatch != null) {
            _codeController.text = uuidMatch.group(0)!;
          } else {
            _codeController.text = text;
          }
        }
      }
    } catch (e) {
      // Ignore clipboard errors
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Join Room'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              
              // Join room illustration with circus tent emoji
              Container(
                height: 120,
                width: 120,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).primaryColor,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(60),
                ),
                child: const Center(
                  child: Text(
                    '🦎🎪🦎',
                    style: TextStyle(fontSize: 60),
                  ),
                ),
              ),
              
              const SizedBox(height: 32),
              
              const Text(
                'Join Room',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              
              const SizedBox(height: 8),
              
              const Text(
                'Enter the room ID or paste an invite link',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey,
                ),
                textAlign: TextAlign.center,
              ),
              
              const SizedBox(height: 32),
              
              // Room ID field
              TextFormField(
                controller: _codeController,
                decoration: InputDecoration(
                  labelText: 'Room ID',
                  hintText: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  prefixIcon: const Icon(Icons.group),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.paste),
                    onPressed: _pasteFromClipboard,
                    tooltip: 'Paste from clipboard',
                  ),
                ),
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 14,
                  fontFamily: 'monospace',
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a room ID';
                  }
                  // Basic UUID format validation
                  final uuidRegex = RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$');
                  if (!uuidRegex.hasMatch(value.trim().toLowerCase())) {
                    return 'Please enter a valid room ID';
                  }
                  return null;
                },
              ),
              
              const SizedBox(height: 32),
              
              const SizedBox(height: 24),
              
              // Info card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Theme.of(context).primaryColor.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.group_add, color: Theme.of(context).primaryColor),
                        const SizedBox(width: 8),
                        Text(
                          'What happens next?',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).primaryColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '• Your responses will be shared anonymously with this room, but only displayed when 5+ chameleons have responded to the same question\n\n'
                      '• This room\'s responses will be included in your "My Network vs World" comparisons and vice-versa\n\n'
                      '• You can leave the room whenever you want',
                      style: TextStyle(fontSize: 14),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 32),
              
              // Join button
              ElevatedButton(
                onPressed: _isLoading ? null : _joinRoom,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Text(
                        'Join Room',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
              
              const SizedBox(height: 16),
              
              // Cancel button
              TextButton(
                onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
