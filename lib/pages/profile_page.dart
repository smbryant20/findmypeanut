import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _form = GlobalKey<FormState>();
  final _displayName = TextEditingController();
  final _avatarUrl = TextEditingController();
  final _bio = TextEditingController();
  final _instagram = TextEditingController();
  final _tiktok = TextEditingController();
  final _facebook = TextEditingController();
  final _twitter = TextEditingController();
  final _picker = ImagePicker();

  bool _loading = true;
  final _sb = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _pickAndUploadAvatar() async {
    final user = _sb.auth.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in first.')),
      );
      return;
    }

    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (picked == null) return;

    final bytes = await picked.readAsBytes();
    final ext = p.extension(picked.name).toLowerCase();
    final safeExt =
        (ext.isEmpty || !['.jpg', '.jpeg', '.png', '.webp'].contains(ext))
            ? '.jpg'
            : ext;
    final path = '${user.id}/${DateTime.now().millisecondsSinceEpoch}$safeExt';

    setState(() => _loading = true);
    try {
      await _sb.storage.from('avatars').uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(
              contentType: safeExt == '.png'
                  ? 'image/png'
                  : safeExt == '.webp'
                      ? 'image/webp'
                      : 'image/jpeg',
              upsert: true,
            ),
          );

      // Public URL for immediate display
      final publicUrl = _sb.storage.from('avatars').getPublicUrl(path);

      // Update local UI immediately
      setState(() {
        _avatarUrl.text = publicUrl;
      });

      // Persist to profile
      await _sb.from('profiles').upsert({
        'auth_id': user.id,
        'avatar_url': publicUrl,
        'updated_at': DateTime.now().toIso8601String(),
      });

      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Avatar updated')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed: $e')),
      );
    }
  }

  Future<void> _load() async {
    final user = _sb.auth.currentUser;
    if (user == null) {
      setState(() => _loading = false);
      return;
    }
    final res = await _sb
        .from('profiles')
        .select()
        .eq('auth_id', user.id)
        .maybeSingle();

    if (res != null) {
      _displayName.text = res['display_name'] ?? '';
      _avatarUrl.text = res['avatar_url'] ?? '';
      _bio.text = res['bio'] ?? '';
      _instagram.text = res['instagram_url'] ?? '';
      _tiktok.text = res['tiktok_url'] ?? '';
      _facebook.text = res['facebook_url'] ?? '';
      _twitter.text = res['twitter_url'] ?? '';
    }
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    final user = _sb.auth.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in first.')),
      );
      return;
    }

    _form.currentState?.save();
    setState(() => _loading = true);

    final payload = {
      'auth_id': user.id,
      'display_name': _displayName.text.trim(),
      'avatar_url': _avatarUrl.text.trim(),
      'bio': _bio.text.trim(),
      'instagram_url': _instagram.text.trim(),
      'tiktok_url': _tiktok.text.trim(),
      'facebook_url': _facebook.text.trim(),
      'twitter_url': _twitter.text.trim(),
      'updated_at': DateTime.now().toIso8601String(),
    };

    try {
      await _sb.from('profiles').upsert(payload);
      setState(() => _loading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile saved')),
      );
    } catch (e) {
      setState(() => _loading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving profile: $e')),
      );
    }
  }

  Future<void> _signOut() async {
    await _sb.auth.signOut();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Signed out')),
    );
    setState(() {}); // refresh UI
  }

  @override
  void dispose() {
    _displayName.dispose();
    _avatarUrl.dispose();
    _bio.dispose();
    _instagram.dispose();
    _tiktok.dispose();
    _facebook.dispose();
    _twitter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            tooltip: 'Save',
            icon: const Icon(Icons.save),
            onPressed: _loading ? null : _save,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Center(
                    child: Column(
                      children: [
                        CircleAvatar(
                          radius: 42,
                          backgroundColor: scheme.primaryContainer,
                          backgroundImage: (_avatarUrl.text.isNotEmpty)
                              ? NetworkImage(_avatarUrl.text)
                              : null,
                          child: (_avatarUrl.text.isEmpty)
                              ? Icon(Icons.person,
                                  color: scheme.onPrimaryContainer, size: 42)
                              : null,
                        ),
                        const SizedBox(height: 12),
                        TextButton.icon(
                          onPressed: _loading ? null : _pickAndUploadAvatar,
                          icon: const Icon(Icons.image_outlined),
                          label: const Text('Change photo'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _displayName,
                    decoration:
                        const InputDecoration(labelText: 'Display name'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _bio,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Bio',
                      hintText: 'Owner of a brown lab named Daisy…',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Social links',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _instagram,
                    decoration: const InputDecoration(
                      labelText: 'Instagram URL',
                      prefixIcon: Icon(Icons.link),
                      hintText: 'https://instagram.com/yourname',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _tiktok,
                    decoration: const InputDecoration(
                      labelText: 'TikTok URL',
                      prefixIcon: Icon(Icons.link),
                      hintText: 'https://www.tiktok.com/@yourname',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _facebook,
                    decoration: const InputDecoration(
                      labelText: 'Facebook URL',
                      prefixIcon: Icon(Icons.link),
                      hintText: 'https://facebook.com/yourpage',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _twitter,
                    decoration: const InputDecoration(
                      labelText: 'X (Twitter) URL',
                      prefixIcon: Icon(Icons.link),
                      hintText: 'https://x.com/yourname',
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _loading ? null : _save,
                    icon: const Icon(Icons.save),
                    label: const Text('Save changes'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _signOut,
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out'),
                  ),
                  const SizedBox(height: 24),
                  const MyReportsSection(),
                ],
              ),
            ),
    );
  }
}

class MyReportsSection extends StatefulWidget {
  const MyReportsSection({super.key});
  @override
  State<MyReportsSection> createState() => _MyReportsSectionState();
}

class _MyReportsSectionState extends State<MyReportsSection> {
  final sb = Supabase.instance.client;
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user = sb.auth.currentUser;
    if (user == null) {
      setState(() {
        _rows = [];
        _loading = false;
      });
      return;
    }
    try {
      final res = await sb
          .from('reports')
          .select('id, kind, city, state, country, created_at, status, images')
          .eq('created_by', user.id)
          .order('created_at', ascending: false);
      setState(() {
        _rows = (res as List).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading your reports: $e')),
      );
    }
  }

  Color _statusColor(String s, BuildContext ctx) {
    final cs = Theme.of(ctx).colorScheme;
    switch (s) {
      case 'RESOLVED':
        return cs.tertiary;
      case 'MATCHED':
        return cs.secondary;
      default:
        return cs.primary; // OPEN
    }
  }

  Future<void> _updateStatus(String id, String status) async {
    try {
      await sb.from('reports').update({'status': status}).eq('id', id);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Status set to $status')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update status: $e')),
      );
    }
  }

  Future<void> _deleteReport(Map<String, dynamic> row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete report?'),
        content: const Text(
          'This will permanently remove the report and its images.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;

    try {
      // Try to delete Storage files (images are public URLs)
      final images = (row['images'] as List?)?.cast<String>() ?? const [];
      if (images.isNotEmpty) {
        final paths = <String>[];
        for (final url in images) {
          // format: https://<proj>.supabase.co/storage/v1/object/public/reports/<path>
          final idx = url.indexOf('/public/reports/');
          if (idx != -1) {
            final path = url.substring(idx + '/public/reports/'.length);
            paths.add(path);
          }
        }
        if (paths.isNotEmpty) {
          await sb.storage.from('reports').remove(paths);
        }
      }

      // Delete the DB row
      await sb.from('reports').delete().eq('id', row['id']);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report deleted')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('You haven’t posted any reports yet.'),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('My Reports', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          ListView.separated(
            itemCount: _rows.length,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final r = _rows[i];
              final status = (r['status'] ?? 'OPEN') as String;
              final images = (r['images'] as List?)?.cast<String>() ?? const [];

              return Card(
                child: ListTile(
                  leading: (images.isEmpty)
                      ? const Icon(Icons.pets, size: 32)
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.network(
                            images.first,
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                          ),
                        ),
                  title: Text(
                      '${(r['kind'] ?? '').toString().toUpperCase()} · ${r['city'] ?? ''}'),
                  subtitle: Text(
                    (r['state'] ?? '').toString().isEmpty
                        ? (r['country'] ?? '').toString()
                        : '${r['state']} · ${r['country']}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color:
                              _statusColor(status, context).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          status,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: _statusColor(status, context),
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        onSelected: (val) {
                          switch (val) {
                            case 'edit':
                              context
                                  .push('/report/${r['id']}/edit')
                                  .then((_) => _load());
                              break;
                            case 'delete':
                              _deleteReport(r);
                              break;
                            case 'status_open':
                              _updateStatus(r['id'] as String, 'OPEN');
                              break;
                            case 'status_resolved':
                              _updateStatus(r['id'] as String, 'RESOLVED');
                              break;
                            case 'status_matched':
                              _updateStatus(r['id'] as String, 'MATCHED');
                              break;
                          }
                        },
                        itemBuilder: (ctx) => const [
                          PopupMenuItem(
                              value: 'edit',
                              child: ListTile(
                                  leading: Icon(Icons.edit),
                                  title: Text('Edit'))),
                          PopupMenuItem(
                              value: 'delete',
                              child: ListTile(
                                  leading: Icon(Icons.delete_outline),
                                  title: Text('Delete'))),
                          PopupMenuDivider(),
                          PopupMenuItem(
                              value: 'status_open',
                              child: ListTile(
                                  leading: Icon(Icons.circle_outlined),
                                  title: Text('Mark Open'))),
                          PopupMenuItem(
                              value: 'status_resolved',
                              child: ListTile(
                                  leading: Icon(Icons.check_circle_outline),
                                  title: Text('Mark Resolved'))),
                          PopupMenuItem(
                              value: 'status_matched',
                              child: ListTile(
                                  leading: Icon(Icons.link),
                                  title: Text('Mark Matched'))),
                        ],
                      ),
                    ],
                  ),
                  onTap: () => context.push('/report/${r['id']}'),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
