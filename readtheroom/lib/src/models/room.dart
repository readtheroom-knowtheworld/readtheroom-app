// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// Room data model
class Room {
  final String id;
  final String name;
  final String? description;
  final String? avatarUrl;
  final String inviteCode;
  final bool inviteCodeActive;
  final bool nsfwEnabled;
  final int memberCount;
  final double? rqiScore;
  final int? globalRank;
  final String? createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  Room({
    required this.id,
    required this.name,
    this.description,
    this.avatarUrl,
    required this.inviteCode,
    this.inviteCodeActive = true,
    this.nsfwEnabled = false,
    this.memberCount = 0,
    this.rqiScore,
    this.globalRank,
    this.createdBy,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Room.fromJson(Map<String, dynamic> json) {
    return Room(
      id: json['id'],
      name: json['name'],
      description: json['description'],
      avatarUrl: json['avatar_url'],
      inviteCode: json['invite_code'],
      inviteCodeActive: json['invite_code_active'] ?? true,
      nsfwEnabled: json['nsfw_enabled'] ?? false,
      memberCount: json['member_count'] ?? 0,
      rqiScore: json['rqi_score'] != null ? double.parse(json['rqi_score'].toString()) : null,
      globalRank: json['global_rank'],
      createdBy: json['created_by'],
      createdAt: DateTime.parse(json['created_at']),
      updatedAt: DateTime.parse(json['updated_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'avatar_url': avatarUrl,
      'invite_code': inviteCode,
      'invite_code_active': inviteCodeActive,
      'nsfw_enabled': nsfwEnabled,
      'member_count': memberCount,
      'rqi_score': rqiScore,
      'global_rank': globalRank,
      'created_by': createdBy,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  bool get isUnlocked => memberCount >= 5;
  int get membersNeeded => memberCount < 5 ? 5 - memberCount : 0;
}

// Room member model
class RoomMember {
  final String id;
  final String roomId;
  final String userId;
  final String role;
  final String sharingPreference;
  final double? cqiScore;
  final DateTime joinedAt;
  final DateTime lastActive;
  final bool muted;

  RoomMember({
    required this.id,
    required this.roomId,
    required this.userId,
    this.role = 'member',
    this.sharingPreference = 'manual',
    this.cqiScore,
    required this.joinedAt,
    required this.lastActive,
    this.muted = false,
  });

  factory RoomMember.fromJson(Map<String, dynamic> json) {
    return RoomMember(
      id: json['id'],
      roomId: json['room_id'],
      userId: json['user_id'],
      role: json['role'] ?? 'member',
      sharingPreference: json['sharing_preference'] ?? 'manual',
      cqiScore: json['cqi_score'] != null ? double.parse(json['cqi_score'].toString()) : null,
      joinedAt: DateTime.parse(json['joined_at']),
      lastActive: DateTime.parse(json['last_active']),
      muted: json['muted'] ?? false,
    );
  }

  bool get isAdmin => role == 'admin';
  bool get isModerator => role == 'moderator';
  bool get autoShareEnabled => sharingPreference == 'auto_share_all';
}

// Activity item model
class UserActivityItem {
  final String id;
  final String userId;
  final String activityType;
  final String title;
  final String? subtitle;
  final bool isActionable;
  final String? roomId;
  final String? questionId;
  final Map<String, dynamic>? metadata;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final bool isRead;
  final bool isDismissed;

  UserActivityItem({
    required this.id,
    required this.userId,
    required this.activityType,
    required this.title,
    this.subtitle,
    this.isActionable = false,
    this.roomId,
    this.questionId,
    this.metadata,
    required this.createdAt,
    this.expiresAt,
    this.isRead = false,
    this.isDismissed = false,
  });

  factory UserActivityItem.fromJson(Map<String, dynamic> json) {
    return UserActivityItem(
      id: json['id'],
      userId: json['user_id'],
      activityType: json['activity_type'],
      title: json['title'],
      subtitle: json['subtitle'],
      isActionable: json['is_actionable'] ?? false,
      roomId: json['room_id'],
      questionId: json['question_id'],
      metadata: json['metadata'],
      createdAt: DateTime.parse(json['created_at']),
      expiresAt: json['expires_at'] != null ? DateTime.parse(json['expires_at']) : null,
      isRead: json['is_read'] ?? false,
      isDismissed: json['is_dismissed'] ?? false,
    );
  }

  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }
}