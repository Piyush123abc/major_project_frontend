import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../global_variable/base_url.dart';
import '../../global_variable/token_handles.dart';

class MasterNodesManagerPage extends StatefulWidget {
  final int classroomId;

  const MasterNodesManagerPage({super.key, required this.classroomId});

  @override
  State<MasterNodesManagerPage> createState() => _MasterNodesManagerPageState();
}

class _MasterNodesManagerPageState extends State<MasterNodesManagerPage> {
  List<dynamic> _masterNodes = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchMasterNodes();
  }

  // --- API CALLS ---

  Future<void> _fetchMasterNodes() async {
    setState(() => _isLoading = true);

    Future<http.Response?> tryRequest() async {
      try {
        return await http.get(
          Uri.parse(
            "${BaseUrl.value}/session/teacher/classroom/${widget.classroomId}/master-node/list/",
          ),
          headers: await TokenHandles.getAuthHeaders(),
        );
      } catch (e) {
        return null;
      }
    }

    var response = await tryRequest();

    if (response != null && response.statusCode == 401) {
      final refreshed = await TokenHandles.refreshAccessToken();
      if (refreshed) {
        response = await tryRequest();
      }
    }

    if (response != null && response.statusCode == 200) {
      final data = jsonDecode(response.body);
      setState(() {
        _masterNodes = data["master_nodes"] ?? [];
      });
    } else {
      _showSnackBar("Failed to load master nodes.");
    }

    setState(() => _isLoading = false);
  }

  Future<void> _addMasterNode(String uid) async {
    // Show a loading indicator dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    Future<http.Response?> tryRequest() async {
      final headers = await TokenHandles.getAuthHeaders();
      headers['Content-Type'] = 'application/json'; // Ensure JSON content type

      try {
        return await http.post(
          Uri.parse(
            "${BaseUrl.value}/session/teacher/classroom/${widget.classroomId}/master-node/add/",
          ),
          headers: headers,
          body: jsonEncode({"uid": uid}),
        );
      } catch (e) {
        return null;
      }
    }

    var response = await tryRequest();

    if (response != null && response.statusCode == 401) {
      final refreshed = await TokenHandles.refreshAccessToken();
      if (refreshed) {
        response = await tryRequest();
      }
    }

    Navigator.pop(context); // Remove loading indicator

    if (response != null && response.statusCode == 200) {
      _showSnackBar("Successfully added $uid as Master Node");
      _fetchMasterNodes(); // Refresh list
    } else {
      final errorMsg = response != null
          ? jsonDecode(response.body)['error']
          : "Network error";
      _showSnackBar("Error: $errorMsg");
    }
  }

  Future<void> _removeMasterNode(String uid) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    Future<http.Response?> tryRequest() async {
      final headers = await TokenHandles.getAuthHeaders();
      headers['Content-Type'] = 'application/json';

      try {
        return await http.post(
          Uri.parse(
            "${BaseUrl.value}/session/teacher/classroom/${widget.classroomId}/master-node/remove/",
          ),
          headers: headers,
          body: jsonEncode({"uid": uid}),
        );
      } catch (e) {
        return null;
      }
    }

    var response = await tryRequest();

    if (response != null && response.statusCode == 401) {
      final refreshed = await TokenHandles.refreshAccessToken();
      if (refreshed) {
        response = await tryRequest();
      }
    }

    Navigator.pop(context); // Remove loading indicator

    if (response != null && response.statusCode == 200) {
      _showSnackBar("Removed $uid from Master Nodes");
      _fetchMasterNodes(); // Refresh list
    } else {
      final errorMsg = response != null
          ? jsonDecode(response.body)['error']
          : "Network error";
      _showSnackBar("Error: $errorMsg");
    }
  }

  // --- DIALOGS & UI HELPERS ---

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showAddDialog() {
    final TextEditingController uidController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Add Master Node"),
        content: TextField(
          controller: uidController,
          decoration: const InputDecoration(
            labelText: "Student UID",
            hintText: "Enter exact UID",
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () {
              final uid = uidController.text.trim();
              if (uid.isNotEmpty) {
                Navigator.pop(context);
                _addMasterNode(uid);
              }
            },
            child: const Text("Add"),
          ),
        ],
      ),
    );
  }

  void _showConfirmRemoveDialog(String uid, String username) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Remove Master Node"),
        content: Text(
          "Are you sure you want to remove $username ($uid) from the master nodes list?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context);
              _removeMasterNode(uid);
            },
            child: const Text("Remove"),
          ),
        ],
      ),
    );
  }

  // --- BUILD UI ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Manage Master Nodes"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchMasterNodes,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _masterNodes.isEmpty
          ? _buildEmptyState()
          : RefreshIndicator(
              onRefresh: _fetchMasterNodes,
              child: ListView.builder(
                padding: const EdgeInsets.all(12.0),
                itemCount: _masterNodes.length,
                itemBuilder: (context, index) {
                  final node = _masterNodes[index];
                  return Card(
                    elevation: 2,
                    margin: const EdgeInsets.symmetric(vertical: 8.0),
                    child: ListTile(
                      leading: const CircleAvatar(
                        backgroundColor: Colors.blueAccent,
                        child: Icon(Icons.hub, color: Colors.white),
                      ),
                      title: Text(
                        node['username'] ?? 'Unknown',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text("UID: ${node['uid']}"),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.red,
                        ),
                        onPressed: () => _showConfirmRemoveDialog(
                          node['uid'],
                          node['username'],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddDialog,
        icon: const Icon(Icons.add),
        label: const Text("Add Node"),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.hub_outlined, size: 80, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          const Text(
            "No Master Nodes assigned.",
            style: TextStyle(fontSize: 18, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          const Text(
            "Tap the + button to add trusted students.",
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
