import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart' as gc;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

class CreateReportPage extends StatefulWidget {
  const CreateReportPage({super.key});
  @override
  State<CreateReportPage> createState() => _CreateReportPageState();
}

class _CreateReportPageState extends State<CreateReportPage> {
  final _form = GlobalKey<FormState>();

  // Text fields
  final _descCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _stateCtrl = TextEditingController(); // US state code or region text
  final _countryCtrl = TextEditingController(text: 'US');
  final _locationDetailsCtrl = TextEditingController();
  bool _showApprox = true; // default privacy-friendly

  String _kind = 'LOST'; // MUST match DB constraint: LOST | FOUND | SIGHTING
  bool _saving = false;

  final _picker = ImagePicker();
  final _sb = Supabase.instance.client; // single client

  // Selected images
  final List<XFile> _photos = [];

  LatLng? _pin; // preview pin location
  bool _locBusy = false; // GPS in progress
  final _mapController = MapController(); // optional: to move camera

  @override
  void dispose() {
    _descCtrl.dispose();
    _cityCtrl.dispose();
    _stateCtrl.dispose();
    _countryCtrl.dispose();
    _locationDetailsCtrl.dispose();
    super.dispose();
  }

  Future<bool> _requestLocation() async {
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever ||
        perm == LocationPermission.denied) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location permission denied')),
      );
      return false;
    }
    return true;
  }

  Future<void> _useMyLocation() async {
    if (_locBusy) return;
    setState(() => _locBusy = true);
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enable Location Services')),
        );
        return;
      }

      if (!await _requestLocation()) return;

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final places =
          await gc.placemarkFromCoordinates(pos.latitude, pos.longitude);

      if (places.isNotEmpty) {
        final p = places.first;
        if (_cityCtrl.text.trim().isEmpty && (p.locality ?? '').isNotEmpty) {
          _cityCtrl.text = p.locality!;
        }
        if (_stateCtrl.text.trim().isEmpty &&
            (p.administrativeArea ?? '').isNotEmpty) {
          // _stateCtrl.text = p.administrativeArea!;
          _stateCtrl.text = _toUsStateCode(p.administrativeArea ?? '');
        }
        if (_countryCtrl.text.trim().isEmpty &&
            (p.isoCountryCode ?? '').isNotEmpty) {
          _countryCtrl.text = (p.isoCountryCode ?? '').toUpperCase();
        }
      }

      _pin = LatLng(pos.latitude, pos.longitude);
      try {
        _mapController.move(_pin!, 14);
      } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location detected')),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Location error: $e')),
      );
    } finally {
      if (mounted) setState(() => _locBusy = false);
    }
  }

  Future<Uint8List> _compressBytes(Uint8List src) async {
    final out = await FlutterImageCompress.compressWithList(
      src,
      minWidth: 1200,
      minHeight: 1200,
      quality: 80,
      format: CompressFormat.jpeg,
      keepExif: false,
    );
    return Uint8List.fromList(out);
  }

  // Pick multiple photos
  Future<void> _pickPhotos() async {
    try {
      final picked = await _picker.pickMultiImage(imageQuality: 80);
      if (picked.isEmpty) return;
      setState(() {
        _photos.addAll(picked);
        if (_photos.length > 6)
          _photos.removeRange(6, _photos.length); // cap @ 6
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Pick failed: $e')),
      );
    }
  }

  // Upload photos to Supabase Storage
  Future<List<String>> _uploadReportPhotos({
    required String uid,
    required String reportId,
  }) async {
    final urls = <String>[];

    for (int i = 0; i < _photos.length; i++) {
      final x = _photos[i];

      // Read original bytes
      final raw = await x.readAsBytes();

      // Always compress to JPEG for smaller, consistent files
      final compressed = await _compressBytes(raw); // ~1200px long edge

      // Force .jpg extension (since we compress to JPEG)
      final filename = '${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
      final storagePath = '$uid/$reportId/$filename';

      await _sb.storage.from('reports').uploadBinary(
            storagePath,
            compressed,
            fileOptions: const FileOptions(
              contentType: 'image/jpeg',
              upsert: true,
            ),
          );

      final publicUrl = _sb.storage.from('reports').getPublicUrl(storagePath);
      urls.add(publicUrl);
    }

    return urls;
  }

  // Geocode using OpenStreetMap Nominatim
  Future<({double lat, double lng})?> _geocode({
    required String details,
    required String city,
    required String stateOrRegion,
    required String countryCode, // ISO like 'US'
  }) async {
    final parts = [details, city, stateOrRegion, countryCode]
        .where((s) => s.trim().isNotEmpty)
        .join(', ');
    if (parts.isEmpty) return null;

    final url = Uri.parse(
      'https://nominatim.openstreetmap.org/search'
      '?format=json&limit=1&q=${Uri.encodeComponent(parts)}',
    );

    final r = await http.get(
      url,
      headers: const {
        'User-Agent': 'Finder/0.1 (contact: smbryant20@gmail.com)',
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

  final _rand = Random();
  // Submit report
  ({double lat, double lng})? _maskIfNeeded(({double lat, double lng}) p) {
    if (!_showApprox) return p;
    // ~100m radius jitter
    final meters = 100.0;
    final dx = (_rand.nextDouble() * 2 - 1) * meters;
    final dy = (_rand.nextDouble() * 2 - 1) * meters;
    // rough meter->degree conversions near mid-latitudes
    final dLat = dy / 111320.0;
    final dLng = dx / (111320.0 * cos(p.lat * pi / 180));
    return (lat: p.lat + dLat, lng: p.lng + dLng);
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;

    final user = _sb.auth.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in first.')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      // Prefer the preview pin; otherwise best-effort geocode
      ({double lat, double lng})? loc;
      if (_pin != null) {
        loc = (lat: _pin!.latitude, lng: _pin!.longitude);
      } else {
        loc = await _geocode(
          details: _locationDetailsCtrl.text.trim(),
          city: _cityCtrl.text.trim(),
          stateOrRegion: _stateCtrl.text.trim(),
          countryCode: _countryCtrl.text.trim(),
        );
      }
      final masked = (loc == null) ? null : _maskIfNeeded(loc);

      final inserted = await _sb
          .from('reports')
          .insert({
            'kind': _kind,
            'raw_text': _descCtrl.text.trim(),
            'location_details': _locationDetailsCtrl.text.trim(),
            'city': _cityCtrl.text.trim(),
            'state': _stateCtrl.text.trim(),
            'country': _countryCtrl.text.trim(),
            if (masked != null) 'lat': masked.lat,
            if (masked != null) 'lng': masked.lng,
            'show_approx': _showApprox,
            'created_by': user.id,
          })
          .select('id')
          .single();

      final reportId = inserted['id'] as String;

      if (_photos.isNotEmpty) {
        final urls =
            await _uploadReportPhotos(uid: user.id, reportId: reportId);
        await _sb.from('reports').update({'images': urls}).eq('id', reportId);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report created')),
      );

// Navigate to the report and reset form when coming back
      context.push('/report/$reportId').then((_) {
        _form.currentState?.reset();
        _descCtrl.clear();
        _cityCtrl.clear();
        _stateCtrl.clear();
        _countryCtrl.text = 'US';
        _locationDetailsCtrl.clear();
        _photos.clear();
        _pin = null;
        setState(() {});
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Create failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final stateValue = _toUsStateCode(_stateCtrl.text);
    final hasItem = _usStates.any((it) => it.value == stateValue);
    return Scaffold(
      appBar: AppBar(title: const Text('Create report')),
      body: Form(
        key: _form,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<String>(
              value: _kind,
              decoration: const InputDecoration(labelText: 'Type'),
              items: const [
                DropdownMenuItem(value: 'LOST', child: Text('Lost')),
                DropdownMenuItem(value: 'FOUND', child: Text('Found')),
                DropdownMenuItem(value: 'SIGHTING', child: Text('Sighting')),
              ],
              onChanged: (v) => setState(() => _kind = v ?? 'LOST'),
            ),
            const SizedBox(height: 12),

            TextFormField(
              controller: _descCtrl,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Description'),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Please add a description'
                  : null,
            ),

            const SizedBox(height: 12),
            TextFormField(
              controller: _locationDetailsCtrl,
              decoration: const InputDecoration(
                labelText: 'Location details (street/park/landmark)',
                hintText: 'e.g. Near Main St & Oak Ave',
              ),
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Switch(
                  value: _showApprox,
                  onChanged: (v) => setState(() => _showApprox = v),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Show approximate location on map (privacy-friendly)',
                    maxLines: 2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // City + State/Region (state is dropdown for US)
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _cityCtrl,
                    decoration: const InputDecoration(labelText: 'City'),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Please enter a city'
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                    child: (_countryCtrl.text == 'US')
                        ? DropdownButtonFormField<String>(
                            isExpanded: true,
                            value: hasItem ? stateValue : null,
                            decoration: const InputDecoration(
                                labelText: 'State (US only)'),
                            items: _usStates,
                            onChanged: (v) =>
                                setState(() => _stateCtrl.text = v ?? ''),
                            validator: (v) => (_countryCtrl.text == 'US' &&
                                    (v == null || v.isEmpty))
                                ? 'Select a state'
                                : null,
                          )
                        : TextFormField(
                            controller: _stateCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Region / State / Province',
                              isDense: true,
                            ),
                          )),
              ],
            ),
            const SizedBox(height: 12),

            // Country dropdown
            DropdownButtonFormField<String>(
              value: _countryCtrl.text,
              decoration: const InputDecoration(labelText: 'Country'),
              items: _countries,
              onChanged: (v) => setState(() {
                _countryCtrl.text = v ?? 'US';
                _stateCtrl.clear();
              }),
            ),
            const SizedBox(height: 16),
// --- Preview pin on map ---
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _locBusy ? null : _useMyLocation,
                  icon: const Icon(Icons.my_location),
                  label: Text(_locBusy ? 'Locating…' : 'Use my location'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    // If user already dropped a pin manually, just refresh the map
                    if (_pin != null) {
                      _mapController.move(_pin!, 14);
                      return;
                    }

                    // Otherwise, geocode their city/state/country and drop a preview pin
                    final geo = await _geocode(
                      details: _locationDetailsCtrl.text.trim(),
                      city: _cityCtrl.text.trim(),
                      stateOrRegion: _stateCtrl.text.trim(),
                      countryCode: _countryCtrl.text.trim(),
                    );

                    if (geo != null) {
                      setState(() {
                        _pin = LatLng(geo.lat, geo.lng);
                      });
                      _mapController.move(_pin!, 14);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Could not locate that area')),
                      );
                    }
                  },
                  icon: const Icon(Icons.push_pin_outlined),
                  label: const Text('Preview pin'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 220,
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _pin ?? const LatLng(42.7, -73.1),
                  initialZoom: _pin == null ? 12 : 14,
                  onTap: (tapPos, latLng) => setState(() => _pin = latLng),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  ),
                  if (_pin != null)
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: _pin!,
                          width: 40,
                          height: 40,
                          child: const Icon(Icons.place, size: 36),
                        ),
                      ],
                    ),
                  // OSM attribution (bottom-right)
                  RichAttributionWidget(
                    alignment: AttributionAlignment.bottomRight,
                    attributions: [
                      TextSourceAttribution(
                        '© OpenStreetMap contributors',
                        // Optional: tap to open the copyright page
                        // onTap: () => launchUrl(Uri.parse('https://www.openstreetmap.org/copyright')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_pin != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Pin: ${_pin!.latitude.toStringAsFixed(5)}, ${_pin!.longitude.toStringAsFixed(5)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),

            // Photos section
            Text('Photos', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final x in _photos)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: FutureBuilder<Uint8List>(
                      future: x.readAsBytes(),
                      builder: (context, snap) {
                        if (!snap.hasData) {
                          return Container(
                            width: 72,
                            height: 72,
                            color: scheme
                                .surfaceContainerHighest, // more compatible
                            alignment: Alignment.center,
                            child: const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          );
                        }
                        return Image.memory(
                          snap.data!,
                          width: 72,
                          height: 72,
                          fit: BoxFit.cover,
                        );
                      },
                    ),
                  ),
                // add tile
                InkWell(
                  onTap: _saving ? null : _pickPhotos,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: scheme.primaryContainer,
                    ),
                    child: Icon(Icons.add_a_photo,
                        color: scheme.onPrimaryContainer),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _submit,
              child: Text(_saving ? 'Saving…' : 'Submit'),
            ),
          ],
        ),
      ),
    );
  }
}

