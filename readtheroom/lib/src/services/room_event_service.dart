// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import '../models/room.dart';

class RoomEventService {
  static final RoomEventService _instance = RoomEventService._internal();
  factory RoomEventService() => _instance;
  RoomEventService._internal();

  final StreamController<Room> _roomJoinedController = StreamController<Room>.broadcast();
  final StreamController<String> _roomLeftController = StreamController<String>.broadcast();

  Stream<Room> get onRoomJoined => _roomJoinedController.stream;
  Stream<String> get onRoomLeft => _roomLeftController.stream;

  void notifyRoomJoined(Room room) {
    print('🎪 RoomEventService - Broadcasting room joined: ${room.name}');
    _roomJoinedController.add(room);
  }

  void notifyRoomLeft(String roomId) {
    print('🎪 RoomEventService - Broadcasting room left: $roomId');
    _roomLeftController.add(roomId);
  }

  void dispose() {
    _roomJoinedController.close();
    _roomLeftController.close();
  }
}