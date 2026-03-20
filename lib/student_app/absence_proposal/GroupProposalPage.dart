import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';

import '../../global_variable/base_url.dart';
import '../../global_variable/token_handles.dart';

class GroupProposalPage extends StatefulWidget {
  const GroupProposalPage({super.key});

  @override
  State<GroupProposalPage> createState() => _GroupProposalPageState();
}

class _GroupProposalPageState extends State<GroupProposalPage> {
  bool _isLoading = false;
  Future<List<dynamic>>? _historyFuture;

  // --- Controllers for JOIN Tab ---
  final TextEditingController _groupIdController = TextEditingController();
  final TextEditingController _joinPasswordController = TextEditingController();

  // --- Controllers & State for CREATE Tab ---
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descController = TextEditingController();
  final TextEditingController _createPasswordController =
      TextEditingController();
  String? _selectedReason;
  DateTime? _startDateTime;
  DateTime? _endDateTime;
  PlatformFile? _selectedFile;

  @override
  void initState() {
    super.initState();
    _historyFuture = _fetchHistory(); // Load history when page opens
  }

  @override
  void dispose() {
    _groupIdController.dispose();
    _joinPasswordController.dispose();
    _titleController.dispose();
    _descController.dispose();
    _createPasswordController.dispose();
    super.dispose();
  }

  // ==========================================
  // API CALLS & LOGIC
  // ==========================================

  Future<void> _refreshHistory() async {
    setState(() {
      _historyFuture = _fetchHistory();
    });
  }

  Future<void> _submitJoinRequest() async {
    final groupId = _groupIdController.text.trim();
    final password = _joinPasswordController.text.trim();

    if (groupId.isEmpty || password.isEmpty) {
      _showSnackBar("Please fill in both fields");
      return;
    }

    setState(() => _isLoading = true);

    try {
      var response = await http.post(
        Uri.parse("${BaseUrl.value}user/group-absence-proposals/join/"),
        headers: await TokenHandles.getAuthHeaders().then(
          (h) => {...h, 'Content-Type': 'application/json'},
        ),
        body: jsonEncode({"group_id": groupId, "join_password": password}),
      );

      if (response.statusCode == 401) {
        if (await TokenHandles.refreshAccessToken()) {
          response = await http.post(
            Uri.parse("${BaseUrl.value}user/group-absence-proposals/join/"),
            headers: await TokenHandles.getAuthHeaders().then(
              (h) => {...h, 'Content-Type': 'application/json'},
            ),
            body: jsonEncode({"group_id": groupId, "join_password": password}),
          );
        }
      }

      if (response.statusCode == 200) {
        _showSnackBar("✅ Successfully joined the group!");
        _groupIdController.clear();
        _joinPasswordController.clear();
        _refreshHistory(); // Refresh history tab
      } else {
        final error = jsonDecode(response.body)['error'] ?? "Failed to join";
        _showSnackBar("❌ Error: $error");
      }
    } catch (e) {
      _showSnackBar("Network error occurred.");
    }

    setState(() => _isLoading = false);
  }

  Future<void> _submitCreateRequest() async {
    if (_titleController.text.isEmpty ||
        _selectedReason == null ||
        _createPasswordController.text.isEmpty ||
        _startDateTime == null ||
        _endDateTime == null) {
      _showSnackBar(
        "Please fill in all required fields (Document is optional).",
      );
      return;
    }

    if (_endDateTime!.isBefore(_startDateTime!)) {
      _showSnackBar("End date must be after start date.");
      return;
    }

    setState(() => _isLoading = true);

    try {
      var uri = Uri.parse(
        "${BaseUrl.value}user/group-absence-proposals/create/",
      );
      var request = http.MultipartRequest('POST', uri);

      request.headers.addAll(await TokenHandles.getAuthHeaders());

      // Add Text Fields
      request.fields['title'] = _titleController.text.trim();
      request.fields['reason_type'] = _selectedReason!;
      request.fields['reason_description'] = _descController.text.trim();
      request.fields['join_password'] = _createPasswordController.text.trim();
      request.fields['start_datetime'] = _startDateTime!
          .toUtc()
          .toIso8601String();
      request.fields['end_datetime'] = _endDateTime!.toUtc().toIso8601String();

      // Add Optional File
      if (_selectedFile != null && _selectedFile!.path != null) {
        request.files.add(
          await http.MultipartFile.fromPath('document', _selectedFile!.path!),
        );
      }

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 201) {
        final data = jsonDecode(response.body);
        _showSnackBar("✅ Group created! ID: ${data['id']}");

        // Clear form
        _titleController.clear();
        _descController.clear();
        _createPasswordController.clear();
        setState(() {
          _selectedReason = null;
          _startDateTime = null;
          _endDateTime = null;
          _selectedFile = null;
        });

        _refreshHistory(); // Refresh history tab
      } else {
        _showSnackBar("❌ Failed to create group.");
      }
    } catch (e) {
      _showSnackBar("Network error occurred.");
    }