const Map<String, String> _usStateNameToCode = {
  'ALABAMA': 'AL',
  'ALASKA': 'AK',
  'ARIZONA': 'AZ',
  'ARKANSAS': 'AR',
  'CALIFORNIA': 'CA',
  'COLORADO': 'CO',
  'CONNECTICUT': 'CT',
  'DELAWARE': 'DE',
  'FLORIDA': 'FL',
  'GEORGIA': 'GA',
  'HAWAII': 'HI',
  'IDAHO': 'ID',
  'ILLINOIS': 'IL',
  'INDIANA': 'IN',
  'IOWA': 'IA',
  'KANSAS': 'KS',
  'KENTUCKY': 'KY',
  'LOUISIANA': 'LA',
  'MAINE': 'ME',
  'MARYLAND': 'MD',
  'MASSACHUSETTS': 'MA',
  'MICHIGAN': 'MI',
  'MINNESOTA': 'MN',
  'MISSISSIPPI': 'MS',
  'MISSOURI': 'MO',
  'MONTANA': 'MT',
  'NEBRASKA': 'NE',
  'NEVADA': 'NV',
  'NEW HAMPSHIRE': 'NH',
  'NEW JERSEY': 'NJ',
  'NEW MEXICO': 'NM',
  'NEW YORK': 'NY',
  'NORTH CAROLINA': 'NC',
  'NORTH DAKOTA': 'ND',
  'OHIO': 'OH',
  'OKLAHOMA': 'OK',
  'OREGON': 'OR',
  'PENNSYLVANIA': 'PA',
  'RHODE ISLAND': 'RI',
  'SOUTH CAROLINA': 'SC',
  'SOUTH DAKOTA': 'SD',
  'TENNESSEE': 'TN',
  'TEXAS': 'TX',
  'UTAH': 'UT',
  'VERMONT': 'VT',
  'VIRGINIA': 'VA',
  'WASHINGTON': 'WA',
  'WEST VIRGINIA': 'WV',
  'WISCONSIN': 'WI',
  'WYOMING': 'WY',
};

String _toUsStateCode(String input) {
  final t = input.trim();
  if (t.isEmpty) return '';
  final up = t.toUpperCase();
  if (_usStateNameToCode.containsKey(up)) return _usStateNameToCode[up]!;
  if (up.length == 2) return up; // already a code
  return '';
}

// --- Static lists (countries & US states) ---
const _countries = <DropdownMenuItem<String>>[
  DropdownMenuItem(value: 'US', child: Text('United States')),
  DropdownMenuItem(value: 'CA', child: Text('Canada')),
  DropdownMenuItem(value: 'GB', child: Text('United Kingdom')),
  DropdownMenuItem(value: 'AU', child: Text('Australia')),
  DropdownMenuItem(value: 'IE', child: Text('Ireland')),
  DropdownMenuItem(value: 'NZ', child: Text('New Zealand')),
];

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
