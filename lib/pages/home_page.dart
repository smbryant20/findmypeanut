import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _mapController = MapController();
  final sb = Supabase.instance.client;
  final Set<String> _radarNotifiedIds = {};
  // Filters / search
  final Set<String> _statusFilter = {'OPEN', 'MATCHED'};
  final _searchCtrl = TextEditingController();
  String _kindFilter = 'ALL'; // ALL | LOST | FOUND | SIGHTING
  Timer? _debounce;
  bool _useMapSearchBar = true; // use the glass overlay search on the map
  static const _prefsRecentKey = 'recent_queries_v1';
  static const _maxRecent = 5;
  List<String> _recentQueries = [];
  // Data
  List<Map<String, dynamic>> _reports = [];
  List<Map<String, dynamic>> _allReports = [];
  bool _loading = true;
  bool _searching = false;
  // Realtime
  RealtimeChannel? _channel;
  final _zipRe = RegExp(r'^\d{5}(-\d{4})?$'); // 12345 or 12345-6789

  bool _isZip(String s) => _zipRe.hasMatch(s.trim());

  void _kickMapOnce() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        final cam = _mapController.camera; // ok on flutter_map 5/6
        _mapController.move(cam.center, cam.zoom); // no-op "nudge"
      } catch (_) {}
    });
  }

  @override
  void initState() {
    super.initState();

    // Pre-cache your custom pin to avoid first-use jank
    WidgetsBinding.instance.addPostFrameCallback((_) {
      precacheImage(const AssetImage('assets/images/green_pin.png'), context);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initLocation();
    });
    _loadReports();
    _subscribeToChanges();
    _loadRecentQueries();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _channel?.unsubscribe();
    super.dispose();
  }

  Future<void> _loadRecentQueries() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _recentQueries = prefs.getStringList(_prefsRecentKey) ?? [];
    });
  }

  Future<void> _saveRecentQueries() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsRecentKey, _recentQueries);
  }

  void _pushRecent(String q) {
    final query = q.trim();
    if (query.isEmpty) return;
    _recentQueries.removeWhere((e) => e.toLowerCase() == query.toLowerCase());
    _recentQueries.insert(0, query);
    if (_recentQueries.length > _maxRecent) {
      _recentQueries = _recentQueries.take(_maxRecent).toList();
    }
    _saveRecentQueries();
  }

  Future<LatLng?> _geocodePostal(String zip) async {
    try {
      final url = Uri.parse('https://nominatim.openstreetmap.org/search'
          '?format=json&limit=1'
          '&postalcode=${Uri.encodeComponent(zip)}'
          '&countrycodes=us' // keep it US-only; drop if you want intl.
          );
      final res = await http.get(
        url,
        headers: {'User-Agent': 'FindMyPeanut/1.0 (contact: your@email)'},
      );
      if (res.statusCode == 200) {
        final list = (jsonDecode(res.body) as List);
        if (list.isNotEmpty) {
          final m = list.first as Map<String, dynamic>;
          final lat = double.tryParse('${m['lat']}');
          final lon = double.tryParse('${m['lon']}');
          if (lat != null && lon != null) return LatLng(lat, lon);
        }
      }
    } catch (_) {}
    return null;
  }

  void _openReportSheet(Map<String, dynamic> r) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.32, // start height (0–1)
          minChildSize: 0.18,
          maxChildSize: 0.92,
          snap: true,
          snapSizes: const [0.32, 0.6, 0.92],
          builder: (ctx, scroll) {
            final imgs = (r['images'] as List?)?.whereType<String>().toList() ??
                const [];
            final status = (r['status'] ?? 'OPEN') as String;

            Color chipBg;
            Color chipFg;
            switch (status) {
              case 'MATCHED':
                chipBg = Colors.orange.withOpacity(0.15);
                chipFg = Colors.orange;
                break;
              case 'RESOLVED':
                chipBg = Colors.grey.withOpacity(0.20);
                chipFg = Colors.grey;
                break;
              default:
                chipBg = Colors.green.withOpacity(0.15);
                chipFg = Colors.green;
            }

            return Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
                boxShadow: const [
                  BoxShadow(blurRadius: 12, color: Colors.black26)
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 8),

                  //const SizedBox(height: 8),

                  // Content (scrolls)
                  Expanded(
                    child: ListView(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      children: [
                        if (imgs.isNotEmpty) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: CachedNetworkImage(
                              imageUrl: imgs.first,
                              height: 180,
                              fit: BoxFit.cover,
                              placeholder: (_, __) =>
                                  Container(height: 180, color: Colors.black12),
                              errorWidget: (_, __, ___) => Container(
                                  height: 180,
                                  color: Colors.black12,
                                  alignment: Alignment.center,
                                  child: const Icon(Icons.broken_image)),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if ((r['location_details'] ?? '').toString().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text('Near ${r['location_details']}',
                                style: Theme.of(context).textTheme.bodyMedium),
                          ),
                        Text((r['raw_text'] ?? '').toString(),
                            style: Theme.of(context).textTheme.bodyLarge),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: () {
                            Navigator.of(context).pop(); // close sheet
                            context.push('/report/${r['id']}');
                          },
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('View details'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<LatLng?> _geocodeCity(String city) async {
    try {
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/search',
        {
          'q': city,
          'format': 'json',
          'limit': '1',
          'countrycodes': 'us', // drop this if you want international
        },
      );

      final res = await http.get(
        uri,
        headers: {
          'User-Agent': 'FindMyPeanut/1.0 (contact: smbryant20@gmail.com)'
        },
      );

      if (res.statusCode == 200) {
        final list = json.decode(res.body) as List;
        if (list.isNotEmpty) {
          final m = list.first as Map<String, dynamic>;
          final lat = double.tryParse('${m['lat']}');
          final lon = double.tryParse('${m['lon']}');
          if (lat != null && lon != null) return LatLng(lat, lon);
        }
      }
    } catch (_) {}
    return null;
  }

  void _safeMoveMap(LatLng center, double zoom) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        _mapController.move(center, zoom);
      } catch (_) {
        // ignore timing hiccups
      }
    });
  }

  Future<void> _initLocation() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) return;
    if (!await Geolocator.isLocationServiceEnabled()) return;

    try {
      final pos = await Geolocator.getCurrentPosition();

      _safeMoveMap(LatLng(pos.latitude, pos.longitude), 12);
      Future.microtask(() {
        try {
          final c = _mapController.camera.center;
          final z = _mapController.camera.zoom;
          _mapController.move(LatLng(c.latitude + 0.00001, c.longitude), z);
          _mapController.move(c, z);
        } catch (_) {}
      });
    } catch (_) {}
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      final q = _searchCtrl.text.trim();
      if (q.isEmpty || q.length >= 3) {
        _loadReports(showSpinner: false);
      }
    });
  }

  void _onKindChanged(String? v) {
    setState(() => _kindFilter = v ?? 'ALL');
    _loadReports();
  }

  void _subscribeToChanges() {
    _channel = sb.channel('public:reports')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'reports',
        callback: (payload) {
          final id = payload.newRecord['id']?.toString();
          if (id != null) _loadOne(id);
        },
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'reports',
        callback: (payload) {
          final id = payload.newRecord['id']?.toString();
          if (id != null) _loadOne(id);
        },
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.delete,
        schema: 'public',
        table: 'reports',
        callback: (payload) {
          final id = payload.oldRecord['id']?.toString();
          if (id != null) _removeById(id);
        },
      )
      ..subscribe();
  }

  Future<void> _loadOne(String id) async {
    try {
      final row = await sb
          .from('reports_public')
          .select(
              'id, kind, raw_text, location_details, city, state, country, created_at, images, lat, lng, status')
          .eq('id', id)
          .maybeSingle();

      if (!mounted) return;

      if (row == null || !_statusFilter.contains((row['status'] ?? 'OPEN'))) {
        _removeById(id);
        return;
      }

      _mergePublicRow(Map<String, dynamic>.from(row));
    } catch (_) {}
  }

  void _onSubmitSearch() {
    final q = _searchCtrl.text.trim();
    _pushRecent(q);
    _loadReports(showSpinner: false);
  }

  void _removeById(String id) {
    final iAll = _allReports.indexWhere((r) => r['id'] == id);
    if (iAll >= 0) _allReports.removeAt(iAll);

    final iVis = _reports.indexWhere((r) => r['id'] == id);
    if (iVis >= 0) {
      setState(() => _reports.removeAt(iVis));
    }
  }

  Future<void> _loadReports({bool showSpinner = true}) async {
    final qText = _searchCtrl.text.trim();

    if (_statusFilter.isEmpty) {
      setState(() {
        _allReports = [];
        _reports = [];
        _loading = false;
        _searching = false;
      });

      if (_reports.isEmpty) {
        LatLng? loc;

        if (_isZip(qText)) {
          loc = await _geocodePostal(qText);
        } else if (qText.isNotEmpty && qText.length >= 3) {
          loc = await _geocodeCity(qText);
        }

        if (loc != null) {
          _safeMoveMap(loc, 12.0);
        }
      }
      return;
    }

    if (showSpinner) setState(() => _loading = true);
    if (!showSpinner) setState(() => _searching = true);

    try {
      final statuses = _statusFilter.toList();
      final quoted = statuses.map((s) => '"$s"').join(',');

      final likeRaw = '%${qText.replaceAll(',', ' ').replaceAll('%', r'\%')}%';
      final likeEnc = Uri.encodeComponent(likeRaw);

      var query = Supabase.instance.client
          .from('reports_public')
          .select(
            'id, kind, raw_text, location_details, city, state, country, '
            'created_at, images, lat, lng, status',
          )
          .filter('status', 'in', '($quoted)');

      if (_kindFilter != 'ALL') {
        query = query.eq('kind', _kindFilter);
      }

      if (qText.isNotEmpty) {
        query = query.ilike('city', likeRaw).or(
              [
                'state.ilike.$likeEnc',
                'country.ilike.$likeEnc',
                'raw_text.ilike.$likeEnc',
                'location_details.ilike.$likeEnc',
              ].join(','),
            );
      }

      final rows = await query.order('created_at', ascending: false).limit(100);

      if (!mounted) return;
      setState(() {
        _allReports = (rows as List).cast<Map<String, dynamic>>();
        _reports = _allReports;
        _loading = false;
        _searching = false;
      });

      if (_reports.isNotEmpty) {
        final first = _reports.firstWhere(
          (r) => r['lat'] != null && r['lng'] != null,
          orElse: () => {},
        );
        if (first.isNotEmpty) {
          _safeMoveMap(
            LatLng((first['lat'] as num).toDouble(),
                (first['lng'] as num).toDouble()),
            13.0,
          );
        }
      } else {
        LatLng? loc;
        if (_isZip(qText)) {
          loc = await _geocodePostal(qText);
        } else if (qText.isNotEmpty && qText.length >= 3) {
          loc = await _geocodeCity(qText);
        }
        if (loc != null) {
          _safeMoveMap(loc, 11.0);
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _searching = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load reports: $e')),
      );
    }
  }

  void _showRecentSearchesSheet() {
    if (_recentQueries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No recent searches yet')),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  leading: Icon(Icons.history),
                  title: Text('Recent searches',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _recentQueries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final q = _recentQueries[i];
                      return ListTile(
                        leading: const Icon(Icons.search),
                        title: Text(q),
                        trailing: IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Remove',
                          onPressed: () {
                            setState(() {
                              _recentQueries.removeAt(i);
                            });
                            _saveRecentQueries();
                            Navigator.of(ctx).pop();
                            _showRecentSearchesSheet(); // reopen updated
                          },
                        ),
                        onTap: () {
                          _searchCtrl.text = q;
                          Navigator.of(ctx).pop();
                          _onSubmitSearch();
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Clear all'),
                    onPressed: () {
                      setState(() {
                        _recentQueries.clear();
                      });
                      _saveRecentQueries();
                      Navigator.of(ctx).pop();
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showFiltersSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              top: 8,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ListTile(
                    leading: Icon(Icons.tune),
                    title: Text('Filters',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(height: 8),
                  // Re-use your existing filter UI:
                  _filterBar(),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.check),
                      label: const Text('Apply'),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _loadReports(); // refresh with any updated filters
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _mergePublicRow(Map<String, dynamic> row) {
    final id = row['id'];

    // update master
    final iAll = _allReports.indexWhere((r) => r['id'] == id);
    if (iAll >= 0) {
      _allReports[iAll] = row;
    } else {
      _allReports.insert(0, row);
    }

    // evaluate filters
    final matchesStatus = _statusFilter.contains(row['status'] ?? 'OPEN');
    final matchesKind = (_kindFilter == 'ALL') || (row['kind'] == _kindFilter);

    bool matchesSearch = true;
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      bool has(String? s) => (s ?? '').toLowerCase().contains(q);
      matchesSearch = has(row['city']) ||
          has(row['state']) ||
          has(row['country']) ||
          has(row['raw_text']) ||
          has(row['location_details']);
    }

    final iVis = _reports.indexWhere((r) => r['id'] == id);

    if (!(matchesStatus && matchesKind && matchesSearch)) {
      if (iVis >= 0) {
        setState(() => _reports.removeAt(iVis));
      }
      return;
    }

    setState(() {
      if (iVis >= 0) {
        _reports[iVis] = row;
      } else {
        _reports.insert(0, row);
      }
      _reports.sort((a, b) => DateTime.parse(b['created_at'])
          .compareTo(DateTime.parse(a['created_at'])));
    });
  }

  Widget _statusChips() {
    const statuses = ['OPEN', 'MATCHED', 'RESOLVED'];
    return Wrap(
      spacing: 8,
      children: statuses.map((s) {
        final selected = _statusFilter.contains(s);
        return FilterChip(
          label: Text(s),
          selected: selected,
          onSelected: (val) {
            setState(() {
              if (val) {
                _statusFilter.add(s);
              } else {
                _statusFilter.remove(s);
              }
            });
            _loadReports();
          },
        );
      }).toList(),
    );
  }

  Widget _filterBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _statusChips(),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 170,
              child: DropdownButtonFormField<String>(
                value: _kindFilter,
                decoration: const InputDecoration(labelText: 'Kind'),
                items: const [
                  DropdownMenuItem(value: 'ALL', child: Text('All')),
                  DropdownMenuItem(value: 'LOST', child: Text('Lost')),
                  DropdownMenuItem(value: 'FOUND', child: Text('Found')),
                  DropdownMenuItem(value: 'SIGHTING', child: Text('Sighting')),
                ],
                onChanged: _onKindChanged,
              ),
            ),
            const SizedBox(width: 12),
            if (!_useMapSearchBar)
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _loadReports(showSpinner: false),
                  decoration: InputDecoration(
                    labelText: 'Search city/state/country/notes',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: (_searchCtrl.text.isEmpty)
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchCtrl.clear();
                              _loadReports();
                              setState(() {}); // hide clear button
                            },
                          ),
                  ),
                  onChanged: _onSearchChanged,
                ),
              )
            else
              const SizedBox.shrink(),
          ],
        ),
        if (_searching)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 900;

    return Scaffold(
      appBar: AppBar(
        title: const Text('FindMyPeanut'),
        actions: [
          IconButton(
            tooltip: 'Alerts',
            icon: const Icon(Icons.notifications),
            onPressed: () => context.push('/alerts'),
          ),
          IconButton(
            tooltip: 'Profile',
            icon: const Icon(Icons.person_outline),
            onPressed: () => context.push('/profile'),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'create') context.push('/create');
              if (value == 'admin') context.push('/admin');
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'create',
                child: ListTile(
                  leading: Icon(Icons.add_circle_outline),
                  title: Text('Create report'),
                ),
              ),
              PopupMenuItem(
                value: 'admin',
                child: ListTile(
                  leading: Icon(Icons.admin_panel_settings),
                  title: Text('Admin'),
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/create'),
        label: const Text('Report'),
        icon: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadReports,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: isWide
                    ? SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            //_filterBar(),
                            const SizedBox(height: 12),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: SizedBox(
                                    height: 420,
                                    child: Stack(
                                      children: [
                                        _MapWidget(
                                          mapController: _mapController,
                                          reports: _reports,
                                          onMarkerTap: _openReportSheet,
                                        ),
                                        Positioned(
                                          top: 12,
                                          left: 12,
                                          right: 12,
                                          child: SafeArea(
                                            child: Center(
                                              child: ConstrainedBox(
                                                constraints:
                                                    const BoxConstraints(
                                                        maxWidth: 800),
                                                child: _MapSearchBar(
                                                  controller: _searchCtrl,
                                                  onChanged: _onSearchChanged,
                                                  onSubmitted: _onSubmitSearch,
                                                  onClear: () {
                                                    _searchCtrl.clear();
                                                    _loadReports(
                                                        showSpinner: false);
                                                  },
                                                  onMyLocation: () async {
                                                    try {
                                                      final pos = await Geolocator
                                                          .getCurrentPosition();
                                                      _mapController.move(
                                                          LatLng(pos.latitude,
                                                              pos.longitude),
                                                          12);
                                                    } catch (_) {}
                                                  },
                                                  onShowHistory:
                                                      _showRecentSearchesSheet, // add
                                                  onShowFilters:
                                                      _showFiltersSheet, // add
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  flex: 2,
                                  child: _ListWidget(reports: _reports),
                                ),
                              ],
                            ),
                          ],
                        ),
                      )
                    : ListView(
                        children: [
                          //_filterBar(),
                          // in the mobile (isWide == false) branch:
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 420,
                            child: Stack(
                              children: [
                                _MapWidget(
                                  mapController: _mapController,
                                  reports: _reports,
                                  onMarkerTap: _openReportSheet,
                                ),
                                Positioned(
                                  top: 12,
                                  left: 12,
                                  right: 12,
                                  child: SafeArea(
                                    child: Center(
                                      child: ConstrainedBox(
                                        constraints:
                                            const BoxConstraints(maxWidth: 760),
                                        child: _MapSearchBar(
                                          controller: _searchCtrl,
                                          onChanged: _onSearchChanged,
                                          onSubmitted: _onSubmitSearch,
                                          onClear: () {
                                            _searchCtrl.clear();
                                            _loadReports(showSpinner: false);
                                          },
                                          onMyLocation: () async {
                                            try {
                                              final pos = await Geolocator
                                                  .getCurrentPosition();
                                              _mapController.move(
                                                  LatLng(pos.latitude,
                                                      pos.longitude),
                                                  12);
                                            } catch (_) {}
                                          },
                                          onShowHistory:
                                              _showRecentSearchesSheet, // NEW
                                          onShowFilters:
                                              _showFiltersSheet, // NEW
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),

                          _ListWidget(reports: _reports),
                        ],
                      ),
              ),
            ),
    );
  }
}

class PulseGlow extends StatefulWidget {
  const PulseGlow(
      {super.key, this.size = 40, this.color = const Color(0x4400E676)});
  final double size;
  final Color color;

  @override
  State<PulseGlow> createState() => _PulseGlowState();
}

class _PulseGlowState extends State<PulseGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: Tween(begin: 0.9, end: 1.3)
          .animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

class _MapWidget extends StatelessWidget {
  _MapWidget({
    Key? key,
    required this.reports,
    required this.mapController,
    required this.onMarkerTap,
  }) : super(key: key);

  final List<Map<String, dynamic>> reports;
  final MapController mapController;
  //final PopupController _popupController = PopupController();
  final void Function(Map<String, dynamic> report) onMarkerTap;
  Color _markerColor(String status) {
    switch (status) {
      case 'MATCHED':
        return Colors.orange;
      case 'RESOLVED':
        return Colors.grey;
      default:
        return Colors.green;
    }
  }

  Widget _markerByStatus(String status) {
    switch (status) {
      case 'MATCHED':
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.96, end: 1.06),
          duration: const Duration(milliseconds: 900),
          curve: Curves.easeInOut,
          builder: (_, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: const Icon(Icons.location_on, color: Colors.orange, size: 40),
        );

      case 'RESOLVED':
        return const Icon(Icons.location_on, color: Colors.grey, size: 36);

      default: // OPEN
        return Stack(
          alignment: Alignment.center,
          children: [
            // soft pulsing glow behind the pin
            /* TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.9, end: 1.3),
              duration: const Duration(seconds: 2),
              curve: Curves.easeInOut,
              builder: (_, scale, __) => Transform.scale(
                scale: scale,
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: Colors.greenAccent.withOpacity(0.28),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),*/

            // your custom pin image
            Image.asset(
              'assets/images/green_marker.png',
              width: 38,
              height: 38,
              fit: BoxFit.contain,
            ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final markers = <Marker>[];

    for (final r
        in reports.where((r) => r['lat'] != null && r['lng'] != null)) {
      final status = (r['status'] ?? 'OPEN') as String;
      final pt = LatLng(
        (r['lat'] as num).toDouble(),
        (r['lng'] as num).toDouble(),
      );

      markers.add(
        Marker(
          point: pt,
          width: 60,
          height: 60,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              final currentZoom = MapCamera.maybeOf(context)?.zoom ?? 13.0;
              mapController.move(pt, currentZoom < 12 ? 12 : currentZoom);
              onMarkerTap(r);
            },
            child: Semantics(
              label:
                  '${(r['kind'] ?? '').toString()} in ${(r['city'] ?? '').toString()}, status $status',
              button: true,
              child: _markerByStatus(status),
            ),
          ),
        ),
      );
    }

    return FlutterMap(
      key: const ValueKey('main-map'),
      mapController: mapController,
      options: MapOptions(
        initialCenter: const LatLng(42.7, -73.1),
        initialZoom: 12,
        keepAlive: true,
        onMapReady: () async {
          await Future.delayed(const Duration(milliseconds: 120));
          try {
            final cam = mapController.camera;
            final c = cam.center;
            final z = cam.zoom;
            mapController.move(
                LatLng(c.latitude + 0.00008, c.longitude + 0.00008), z);
            await Future.delayed(const Duration(milliseconds: 60));
            mapController.move(c, z);
          } catch (e) {
            debugPrint('onMapReady nudge failed: $e');
          }
        },
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.findmypeanut.app',
          tileProvider: NetworkTileProvider(),
        ),
        MarkerLayer(markers: markers),
      ],
    );
  }

  List<Marker> _buildMarkers() {
    return reports.where((r) => r['lat'] != null && r['lng'] != null).map((r) {
      final status = (r['status'] ?? 'OPEN') as String;
      final pt =
          LatLng((r['lat'] as num).toDouble(), (r['lng'] as num).toDouble());
      return Marker(
        key: ValueKey(r['id']),
        point: pt,
        width: 60,
        height: 60,
        child: Semantics(
          label:
              '${(r['kind'] ?? '').toString()} in ${(r['city'] ?? '').toString()}, status $status',
          button: true,
          child: _markerByStatus(status),
        ),
      );
    }).toList();
  }
}

class _ListWidget extends StatelessWidget {
  const _ListWidget({required this.reports});
  final List<Map<String, dynamic>> reports;

  Widget _thumb(Map<String, dynamic> r) {
    final imgs = (r['images'] as List?)?.cast<String>() ?? const [];
    if (imgs.isEmpty) return const Icon(Icons.pets, size: 36);

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedNetworkImage(
        imageUrl: imgs.first,
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        memCacheWidth: 300, // lightweight cached thumb
        placeholder: (_, __) => Container(color: Colors.black12),
        errorWidget: (_, __, ___) => const Icon(Icons.broken_image),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: reports.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (c, i) {
        final r = reports[i];
        final status = (r['status'] ?? 'OPEN') as String;

        Color bg, fg;
        switch (status) {
          case 'MATCHED':
            bg = Colors.orange.withOpacity(0.15);
            fg = Colors.orange;
            break;
          case 'RESOLVED':
            bg = Colors.grey.withOpacity(0.2);
            fg = Colors.grey;
            break;
          default:
            bg = Colors.green.withOpacity(0.15);
            fg = Colors.green;
        }

        return Card(
          child: ListTile(
            leading: _thumb(r),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    '${(r['kind'] ?? '').toString().toUpperCase()} · ${r['city'] ?? ''}',
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: bg, borderRadius: BorderRadius.circular(8)),
                  child: Text(
                    status,
                    style: TextStyle(color: fg, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            subtitle: Text(
              ((r['location_details'] ?? '').toString().isNotEmpty)
                  ? 'Near ${r['location_details']} — ${(r['raw_text'] ?? '').toString()}'
                  : (r['raw_text'] ?? '').toString(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => context.push('/report/${r['id']}'),
          ),
        );
      },
    );
  }
}

class _MapSearchBar extends StatelessWidget {
  const _MapSearchBar({
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    this.hint = 'Search city, state, notes, or ZIP',
    this.onClear,
    this.onMyLocation,
    this.onShowHistory,
    this.onShowFilters,
    super.key,
  });

  final TextEditingController controller;
  final void Function(String) onChanged;
  final VoidCallback onSubmitted;
  final String hint;
  final VoidCallback? onClear;
  final VoidCallback? onMyLocation;
  final VoidCallback? onShowHistory;
  final VoidCallback? onShowFilters;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 3,
      color: theme.colorScheme.surface,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(28),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: theme.dividerColor.withOpacity(0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.search, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                decoration: InputDecoration(
                  hintText: hint,
                  border: InputBorder.none,
                  isDense: true,
                ),
                textInputAction: TextInputAction.search,
                onChanged: onChanged,
                onSubmitted: (_) => onSubmitted(),
              ),
            ),

            // React to text changes for trailing controls
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (_, value, __) {
                final hasText = value.text.isNotEmpty;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasText && onClear != null)
                      IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: onClear,
                        visualDensity: VisualDensity.compact,
                      ),
                    if (onShowHistory != null)
                      IconButton(
                        tooltip: 'Recent',
                        icon: const Icon(Icons.history, size: 20),
                        onPressed: onShowHistory,
                        visualDensity: VisualDensity.compact,
                      ),
                    if (onShowFilters != null)
                      IconButton(
                        tooltip: 'Filters',
                        icon: const Icon(Icons.tune, size: 20),
                        onPressed: onShowFilters,
                        visualDensity: VisualDensity.compact,
                      ),
                    if (onMyLocation != null)
                      IconButton(
                        tooltip: 'Use my location',
                        icon: const Icon(Icons.my_location, size: 20),
                        onPressed: onMyLocation,
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}






/*
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'dart:math' as math;
import 'package:flutter/scheduler.dart';
import 'package:latlong2/latlong.dart' show Distance, LengthUnit;

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _mapController = MapController();
  final sb = Supabase.instance.client;
  final Set<String> _radarNotifiedIds = {};
  // Filters / search
  final Set<String> _statusFilter = {'OPEN', 'MATCHED'};
  final _searchCtrl = TextEditingController();
  String _kindFilter = 'ALL'; // ALL | LOST | FOUND | SIGHTING
  Timer? _debounce;

  // Data
  List<Map<String, dynamic>> _reports = [];
  List<Map<String, dynamic>> _allReports = [];
  bool _loading = true;
  bool _searching = false;
  // Realtime
  RealtimeChannel? _channel;
  final _zipRe = RegExp(r'^\d{5}(-\d{4})?$'); // 12345 or 12345-6789

  bool _isZip(String s) => _zipRe.hasMatch(s.trim());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initLocation(); // ensures the map is built first
    });
    _loadReports();
    _subscribeToChanges();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _channel?.unsubscribe();
    super.dispose();
  }

  Future<LatLng?> _geocodePostal(String zip) async {
    try {
      final url = Uri.parse('https://nominatim.openstreetmap.org/search'
          '?format=json&limit=1'
          '&postalcode=${Uri.encodeComponent(zip)}'
          '&countrycodes=us' // keep it US-only; drop if you want intl.
          );
      final res = await http.get(
        url,
        headers: {'User-Agent': 'FindMyPeanut/1.0 (contact: your@email)'},
      );
      if (res.statusCode == 200) {
        final list = (jsonDecode(res.body) as List);
        if (list.isNotEmpty) {
          final m = list.first as Map<String, dynamic>;
          final lat = double.tryParse('${m['lat']}');
          final lon = double.tryParse('${m['lon']}');
          if (lat != null && lon != null) return LatLng(lat, lon);
        }
      }
    } catch (_) {}
    return null;
  }

  void _openReportSheet(Map<String, dynamic> r) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.32, // start height (0–1)
          minChildSize: 0.18,
          maxChildSize: 0.92,
          snap: true,
          snapSizes: const [0.32, 0.6, 0.92],
          builder: (ctx, scroll) {
            final imgs = (r['images'] as List?)?.whereType<String>().toList() ??
                const [];
            final status = (r['status'] ?? 'OPEN') as String;

            Color chipBg;
            Color chipFg;
            switch (status) {
              case 'MATCHED':
                chipBg = Colors.orange.withOpacity(0.15);
                chipFg = Colors.orange;
                break;
              case 'RESOLVED':
                chipBg = Colors.grey.withOpacity(0.20);
                chipFg = Colors.grey;
                break;
              default:
                chipBg = Colors.green.withOpacity(0.15);
                chipFg = Colors.green;
            }

            return Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
                boxShadow: const [
                  BoxShadow(blurRadius: 12, color: Colors.black26)
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 8),
                  // Header row
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${(r['kind'] ?? '').toString().toUpperCase()} · ${r['city'] ?? ''}',
                            style: Theme.of(context).textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                              color: chipBg,
                              borderRadius: BorderRadius.circular(8)),
                          child: Text(status,
                              style: TextStyle(
                                  color: chipFg, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Content (scrolls)
                  Expanded(
                    child: ListView(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      children: [
                        if (imgs.isNotEmpty) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: CachedNetworkImage(
                              imageUrl: imgs.first,
                              height: 180,
                              fit: BoxFit.cover,
                              placeholder: (_, __) =>
                                  Container(height: 180, color: Colors.black12),
                              errorWidget: (_, __, ___) => Container(
                                  height: 180,
                                  color: Colors.black12,
                                  alignment: Alignment.center,
                                  child: const Icon(Icons.broken_image)),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if ((r['location_details'] ?? '').toString().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text('Near ${r['location_details']}',
                                style: Theme.of(context).textTheme.bodyMedium),
                          ),
                        Text((r['raw_text'] ?? '').toString(),
                            style: Theme.of(context).textTheme.bodyLarge),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: () {
                            Navigator.of(context).pop(); // close sheet
                            context.push('/report/${r['id']}');
                          },
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('View details'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<LatLng?> _geocodeCity(String city) async {
    try {
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=$city&format=json&limit=1',
      );
      final res =
          await http.get(url, headers: {'User-Agent': 'FindMyPeanutApp/1.0'});
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data.isNotEmpty) {
          final lat = double.parse(data[0]['lat']);
          final lon = double.parse(data[0]['lon']);
          return LatLng(lat, lon);
        }
      }
    } catch (_) {}
    return null;
  }

  void _safeMoveMap(LatLng center, double zoom) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        _mapController.move(center, zoom);
      } catch (_) {
        // ignore timing hiccups
      }
    });
  }

  Future<void> _initLocation() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) return;
    if (!await Geolocator.isLocationServiceEnabled()) return;

    try {
      final pos = await Geolocator.getCurrentPosition();

      _safeMoveMap(LatLng(pos.latitude, pos.longitude), 12);
    } catch (_) {}
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      final q = _searchCtrl.text.trim();
      if (q.isEmpty || q.length >= 3) {
        _loadReports(showSpinner: false);
      }
    });
  }

  void _onKindChanged(String? v) {
    setState(() => _kindFilter = v ?? 'ALL');
    _loadReports();
  }

  void _subscribeToChanges() {
    _channel = sb.channel('public:reports')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'reports',
        callback: (payload) {
          final id = payload.newRecord['id']?.toString();
          if (id != null) _loadOne(id);
        },
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'reports',
        callback: (payload) {
          final id = payload.newRecord['id']?.toString();
          if (id != null) _loadOne(id);
        },
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.delete,
        schema: 'public',
        table: 'reports',
        callback: (payload) {
          final id = payload.oldRecord['id']?.toString();
          if (id != null) _removeById(id);
        },
      )
      ..subscribe();
  }

  Future<void> _loadOne(String id) async {
    try {
      final row = await sb
          .from('reports_public')
          .select(
              'id, kind, raw_text, location_details, city, state, country, created_at, images, lat, lng, status')
          .eq('id', id)
          .maybeSingle();

      if (!mounted) return;

      // If it no longer matches current filter, remove it
      if (row == null || !_statusFilter.contains((row['status'] ?? 'OPEN'))) {
        _removeById(id);
        return;
      }

      _mergePublicRow(Map<String, dynamic>.from(row));
    } catch (_) {
      // ignore; next full load will fix
    }
  }

  void _removeById(String id) {
    final iAll = _allReports.indexWhere((r) => r['id'] == id);
    if (iAll >= 0) _allReports.removeAt(iAll);

    final iVis = _reports.indexWhere((r) => r['id'] == id);
    if (iVis >= 0) {
      setState(() => _reports.removeAt(iVis));
    }
  }

  Future<void> _loadReports({bool showSpinner = true}) async {
    if (_statusFilter.isEmpty) {
      setState(() {
        _allReports = [];
        _reports = [];
        _loading = false;
        _searching = false;
      });
      return;
    }

    if (showSpinner) setState(() => _loading = true);
    if (!showSpinner) setState(() => _searching = true);

    try {
      final statuses = _statusFilter.toList(); // e.g. ['OPEN','MATCHED']
      final quoted =
          statuses.map((s) => '"$s"').join(','); // -> "OPEN","MATCHED"
      final qText = _searchCtrl.text.trim();

      final likeRaw = '%${qText.replaceAll(',', ' ').replaceAll('%', r'\%')}%';
      final likeEnc = Uri.encodeComponent(likeRaw);

      // ✅ define the query builder first
      var query = Supabase.instance.client
          .from('reports_public')
          .select(
            'id, kind, raw_text, location_details, city, state, country, '
            'created_at, images, lat, lng, status',
          )
          .filter('status', 'in', '($quoted)');

      // kind filter
      if (_kindFilter != 'ALL') {
        query = query.eq('kind', _kindFilter);
      }

      // text search
      if (qText.isNotEmpty) {
        query = query.ilike('city', likeRaw).or(
              [
                'state.ilike.$likeEnc',
                'country.ilike.$likeEnc',
                'raw_text.ilike.$likeEnc',
                'location_details.ilike.$likeEnc',
              ].join(','),
            );
      }

      // ✅ execute query
      final rows = await query.order('created_at', ascending: false).limit(100);

      if (!mounted) return;
      setState(() {
        _allReports = (rows as List).cast<Map<String, dynamic>>();
        _reports = _allReports;
        _loading = false;
        _searching = false;
      });

      // Auto-center on reports if any
      if (_reports.isNotEmpty) {
        final first = _reports.firstWhere(
          (r) => r['lat'] != null && r['lng'] != null,
          orElse: () => {},
        );
        if (first.isNotEmpty) {
          _safeMoveMap(
            LatLng((first['lat'] as num).toDouble(),
                (first['lng'] as num).toDouble()),
            13.0,
          );
        }
      } else {
        // If no results and user typed a ZIP, center on that ZIP anyway
        if (_isZip(qText)) {
          final loc = await _geocodePostal(qText);
          if (loc != null) {
            _mapController.move(loc, 12.0);
          }
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _searching = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load reports: $e')),
      );
    }
  }

  void _mergePublicRow(Map<String, dynamic> row) {
    final id = row['id'];

    // update master
    final iAll = _allReports.indexWhere((r) => r['id'] == id);
    if (iAll >= 0) {
      _allReports[iAll] = row;
    } else {
      _allReports.insert(0, row);
    }

    // evaluate filters
    final matchesStatus = _statusFilter.contains(row['status'] ?? 'OPEN');
    final matchesKind = (_kindFilter == 'ALL') || (row['kind'] == _kindFilter);

    bool matchesSearch = true;
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      bool has(String? s) => (s ?? '').toLowerCase().contains(q);
      matchesSearch = has(row['city']) ||
          has(row['state']) ||
          has(row['country']) ||
          has(row['raw_text']) ||
          has(row['location_details']);
    }

    final iVis = _reports.indexWhere((r) => r['id'] == id);

    if (!(matchesStatus && matchesKind && matchesSearch)) {
      if (iVis >= 0) {
        setState(() => _reports.removeAt(iVis));
      }
      return;
    }

    setState(() {
      if (iVis >= 0) {
        _reports[iVis] = row;
      } else {
        _reports.insert(0, row);
      }
      _reports.sort((a, b) => DateTime.parse(b['created_at'])
          .compareTo(DateTime.parse(a['created_at'])));
    });
  }

  Widget _statusChips() {
    const statuses = ['OPEN', 'MATCHED', 'RESOLVED'];
    return Wrap(
      spacing: 8,
      children: statuses.map((s) {
        final selected = _statusFilter.contains(s);
        return FilterChip(
          label: Text(s),
          selected: selected,
          onSelected: (val) {
            setState(() {
              if (val) {
                _statusFilter.add(s);
              } else {
                _statusFilter.remove(s);
              }
            });
            _loadReports();
          },
        );
      }).toList(),
    );
  }

  Widget _filterBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _statusChips(),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 170,
              child: DropdownButtonFormField<String>(
                value: _kindFilter,
                decoration: const InputDecoration(labelText: 'Kind'),
                items: const [
                  DropdownMenuItem(value: 'ALL', child: Text('All')),
                  DropdownMenuItem(value: 'LOST', child: Text('Lost')),
                  DropdownMenuItem(value: 'FOUND', child: Text('Found')),
                  DropdownMenuItem(value: 'SIGHTING', child: Text('Sighting')),
                ],
                onChanged: _onKindChanged,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _loadReports(showSpinner: false),
                decoration: InputDecoration(
                  labelText: 'Search city/state/country/notes',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: (_searchCtrl.text.isEmpty)
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchCtrl.clear();
                            _loadReports();
                            setState(() {}); // hide clear button
                          },
                        ),
                ),
                onChanged: _onSearchChanged,
              ),
            ),
          ],
        ),
        if (_searching)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 900;

    return Scaffold(
      appBar: AppBar(
        title: const Text('FindMyPeanut'),
        actions: [
          IconButton(
            tooltip: 'Alerts',
            icon: const Icon(Icons.notifications),
            onPressed: () => context.push('/alerts'),
          ),
          IconButton(
            tooltip: 'Profile',
            icon: const Icon(Icons.person_outline),
            onPressed: () => context.push('/profile'),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'create') context.push('/create');
              if (value == 'admin') context.push('/admin');
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'create',
                child: ListTile(
                  leading: Icon(Icons.add_circle_outline),
                  title: Text('Create report'),
                ),
              ),
              PopupMenuItem(
                value: 'admin',
                child: ListTile(
                  leading: Icon(Icons.admin_panel_settings),
                  title: Text('Admin'),
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/create'),
        label: const Text('Report'),
        icon: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadReports,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: isWide
                    ? SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _filterBar(), // <-- removed stray comma
                            const SizedBox(height: 12),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: SizedBox(
                                    height: 420,
                                    child: Stack(
                                      children: [
                                        _MapWidget(
                                          mapController: _mapController,
                                          reports: _reports,
                                          onMarkerTap: _openReportSheet,
                                        ),
                                        Positioned(
                                          right: 12,
                                          bottom: 12,
                                          child: Material(
                                            color: Colors.transparent,
                                            elevation: 0,
                                            child: Container(
                                              decoration: BoxDecoration(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .surface
                                                    .withOpacity(0.4),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                                boxShadow: const [
                                                  BoxShadow(
                                                      blurRadius: 6,
                                                      color: Colors.black26)
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  flex: 2,
                                  child: _ListWidget(reports: _reports),
                                ),
                              ],
                            ),
                          ],
                        ),
                      )
                    : ListView(
                        children: [
                          _filterBar(),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 420,
                            child: Stack(
                              children: [
                                _MapWidget(
                                  mapController: _mapController,
                                  reports: _reports,
                                  onMarkerTap: _openReportSheet,
                                ),
                                Positioned(
                                  right: 12,
                                  bottom: 12,
                                  child: Material(
                                    color: Colors.transparent,
                                    elevation: 0,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .surface
                                            .withOpacity(0.4),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                        boxShadow: const [
                                          BoxShadow(
                                              blurRadius: 6,
                                              color: Colors.black26)
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          _ListWidget(reports: _reports),
                        ],
                      ),
              ),
            ),
    );
  }
}

class _MapWidget extends StatelessWidget {
  _MapWidget({
    Key? key,
    required this.reports,
    required this.mapController,
    required this.onMarkerTap,
  }) : super(key: key);

  final List<Map<String, dynamic>> reports;
  final MapController mapController;
  //final PopupController _popupController = PopupController();
  final void Function(Map<String, dynamic> report) onMarkerTap;
  Color _markerColor(String status) {
    switch (status) {
      case 'MATCHED':
        return Colors.orange;
      case 'RESOLVED':
        return Colors.grey;
      default:
        return Colors.green;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Build markers and keep a lookup so we can find the report for a given marker
    final markers = <Marker>[];
    final markerData = <Marker, Map<String, dynamic>>{};

    for (final r
        in reports.where((r) => r['lat'] != null && r['lng'] != null)) {
      final status = (r['status'] ?? 'OPEN') as String;
      final pt = LatLng(
        (r['lat'] as num).toDouble(),
        (r['lng'] as num).toDouble(),
      );
      // width: 40,
      // height: 40,
      //child: Icon(Icons.place, color: _markerColor(status), size: 36),
      //);
      markers.add(
        Marker(
          point: pt,
          width: 40,
          height: 40,
          child: GestureDetector(
            onTap: () {
              final currentZoom = MapCamera.maybeOf(context)?.zoom ?? 13.0;

              mapController.move(pt, currentZoom < 12 ? 12 : currentZoom);

              onMarkerTap(r); // <-- opens your bottom sheet
            },
            child: Icon(Icons.place, color: _markerColor(status), size: 36),
          ),
        ),
      );
    }

    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialCenter: const LatLng(42.7, -73.1),
        initialZoom: 12,
        // onTap: (_, __) => _popupController.hideAllPopups(),
      ),
      children: [
        TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'),
        MarkerLayer(markers: markers),
        // 👇 Popups on marker tap
      ],
    );
  }

  List<Marker> _buildMarkers() {
    return reports.where((r) => r['lat'] != null && r['lng'] != null).map((r) {
      return Marker(
        key: ValueKey<Map<String, dynamic>>(r),
        point: LatLng(
          (r['lat'] as num).toDouble(),
          (r['lng'] as num).toDouble(),
        ),
        width: 40,
        height: 40,
        child: Icon(
          Icons.place,
          color: _markerColor((r['status'] ?? 'OPEN') as String),
          size: 36,
        ),
      );
    }).toList();
  }
}

class _ListWidget extends StatelessWidget {
  const _ListWidget({required this.reports});
  final List<Map<String, dynamic>> reports;

  Widget _thumb(Map<String, dynamic> r) {
    final imgs = (r['images'] as List?)?.cast<String>() ?? const [];
    if (imgs.isEmpty) return const Icon(Icons.pets, size: 36);

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedNetworkImage(
        imageUrl: imgs.first,
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        memCacheWidth: 300, // lightweight cached thumb
        placeholder: (_, __) => Container(color: Colors.black12),
        errorWidget: (_, __, ___) => const Icon(Icons.broken_image),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: reports.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (c, i) {
        final r = reports[i];
        final status = (r['status'] ?? 'OPEN') as String;

        Color bg, fg;
        switch (status) {
          case 'MATCHED':
            bg = Colors.orange.withOpacity(0.15);
            fg = Colors.orange;
            break;
          case 'RESOLVED':
            bg = Colors.grey.withOpacity(0.2);
            fg = Colors.grey;
            break;
          default:
            bg = Colors.green.withOpacity(0.15);
            fg = Colors.green;
        }

        return Card(
          child: ListTile(
            leading: _thumb(r),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    '${(r['kind'] ?? '').toString().toUpperCase()} · ${r['city'] ?? ''}',
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: bg, borderRadius: BorderRadius.circular(8)),
                  child: Text(
                    status,
                    style: TextStyle(color: fg, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            subtitle: Text(
              ((r['location_details'] ?? '').toString().isNotEmpty)
                  ? 'Near ${r['location_details']} — ${(r['raw_text'] ?? '').toString()}'
                  : (r['raw_text'] ?? '').toString(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => context.push('/report/${r['id']}'),
          ),
        );
      },
    );
  }
}


*/