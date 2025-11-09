import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;

// ---- Countries (short list) ----
const _countries = <DropdownMenuItem<String>>[
  DropdownMenuItem(value: 'US', child: Text('United States')),
  DropdownMenuItem(value: 'CA', child: Text('Canada')),
  DropdownMenuItem(value: 'GB', child: Text('United Kingdom')),
  DropdownMenuItem(value: 'AU', child: Text('Australia')),
  DropdownMenuItem(value: 'IE', child: Text('Ireland')),
  DropdownMenuItem(value: 'NZ', child: Text('New Zealand')),
];

// ---- US states (two-letter) ----
const _usStates = <DropdownMenuItem<String>>[
  DropdownMenuItem(value: 'AL', child: Text('AL')),
  DropdownMenuItem(value: 'AK', child: Text('AK')),
  DropdownMenuItem(value: 'AZ', child: Text('AZ')),
  DropdownMenuItem(value: 'AR', child: Text('AR')),
  DropdownMenuItem(value: 'CA', child: Text('CA')),
  DropdownMenuItem(value: 'CO', child: Text('CO')),
  DropdownMenuItem(value: 'CT', child: Text('CT')),
  DropdownMenuItem(value: 'DE', child: Text('DE')),
  DropdownMenuItem(value: 'FL', child: Text('FL')),
  DropdownMenuItem(value: 'GA', child: Text('GA')),
  DropdownMenuItem(value: 'HI', child: Text('HI')),
  DropdownMenuItem(value: 'ID', child: Text('ID')),
  DropdownMenuItem(value: 'IL', child: Text('IL')),
  DropdownMenuItem(value: 'IN', child: Text('IN')),
  DropdownMenuItem(value: 'IA', child: Text('IA')),
  DropdownMenuItem(value: 'KS', child: Text('KS')),
  DropdownMenuItem(value: 'KY', child: Text('KY')),
  DropdownMenuItem(value: 'LA', child: Text('LA')),
  DropdownMenuItem(value: 'ME', child: Text('ME')),
  DropdownMenuItem(value: 'MD', child: Text('MD')),
  DropdownMenuItem(value: 'MA', child: Text('MA')),
  DropdownMenuItem(value: 'MI', child: Text('MI')),
  DropdownMenuItem(value: 'MN', child: Text('MN')),
  DropdownMenuItem(value: 'MS', child: Text('MS')),
  DropdownMenuItem(value: 'MO', child: Text('MO')),
  DropdownMenuItem(value: 'MT', child: Text('MT')),
  DropdownMenuItem(value: 'NE', child: Text('NE')),
  DropdownMenuItem(value: 'NV', child: Text('NV')),
  DropdownMenuItem(value: 'NH', child: Text('NH')),
  DropdownMenuItem(value: 'NJ', child: Text('NJ')),
  DropdownMenuItem(value: 'NM', child: Text('NM')),
  DropdownMenuItem(value: 'NY', child: Text('NY')),
  DropdownMenuItem(value: 'NC', child: Text('NC')),
  DropdownMenuItem(value: 'ND', child: Text('ND')),
  DropdownMenuItem(value: 'OH', child: Text('OH')),
  DropdownMenuItem(value: 'OK', child: Text('OK')),
  DropdownMenuItem(value: 'OR', child: Text('OR')),
  DropdownMenuItem(value: 'PA', child: Text('PA')),
  DropdownMenuItem(value: 'RI', child: Text('RI')),
  DropdownMenuItem(value: 'SC', child: Text('SC')),
  DropdownMenuItem(value: 'SD', child: Text('SD')),
  DropdownMenuItem(value: 'TN', child: Text('TN')),
  DropdownMenuItem(value: 'TX', child: Text('TX')),
  DropdownMenuItem(value: 'UT', child: Text('UT')),
  DropdownMenuItem(value: 'VT', child: Text('VT')),
  DropdownMenuItem(value: 'VA', child: Text('VA')),
  DropdownMenuItem(value: 'WA', child: Text('WA')),
  DropdownMenuItem(value: 'WV', child: Text('WV')),
  DropdownMenuItem(value: 'WI', child: Text('WI')),
  DropdownMenuItem(value: 'WY', child: Text('WY')),
];

