// lib/teacher_app/pending_proposals_page.dart
import 'dart:convert';
import 'package:attendance_app/global_variable/base_url.dart';
import 'package:attendance_app/global_variable/token_handles.dart';
import 'package:attendance_app/teacher_app/absence_proposals/proposal_detial.dart'; // Ensure this path is correct
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

class PendingProposalsPage extends StatefulWidget {
  const PendingProposalsPage({super.key});

  @override
  State<PendingProposalsPage> createState() => _PendingProposalsPageState();
}

class _PendingProposalsPageState extends State<PendingProposalsPage> {
  bool _isLoadingIndividual = true;
  bool _isLoadingGroup = true;
  String _statusMessageIndividual = "";
  String _statusMessageGroup = "";

  List<dynamic> _individualProposals = [];
  List<dynamic> _groupProposals = [];

  @override
  void initState() {
    super.initState();
    _fetchAllProposals();
  }

  Future<void> _fetchAllProposals() async {
    _fetchIndividualProposals();
    _fetchGroupProposals();
  }

  // --- Fetch Individual Proposals ---
  Future<void> _fetchIndividualProposals() async {
    setState(() {
      _isLoadingIndividual = true;
      _statusMessageIndividual = "";
    });

    try {
      final response = await http.get(
        Uri.parse("${BaseUrl.value}user/teacher/absence-proposals/pending/"),
        headers: await TokenHandles.getAuthHeaders(),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _individualProposals = data;
        });
      } else {
        setState(
          () => _statusMessageIndividual =
              "❌ Failed to load: ${response.statusCode}",
        );
      }
    } catch (e) {
      setState(() => _statusMessageIndividual = "❌ Error: $e");
    }

    setState(() => _isLoadingIndividual = false);
  }

  // --- Fetch Group Proposals ---
  Future<void> _fetchGroupProposals() async {
    setState(() {
      _isLoadingGroup = true;
      _statusMessageGroup = "";
    });

    try {
      final response = await http.get(
        Uri.parse(
          "${BaseUrl.value}user/teacher/group-absence-proposals/pending/",
        ),
        headers: await TokenHandles.getAuthHeaders(),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _groupProposals = data;
        });
      } else {
        setState(
          () =>
              _statusMessageGroup = "❌ Failed to load: ${response.statusCode}",
        );
      }
    } catch (e) {
      setState(() => _statusMessageGroup = "❌ Error: $e");
    }

    setState(() => _isLoadingGroup = false);
  }

  String _formatDate(String dateStr) {
    try {
      return DateFormat(
        'MMM dd, hh:mm a',
      ).format(DateTime.parse(dateStr).toLocal());
    } catch (_) {
      return dateStr;
    }
  }

  // --- UI Builders ---
  Widget _buildIndividualCard(dynamic proposal) {
    final student = proposal['student'] ?? {};
    final start = _formatDate(proposal['start_datetime'] ?? '');
    final end = _formatDate(proposal['end_datetime'] ?? '');
    final reason = proposal['reason_type'] ?? '';
    final uid = student['uid'] ?? '';
    final name = student['username'] ?? '';

    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: Colors.blueAccent,
          child: Icon(Icons.person, color: Colors.white),
        ),
        title: Text(
          "$name ($uid)",
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text("Reason: $reason\nTime: $start → $end"),
        isThreeLine: true,
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  PendingProposalDetailPage(proposal: proposal),
            ),
          );
          _fetchIndividualProposals(); // Reload after return
        },
      ),
    );
  }

  Widget _buildGroupCard(dynamic group) {
    final title = group['title'] ?? 'No Title';
    final leader = group['leader_name'] ?? 'Unknown';
    final start = _formatDate(group['start_datetime'] ?? '');
    final count = (group['participants'] as List).length;

    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: Colors.deepPurple,
          child: Icon(Icons.groups, color: Colors.white),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(
          "Leader: $leader\nStarts: $start\nTeam Size: $count students",
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  GroupPendingProposalDetailPage(proposal: group),
            ),
          );
          _fetchGroupProposals(); // Reload after return
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Pending Proposals"),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.person), text: "Individual"),
              Tab(icon: Icon(Icons.groups), text: "Group"),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // TAB 1: Individual
            RefreshIndicator(
              onRefresh: _fetchIndividualProposals,
              child: _isLoadingIndividual
                  ? const Center(child: CircularProgressIndicator())
                  : _individualProposals.isEmpty
                  ? Center(
                      child: Text(
                        _statusMessageIndividual.isEmpty
                            ? "✅ No pending individual proposals"
                            : _statusMessageIndividual,
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      itemCount: _individualProposals.length,
                      itemBuilder: (context, index) =>
                          _buildIndividualCard(_individualProposals[index]),
                    ),
            ),
            // TAB 2: Group
            RefreshIndicator(
              onRefresh: _fetchGroupProposals,
              child: _isLoadingGroup
                  ? const Center(child: CircularProgressIndicator())
                  : _groupProposals.isEmpty
                  ? Center(
                      child: Text(
                        _statusMessageGroup.isEmpty
                            ? "✅ No pending group proposals"
                            : _statusMessageGroup,
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      itemCount: _groupProposals.length,
                      itemBuilder: (context, index) =>
                          _buildGroupCard(_groupProposals[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
