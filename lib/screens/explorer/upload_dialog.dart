import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import '../../providers/app_state.dart';

class UploadProjectDialog extends StatefulWidget {
  const UploadProjectDialog({super.key});
  @override
  State<UploadProjectDialog> createState() => _UploadProjectDialogState();
}

class _UploadProjectDialogState extends State<UploadProjectDialog> {
  String? _selectedDir;
  String _projectName = '';
  bool _uploading = false;
  double _progress = 0;
  String _status = '';
  String? _error;
  String? _remotePath;
  bool _overwrite = false;
  int _fileCount = 0;
  int _totalSize = 0;

  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickDir() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select project folder',
    );
    if (result != null) {
      final name = result.split(Platform.pathSeparator).where((s) => s.isNotEmpty).last;
      setState(() {
        _selectedDir = result;
        _projectName = name;
        _nameController.text = name;
      });
    }
  }

  Future<void> _upload() async {
    if (_selectedDir == null || _projectName.isEmpty) return;
    // Capture api before async gaps so we never touch context after await.
    final api = context.read<AppState>().api;
    setState(() {
      _uploading = true;
      _progress = 0;
      _error = null;
      _remotePath = null;
      _status = 'Packing...';
      _fileCount = 0;
      _totalSize = 0;
    });

    try {
      // Pack directory into tar.gz
      final archive = Archive();
      final dir = Directory(_selectedDir!);
      final baseLen = dir.path.length + 1;
      int fileCount = 0;
      int totalSize = 0;

      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final rel = entity.path.substring(baseLen);
          // Skip common ignores
          if (rel.contains('/.git/') || rel.startsWith('.git/') ||
              rel.contains('/node_modules/') || rel.startsWith('node_modules/') ||
              rel.contains('/build/') || rel.startsWith('build/') ||
              rel.contains('/.dart_tool/') || rel.startsWith('.dart_tool/') ||
              rel.contains('/target/') || rel.startsWith('target/') ||
              rel.contains('/dist/') || rel.startsWith('dist/') ||
              rel.contains('/.next/') || rel.startsWith('.next/') ||
              rel.endsWith('.DS_Store')) {
            continue;
          }
          try {
            final bytes = await entity.readAsBytes();
            archive.addFile(ArchiveFile(rel, bytes.length, bytes));
            fileCount++;
            totalSize += bytes.length;
            if (fileCount % 50 == 0 && mounted) {
              setState(() {
                _status = 'Packing... $fileCount files';
                _fileCount = fileCount;
                _totalSize = totalSize;
              });
            }
          } catch (_) {
            // Skip unreadable files
          }
        }
      }

      if (mounted) {
        setState(() {
          _status = 'Compressing...';
          _fileCount = fileCount;
          _totalSize = totalSize;
        });
      }

      final tarData = TarEncoder().encode(archive);
      final gzData = GZipEncoder().encode(tarData);
      if (gzData == null) throw Exception('Compression failed');

      // Step 1: get Yandex Disk upload URL from server
      if (mounted) {
        setState(() {
          _status = 'Requesting Yandex Disk URL...';
          _progress = 0.25;
        });
      }
      final urlData = await api.getYadiskUploadUrl(_projectName);
      final href = urlData['href'] as String;
      final diskPath = urlData['diskPath'] as String;

      // Step 2: upload directly to Yandex Disk
      if (mounted) {
        setState(() {
          _status = 'Uploading ${(gzData.length / 1024 / 1024).toStringAsFixed(1)} MB to Yandex Disk...';
          _progress = 0.3;
        });
      }

      // Write tar.gz to temp file, upload from file stream (reliable for HTTPS PUT)
      final tmpDir = Directory.systemTemp;
      final tmpFile = File('${tmpDir.path}/planulix-upload-${DateTime.now().millisecondsSinceEpoch}.tar.gz');
      await tmpFile.writeAsBytes(gzData, flush: true);

      try {
        final httpClient = HttpClient();
        httpClient.connectionTimeout = const Duration(minutes: 2);
        httpClient.idleTimeout = const Duration(hours: 1);

        final uri = Uri.parse(href);
        final httpReq = await httpClient.putUrl(uri);
        httpReq.headers.set('Content-Type', 'application/gzip');
        httpReq.contentLength = gzData.length;

        int sent = 0;
        final totalBytes = gzData.length;
        var lastTick = DateTime.now();

        // Stream file in chunks, reporting real bytes pushed
        await tmpFile.openRead().forEach((chunk) {
          httpReq.add(chunk);
          sent += chunk.length;
          final now = DateTime.now();
          if (now.difference(lastTick).inMilliseconds > 150 && mounted) {
            setState(() {
              _progress = 0.3 + (sent / totalBytes) * 0.5;
              _status = 'Uploading to Yandex Disk... '
                  '${(sent / 1024 / 1024).toStringAsFixed(1)}/'
                  '${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB';
            });
            lastTick = now;
          }
        });

        if (mounted) {
          setState(() {
            _status = 'Finalizing upload...';
            _progress = 0.8;
          });
        }

        final httpResp = await httpReq.close();
        final respBody = await httpResp.transform(const SystemEncoding().decoder).join();
        httpClient.close();

        if (httpResp.statusCode >= 400) {
          throw Exception('Yandex Disk HTTP ${httpResp.statusCode}: $respBody');
        }
      } finally {
        try { await tmpFile.delete(); } catch (_) {}
      }

      // Step 3: ask server to import from Yandex Disk
      if (mounted) {
        setState(() {
          _status = 'Server downloading from Yandex Disk...';
          _progress = 0.85;
        });
      }
      final result = await api.importFromYadisk(diskPath, _projectName, overwrite: _overwrite);

      if (mounted) {
        setState(() {
          _uploading = false;
          _progress = 1.0;
          _status = 'Done!';
          _remotePath = result['path'] as String?;
          _fileCount = (result['fileCount'] as num?)?.toInt() ?? fileCount;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _uploading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1e293b),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Container(
        width: 540,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.cloud_upload_outlined, size: 20, color: Color(0xFF8b5cf6)),
                SizedBox(width: 10),
                Text('Upload Project', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Pack a local folder and upload it to ~/projects on the remote server',
              style: TextStyle(fontSize: 11, color: Color(0xFF94a3b8)),
            ),
            const SizedBox(height: 20),

            // Local folder picker
            InkWell(
              onTap: _uploading ? null : _pickDir,
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0f172a),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: _selectedDir != null ? const Color(0xFF8b5cf6) : const Color(0xFF334155),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _selectedDir != null ? Icons.folder : Icons.folder_open,
                      size: 18,
                      color: _selectedDir != null ? const Color(0xFF8b5cf6) : const Color(0xFF64748b),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _selectedDir ?? 'Click to choose local folder...',
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: _selectedDir != null ? const Color(0xFFe2e8f0) : const Color(0xFF64748b),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Name field
            const Text('Remote project name', style: TextStyle(fontSize: 11, color: Color(0xFF94a3b8))),
            const SizedBox(height: 4),
            TextField(
              controller: _nameController,
              enabled: !_uploading,
              onChanged: (v) => setState(() => _projectName = v),
              decoration: InputDecoration(
                hintText: 'my-project',
                hintStyle: const TextStyle(color: Color(0xFF64748b), fontSize: 12),
                filled: true,
                fillColor: const Color(0xFF0f172a),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF334155))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF334155))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF8b5cf6))),
              ),
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 8),

            Row(
              children: [
                Checkbox(
                  value: _overwrite,
                  onChanged: _uploading ? null : (v) => setState(() => _overwrite = v ?? false),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  activeColor: const Color(0xFF8b5cf6),
                ),
                const Text('Overwrite if exists', style: TextStyle(fontSize: 11, color: Color(0xFF94a3b8))),
              ],
            ),

            const SizedBox(height: 12),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Ignored: .git, node_modules, build, .dart_tool, target, dist, .next, .DS_Store',
                style: TextStyle(fontSize: 10, color: Color(0xFF64748b)),
              ),
            ),
            const SizedBox(height: 16),

            // Status / progress
            if (_uploading || _status.isNotEmpty || _error != null || _remotePath != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _error != null
                      ? const Color(0xFFef4444).withAlpha(20)
                      : _remotePath != null
                          ? const Color(0xFF22c55e).withAlpha(20)
                          : const Color(0xFF0f172a),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: _error != null
                        ? const Color(0xFFef4444)
                        : _remotePath != null
                            ? const Color(0xFF22c55e)
                            : const Color(0xFF334155),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_error != null)
                      Text('Error: $_error', style: const TextStyle(fontSize: 11, color: Color(0xFFef4444)))
                    else if (_remotePath != null) ...[
                      const Text('Upload complete!', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF22c55e))),
                      const SizedBox(height: 4),
                      Text('$_fileCount files, ${(_totalSize / 1024 / 1024).toStringAsFixed(1)} MB', style: const TextStyle(fontSize: 10, color: Color(0xFF94a3b8))),
                      Text(_remotePath!, style: const TextStyle(fontSize: 10, color: Color(0xFF94a3b8), fontFamily: 'monospace')),
                    ] else ...[
                      Text(_status, style: const TextStyle(fontSize: 11, color: Color(0xFFcbd5e1))),
                      if (_fileCount > 0) ...[
                        const SizedBox(height: 4),
                        Text('$_fileCount files, ${(_totalSize / 1024 / 1024).toStringAsFixed(1)} MB', style: const TextStyle(fontSize: 10, color: Color(0xFF94a3b8))),
                      ],
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: _progress > 0 ? _progress : null,
                        backgroundColor: const Color(0xFF334155),
                        valueColor: const AlwaysStoppedAnimation(Color(0xFF8b5cf6)),
                      ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 16),

            // Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _uploading ? null : () => Navigator.pop(context, _remotePath),
                  child: Text(_remotePath != null ? 'Done' : 'Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: (_uploading || _selectedDir == null || _projectName.isEmpty)
                      ? null
                      : _upload,
                  icon: _uploading
                      ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.cloud_upload, size: 14),
                  label: Text(_uploading ? 'Uploading...' : 'Upload'),
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF8b5cf6)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