// ---- Geocode helper ----
Future<({double lat, double lng})?> _geocode({
  required String city,
  required String stateOrRegion,
  required String countryCode,
}) async {
  final parts = [city, stateOrRegion, countryCode]
      .where((s) => s.trim().isNotEmpty)
      .join(', ');
  if (parts.isEmpty) return null;

  final url = Uri.parse(
    'https://nominatim.openstreetmap.org/search?format=json&limit=1&q=${Uri.encodeComponent(parts)}',
  );

  final r = await http.get(
    url,
    headers: const {
      'User-Agent': 'Finder/0.1 (contact: youremail@example.com)',
      'Accept': 'application/json',
    },
  );
  if (r.statusCode != 200) return null;

  final list = jsonDecode(r.body) as List;
  if (list.isEmpty) return null;

  final m = list.first as Map<String, dynamic>;
  final lat = double.tryParse('${m['lat']}');
  final lng = double.tryParse('${m['lon']}');
  if (lat == null || lng == null) return null;

  return (lat: lat, lng: lng);
}

class EditReportPage extends StatefulWidget {
  final String id;
  const EditReportPage({super.key, required this.id});

  @override
  State<EditReportPage> createState() => _EditReportPageState();
}

class _EditReportPageState extends State<EditReportPage> {
  final _form = GlobalKey<FormState>();
  final _text = TextEditingController();
  final _city = TextEditingController();
  final _stateCtrl = TextEditingController();
  final _country = TextEditingController(text: 'US');

  DateTime? _eventTime;
  bool _loading = true;

  final sb = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final row = await sb
          .from('reports')
          .select('raw_text, city, state, country, event_time')
          .eq('id', widget.id)
          .single();

      _text.text = (row['raw_text'] ?? '') as String;
      _city.text = (row['city'] ?? '') as String;
      _stateCtrl.text = (row['state'] ?? '') as String;

      _country.text = ((row['country'] ?? 'US') as String).toUpperCase();
      if (_country.text == 'USA') _country.text = 'US';

      _eventTime =
          DateTime.tryParse((row['event_time'] ?? '') as String? ?? '');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You can only edit your own report.')),
        );
        Navigator.pop(context);
      }
      return;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      // Geocode after edits
      final geo = await _geocode(
        city: _city.text.trim(),
        stateOrRegion: _stateCtrl.text.trim(),
        countryCode: _country.text.trim(),
      );

      final update = {
        'raw_text': _text.text.trim(),
        'city': _city.text.trim(),
        'state': _stateCtrl.text.trim(),
        'country': _country.text.trim(),
        'event_time': (_eventTime ?? DateTime.now()).toIso8601String(),
        if (geo != null) 'lat': geo.lat,
        if (geo != null) 'lng': geo.lng,
      };

      await sb.from('reports').update(update).eq('id', widget.id);

      // Optional: re-run match worker
      final fun =
          const String.fromEnvironment('SUPABASE_FUN_URL', defaultValue: '');
      final anon =
          const String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');
      if (fun.isNotEmpty && anon.isNotEmpty) {
        await http.post(
          Uri.parse('$fun/match?report_id=${widget.id}'),
          headers: {'Authorization': 'Bearer $anon'},
        );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report updated')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Update failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    String _status = 'OPEN'; // load from row['status']
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit report'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _save,
            icon: const Icon(Icons.save),
            tooltip: 'Save',
          )
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  DropdownButtonFormField<String>(
                    value: _status,
                    decoration: const InputDecoration(labelText: 'Status'),
                    items: const [
                      DropdownMenuItem(value: 'OPEN', child: Text('Open')),
                      DropdownMenuItem(
                          value: 'RESOLVED', child: Text('Resolved')),
                      DropdownMenuItem(
                          value: 'MATCHED', child: Text('Matched')),
                    ],
                    onChanged: (v) => setState(() => _status = v ?? 'OPEN'),
                  ),

                  TextFormField(
                    controller: _text,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: 'Description'),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),

                  // City
                  TextFormField(
                    controller: _city,
                    decoration: const InputDecoration(labelText: 'City'),
                  ),
                  const SizedBox(height: 12),

                  // Country
                  DropdownButtonFormField<String>(
                    value: _country.text,
                    decoration: const InputDecoration(labelText: 'Country'),
                    items: _countries,
                    onChanged: (v) {
                      setState(() {
                        _country.text = v ?? 'US';
                        _stateCtrl.clear();
                      });
                    },
                  ),
                  const SizedBox(height: 12),

                  // State (US dropdown) or Region text
                  (_country.text == 'US')
                      ? DropdownButtonFormField<String>(
                          isExpanded: true,
                          value:
                              _stateCtrl.text.isEmpty ? null : _stateCtrl.text,
                          decoration: const InputDecoration(labelText: 'State'),
                          items: _usStates,
                          onChanged: (v) =>
                              setState(() => _stateCtrl.text = v ?? ''),
                          validator: (v) => (v == null || v.isEmpty)
                              ? 'Select a state'
                              : null,
                        )
                      : TextFormField(
                          controller: _stateCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Region / State / Province',
                          ),
                        ),

                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _loading ? null : _save,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ),
    );
  }
}
