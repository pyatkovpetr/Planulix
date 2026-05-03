import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';
import 'github_import_dialog.dart';
import 'upload_dialog.dart';

class ProjectPicker extends StatefulWidget {
  const ProjectPicker({super.key});
  @override
  State<ProjectPicker> createState() => _ProjectPickerState();
}

class _ProjectPickerState extends State<ProjectPicker> {
  List<dynamic>? _projects;
  bool _loading = true;
  String? _error;
  final _customPathController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _customPathController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final api = context.read<AppState>().api;
      final list = await api.getProjects();
      if (mounted) setState(() { _projects = list; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1e293b),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Container(
        width: 560,
        height: 520,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.folder_open, size: 18, color: Color(0xFF8b5cf6)),
                const SizedBox(width: 8),
                const Text('Open Project', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () async {
                    final path = await showDialog<String>(
                      context: context,
                      builder: (_) => const GitHubImportDialog(),
                    );
                    if (!context.mounted) return;
                    if (path != null) {
                      Navigator.pop(context, path);
                    }
                  },
                  icon: const Icon(Icons.code, size: 14),
                  label: const Text('GitHub', style: TextStyle(fontSize: 12)),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF334155),
                    foregroundColor: const Color(0xFFe2e8f0),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () async {
                    final result = await showDialog<String>(
                      context: context,
                      builder: (_) => const UploadProjectDialog(),
                    );
                    if (result != null && mounted) {
                      // Refresh project list
                      _load();
                    }
                  },
                  icon: const Icon(Icons.cloud_upload_outlined, size: 14),
                  label: const Text('Upload Local', style: TextStyle(fontSize: 12)),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF8b5cf6),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Custom path
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _customPathController,
                    decoration: InputDecoration(
                      hintText: '/path/to/project',
                      hintStyle: const TextStyle(color: Color(0xFF64748b), fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF0f172a),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF334155))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF334155))),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF8b5cf6))),
                    ),
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    onSubmitted: (v) {
                      if (v.trim().isNotEmpty) Navigator.pop(context, v.trim());
                    },
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    final v = _customPathController.text.trim();
                    if (v.isNotEmpty) Navigator.pop(context, v);
                  },
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF8b5cf6)),
                  child: const Text('Open'),
                ),
              ],
            ),
            const SizedBox(height: 16),

            const Text('DISCOVERED PROJECTS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF94a3b8), letterSpacing: 0.5)),
            const SizedBox(height: 8),

            // Project list
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                  : _error != null
                      ? Center(child: Text(_error!, style: const TextStyle(color: Color(0xFFef4444))))
                      : _projects == null || _projects!.isEmpty
                          ? const Center(
                              child: Text(
                                'No projects found in ~/projects, ~/WORK, ~/code\nEnter a custom path above.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Color(0xFF64748b), fontSize: 12),
                              ),
                            )
                          : ListView.builder(
                              itemCount: _projects!.length,
                              itemBuilder: (_, i) => _projectTile(_projects![i]),
                            ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _projectTile(dynamic proj) {
    final name = proj['name'] as String;
    final path = proj['path'] as String;
    final isGit = proj['isGit'] == true;
    final branch = proj['branch'] as String?;
    final modified = proj['modified'] as int? ?? 0;
    final untracked = proj['untracked'] as int? ?? 0;

    return InkWell(
      onTap: () => Navigator.pop(context, path),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF0f172a),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: Row(
          children: [
            Icon(
              isGit ? Icons.code : Icons.folder_outlined,
              size: 15,
              color: isGit ? const Color(0xFF8b5cf6) : const Color(0xFF64748b),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  Text(path, style: const TextStyle(fontSize: 10, color: Color(0xFF64748b), fontFamily: 'monospace'), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (branch != null) ...[
              const Icon(Icons.account_tree_outlined, size: 11, color: Color(0xFF94a3b8)),
              const SizedBox(width: 3),
              Text(branch, style: const TextStyle(fontSize: 10, color: Color(0xFF94a3b8))),
              const SizedBox(width: 8),
            ],
            if (modified > 0)
              Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFFf59e0b).withAlpha(30),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text('M$modified', style: const TextStyle(fontSize: 9, color: Color(0xFFf59e0b), fontWeight: FontWeight.w600)),
              ),
            if (untracked > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFF22c55e).withAlpha(30),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text('?$untracked', style: const TextStyle(fontSize: 9, color: Color(0xFF22c55e), fontWeight: FontWeight.w600)),
              ),
            const SizedBox(width: 4),
            InkWell(
              onTap: () => _confirmDelete(name, path),
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding: const EdgeInsets.all(4),
                child: const Icon(Icons.delete_outline, size: 14, color: Color(0xFF64748b)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(String name, String path) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1e293b),
        title: const Text('Delete project?', style: TextStyle(fontSize: 15)),
        content: Text(
          'This will permanently delete:\n$path\n\nOn the remote server. This cannot be undone.',
          style: const TextStyle(fontSize: 12, color: Color(0xFF94a3b8)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFef4444)),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.read<AppState>().api.deleteProject(name);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e'), backgroundColor: const Color(0xFFef4444)),
        );
      }
    }
  }
}
