import 'package:equatable/equatable.dart';

/// App user record with stable [id], credentials-style fields, optional local avatar path,
/// and audit timestamps. Extends [Equatable] so lists/blocs can compare users by value.
class User extends Equatable {
  final String id;
  final String username;
  final String email;
  final String? profileImagePath;
  final DateTime createdAt;
  final DateTime updatedAt;

  const User({
    required this.id,
    required this.username,
    required this.email,
    this.profileImagePath,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Fields included in value equality (`==` and `hashCode` via Equatable).
  @override
  List<Object?> get props => [
        id,
        username,
        email,
        profileImagePath,
        createdAt,
        updatedAt,
      ];

  /// Row-shaped map: snake_case keys; dates stored as Unix ms since epoch.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'username': username,
      'email': email,
      'profile_image_path': profileImagePath,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  /// Inverse of [toMap] (e.g. SQLite row or JSON with the same shape).
  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      id: map['id'] as String,
      username: map['username'] as String,
      email: map['email'] as String,
      profileImagePath: map['profile_image_path'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    );
  }

  /// New [User]; for each parameter, `null` means keep the current value.
  User copyWith({
    String? id,
    String? username,
    String? email,
    String? profileImagePath,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return User(
      id: id ?? this.id,
      username: username ?? this.username,
      email: email ?? this.email,
      profileImagePath: profileImagePath ?? this.profileImagePath,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
} 