    setState(() => _isLoading = false);
  }

  Future<List<dynamic>> _fetchHistory() async {
    var response = await http.get(
      Uri.parse("${BaseUrl.value}user/group-absence-proposals/history/"),
      headers: await TokenHandles.getAuthHeaders(),
    );

    if (response.statusCode == 401) {
      if (await TokenHandles.refreshAccessToken()) {
        response = await http.get(
          Uri.parse("${BaseUrl.value}user/group-absence-proposals/history/"),
          headers: await TokenHandles.getAuthHeaders(),
        );
      }
    }

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as List<dynamic>;
    }
    throw Exception("Failed to load history");
  }

  // ==========================================
  // UI HELPERS
  // ==========================================

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _pickDateTime(bool isStart) async {
    DateTime? date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime(2030),
    );
    if (date == null) return;

    TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (time == null) return;

    setState(() {
      DateTime finalDateTime = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      if (isStart) {
        _startDateTime = finalDateTime;
      } else {
        _endDateTime = finalDateTime;
      }
    });
  }

  Future<void> _pickDocument() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'png', 'jpeg'],
    );

    if (result != null) {
      setState(() {
        _selectedFile = result.files.first;
      });
    }
  }

  // ==========================================
  // BUILD METHODS
  // ==========================================

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Group Leave"),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.group_add), text: "Join"),
              Tab(icon: Icon(Icons.add_circle_outline), text: "Create"),
              Tab(icon: Icon(Icons.history), text: "My Groups"),
            ],
          ),
        ),
        body: Stack(
          children: [
            TabBarView(
              children: [
                _buildJoinTab(),
                _buildCreateTab(),
                _buildHistoryTab(),
              ],
            ),
            if (_isLoading)
              Container(
                color: Colors.black.withOpacity(0.3),
                child: const Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildJoinTab() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.hub, size: 80, color: Colors.blueAccent),
          const SizedBox(height: 20),
          const Text(
            "Join an Existing Group",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            "Ask your team leader for the Group ID and Password.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 30),
          TextField(
            controller: _groupIdController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: "Group ID",
              prefixIcon: Icon(Icons.tag),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _joinPasswordController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: "Join Password",
              prefixIcon: Icon(Icons.lock_outline),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              textStyle: const TextStyle(fontSize: 18),
            ),
            onPressed: _isLoading ? null : _submitJoinRequest,
            child: const Text("Join Group"),
          ),
        ],
      ),
    );
  }

  Widget _buildCreateTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            "Create a New Group Leave",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),

          TextFormField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: "Event Title *",
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),

          DropdownButtonFormField<String>(
            value: _selectedReason,
            decoration: const InputDecoration(
              labelText: "Reason Type *",
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: "ACADEMIC", child: Text("Academic")),
              DropdownMenuItem(value: "SPORTS", child: Text("Sports")),
              DropdownMenuItem(value: "EVENT", child: Text("Cultural Event")),
              DropdownMenuItem(value: "OTHER", child: Text("Other")),
            ],
            onChanged: (val) => setState(() => _selectedReason = val),
          ),
          const SizedBox(height: 16),

          TextFormField(
            controller: _descController,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: "Description (Optional)",
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),

          TextFormField(
            controller: _createPasswordController,
            decoration: const InputDecoration(
              labelText: "Set a Join Password *",
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),

          // Date & Time Pickers
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_today, size: 18),
                  label: Text(
                    _startDateTime == null
                        ? "Start Date/Time *"
                        : DateFormat('MMM dd, hh:mm a').format(_startDateTime!),
                  ),
                  onPressed: () => _pickDateTime(true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.event_busy, size: 18),
                  label: Text(
                    _endDateTime == null
                        ? "End Date/Time *"
                        : DateFormat('MMM dd, hh:mm a').format(_endDateTime!),
                  ),
                  onPressed: () => _pickDateTime(false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Document Upload
          ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: Colors.grey.shade400),
            ),
            leading: const Icon(Icons.attach_file),
            title: Text(
              _selectedFile == null
                  ? "Attach Proof Document (Optional)"
                  : _selectedFile!.name,
            ),
            trailing: _selectedFile != null
                ? IconButton(
                    icon: const Icon(Icons.clear, color: Colors.red),
                    onPressed: () => setState(() => _selectedFile = null),
                  )
                : null,
            onTap: _pickDocument,
          ),

          const SizedBox(height: 24),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            onPressed: _isLoading ? null : _submitCreateRequest,
            child: const Text(
              "Create & Get Group ID",
              style: TextStyle(fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryTab() {
    return RefreshIndicator(
      onRefresh: _refreshHistory,
      child: FutureBuilder<List<dynamic>>(
        future: _historyFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(height: MediaQuery.of(context).size.height * 0.3),
                const Center(
                  child: Text("Error loading history. Pull to refresh."),
                ),
              ],
            );
          } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(height: MediaQuery.of(context).size.height * 0.3),
                const Center(
                  child: Text(
                    "No group proposals found. Pull to refresh.",
                    style: TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                ),
              ],
            );
          }

          final history = snapshot.data!;

          return ListView.builder(
            physics:
                const AlwaysScrollableScrollPhysics(), // Ensures it can always be pulled down
            padding: const EdgeInsets.all(12),
            itemCount: history.length,
            itemBuilder: (context, index) {
              final group = history[index];
              final isApproved = group['status'] == 'APPROVED';
              final isRejected = group['status'] == 'REJECTED';

              return Card(
                elevation: 2,
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  title: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          group['title'] ?? 'No Title',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Chip(
                        label: Text(
                          group['status'],
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                        backgroundColor: isApproved
                            ? Colors.green
                            : (isRejected ? Colors.red : Colors.orange),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(
                      top: 16.0,
                    ), // FIX APPLIED HERE
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "ID: ${group['id']} | Leader: ${group['leader_name']}",
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "Starts: ${DateFormat('MMM dd, yyyy - hh:mm a').format(DateTime.parse(group['start_datetime']).toLocal())}",
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
