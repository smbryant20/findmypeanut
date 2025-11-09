import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';

class ReportDetailPage extends StatefulWidget {
  final String id;
  const ReportDetailPage({super.key, required this.id});

  @override
  State<ReportDetailPage> createState() => _ReportDetailPageState();
}

class _ReportDetailPageState extends State<ReportDetailPage> {
  Map<String, dynamic>? report;
  Map<String, dynamic>? matchSummary;
  Map<String, dynamic>? ownerRow;

  final sb = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
    _loadOwnerRow();
  }

  // --- Load public view ---
  Future<void> _load() async {
    final base = const String.fromEnvironment('SUPABASE_URL', defaultValue: '');
    final anon =
        const String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');
    final resp = await http.get(
      Uri.parse('$base/rest/v1/reports_public?id=eq.${widget.id}&select=*'),
      headers: {'apikey': anon, 'Authorization': 'Bearer $anon'},
    );
    final list = jsonDecode(resp.body) as List;
    if (mounted && list.isNotEmpty) {
      setState(() => report = Map<String, dynamic>.from(list.first));
    }
  }

  // --- Load private row if owner ---
  Future<void> _loadOwnerRow() async {
    try {
      final r = await sb
          .from('reports')
          .select(
              'id, created_by, raw_text, city, state, country, event_time, images')
          .eq('id', widget.id)
          .maybeSingle();
      if (mounted) {
        setState(
            () => ownerRow = (r == null) ? null : Map<String, dynamic>.from(r));
      }
    } catch (_) {
      if (mounted) setState(() => ownerRow = null);
    }
  }

  // --- Run match function ---
  Future<void> _runMatch() async {
    final fun =
        const String.fromEnvironment('SUPABASE_FUN_URL', defaultValue: '');
    final anon =
        const String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

    if (fun.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Matching service not configured yet.')),
      );
      return;
    }

    try {
      final r = await http.post(
        Uri.parse('$fun/match?report_id=${widget.id}'),
        headers: {'Authorization': 'Bearer $anon'},
      );
      if (!mounted) return;
      if (r.statusCode >= 200 && r.statusCode < 300) {
        setState(() => matchSummary = jsonDecode(r.body));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Match error: ${r.statusCode} ${r.body}')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Match error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (report == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final imgs =
        (report?['images'] as List?)?.whereType<String>().toList() ?? [];
    final status = (report!['status'] ?? 'OPEN') as String;
    final dt = DateTime.tryParse('${report!['event_time']}')?.toLocal();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Report detail'),
        actions: [
          if (ownerRow != null)
            IconButton(
              tooltip: 'Edit report',
              icon: const Icon(Icons.edit),
              onPressed: () async {
                await context.push('/report/${widget.id}/edit');
                if (!mounted) return;
                await _load();
                await _loadOwnerRow();
              },
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            // --- Title and Status ---
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${report!['kind']} · ${report!['city'] ?? ''}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    status,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),

            if (dt != null)
              Text(
                dt.toString(),
                style: Theme.of(context).textTheme.bodySmall,
              ),

            const SizedBox(height: 12),
            Text((report!['raw_text'] ?? '') as String),

            // --- Image carousel ---
            if (imgs.isNotEmpty) ...[
              const SizedBox(height: 12),
              _ImagesCarousel(urls: imgs),
            ],

            const SizedBox(height: 16),
            FilledButton(
              onPressed: _runMatch,
              child: const Text('Find matches'),
            ),

            if (matchSummary != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Matches computed: ${matchSummary!['count']}, '
                  'top: ${jsonEncode(matchSummary!['top'])}',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// --- Image carousel widget ---
class _ImagesCarousel extends StatefulWidget {
  final List<String> urls;
  const _ImagesCarousel({required this.urls});

  @override
  State<_ImagesCarousel> createState() => _ImagesCarouselState();
}

class _ImagesCarouselState extends State<_ImagesCarousel> {
  final _pc = PageController();
  int _index = 0;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.urls.isEmpty) return const SizedBox.shrink();

    return Column(
      children: [
        SizedBox(
          height: 320,
          child: PageView.builder(
            controller: _pc,
            onPageChanged: (i) => setState(() => _index = i),
            itemCount: widget.urls.length,
            itemBuilder: (_, i) {
              final u = widget.urls[i];
              return ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: CachedNetworkImage(
                    imageUrl: u,
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        const Center(child: CircularProgressIndicator()),
                    errorWidget: (_, __, ___) =>
                        const Center(child: Icon(Icons.broken_image)),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          children: List.generate(widget.urls.length, (i) {
            final sel = i == _index;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: sel ? 10 : 8,
              height: sel ? 10 : 8,
              decoration: BoxDecoration(
                color: sel
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey.shade400,
                shape: BoxShape.circle,
              ),
            );
          }),
        ),
      ],
    );
  }
}
