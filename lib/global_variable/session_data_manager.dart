// session_data_manager.dart

/// A simple model to hold the three cryptographic pieces for a session
class SessionCredentials {
  final String kClass;
  final String sessionSeed;
  final String nodeId;

  SessionCredentials({
    required this.kClass,
    required this.sessionSeed,
    required this.nodeId,
  });
}

/// Singleton manager to hold temporary session data globally in memory
class SessionDataManager {
  // 1. Private constructor and static instance for the Singleton pattern
  SessionDataManager._privateConstructor();
  static final SessionDataManager instance =
      SessionDataManager._privateConstructor();

  // 2. In-memory storage: Maps a classroom_id (as String) to its credentials
  final Map<String, SessionCredentials> _activeSessions = {};

  // 3. Check if we already have the keys (so we don't call backend again)
  bool hasCredentials(String classroomId) {
    return _activeSessions.containsKey(classroomId);
  }

  // 4. Save the keys after fetching from Django
  void saveCredentials({
    required String classroomId,
    required String kClass,
    required String sessionSeed,
    required String nodeId,
  }) {
    _activeSessions[classroomId] = SessionCredentials(
      kClass: kClass,
      sessionSeed: sessionSeed,
      nodeId: nodeId,
    );
    print("🔒 Session credentials cached for classroom: $classroomId");
  }

  // 5. Retrieve the keys for BLE encryption/decryption
  SessionCredentials? getCredentials(String classroomId) {
    return _activeSessions[classroomId];
  }

  // 6. CRITICAL: Clear the keys when the 3-minute timer ends!
  void clearSession(String classroomId) {
    _activeSessions.remove(classroomId);
    print("🗑️ Session credentials cleared for classroom: $classroomId");
  }

  // Clear everything (useful for when the user logs out)
  void clearAll() {
    _activeSessions.clear();
  }
}
