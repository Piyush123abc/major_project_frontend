class GlobalStore {
  static Map<String, dynamic>? teacherProfile;

  // Helper to safely get the teacher's UID
  static String get teacherUid => teacherProfile?['uid'] ?? "UNKNOWN_TEACHER";
}
