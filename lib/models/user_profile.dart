/// Immutable snapshot of the in-app user (display name, demographics, onboarding flag).
/// Use [toMap] / [fromMap] for simple key–value persistence; fields align with profile prefs elsewhere.
class UserProfile {
  final String name;
  final String sex;
  final int age;

  /// Whether this record represents a first-time user (e.g. onboarding or tutorial gating).
  final bool isNewUser;

  const UserProfile({
    required this.name,
    required this.sex,
    required this.age,
    this.isNewUser = true,
  });

  /// Returns a new profile; any argument left `null` keeps the current field value.
  UserProfile copyWith({
    String? name,
    String? sex,
    int? age,
    bool? isNewUser,
  }) {
    return UserProfile(
      name: name ?? this.name,
      sex: sex ?? this.sex,
      age: age ?? this.age,
      isNewUser: isNewUser ?? this.isNewUser,
    );
  }

  /// JSON-friendly map using keys `name`, `sex`, `age`, `isNewUser`.
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'sex': sex,
      'age': age,
      'isNewUser': isNewUser,
    };
  }

  /// Inverse of [toMap]; expects the same keys and runtime types.
  factory UserProfile.fromMap(Map<String, dynamic> map) {
    return UserProfile(
      name: map['name'] as String,
      sex: map['sex'] as String,
      age: map['age'] as int,
      isNewUser: map['isNewUser'] as bool,
    );
  }
} 