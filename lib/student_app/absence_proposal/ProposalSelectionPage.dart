import 'package:attendance_app/student_app/absence_proposal/GroupProposalPage.dart';
import 'package:attendance_app/student_app/absence_proposal/absence_proposal_dashboard.dart';
import 'package:flutter/material.dart';

class ProposalSelectionPage extends StatelessWidget {
  const ProposalSelectionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Apply for Leave"), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              "What type of leave are you applying for?",
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),

            // Option 1: Normal/Individual Proposal
            _buildSelectionCard(
              context,
              title: "Individual Leave",
              description:
                  "Apply for personal medical, academic, or other events.",
              icon: Icons.person_outline,
              color: Colors.blueAccent,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const AbsenceProposalPage(),
                  ),
                );
              },
            ),

            const SizedBox(height: 20),

            // Option 2: Group Proposal
            _buildSelectionCard(
              context,
              title: "Group Leave",
              description:
                  "Apply as a team leader for hackathons, sports, or cultural fests.",
              icon: Icons.groups_outlined,
              color: Colors.deepPurpleAccent,

              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const GroupProposalPage(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // A helper method to create nice-looking, clickable cards
  Widget _buildSelectionCard(
    BuildContext context, {
    required String title,
    required String description,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 40, color: color),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}
