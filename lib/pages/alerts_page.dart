import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class AlertsPage extends StatefulWidget {
  const AlertsPage({super.key});
  @override
  State<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<AlertsPage> {
  final _form = GlobalKey<FormState>();
  String email = '';
  String petType = 'DOG';
  int radius = 10;
  double lat = 42.7, lng = -73.1;
  Future<void> _submit() async {
    final fun =
        const String.fromEnvironment('SUPABASE_FUN_URL', defaultValue: '');
    final anon =
        const String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');
    final r = await http.post(Uri.parse('$fun/alerts/subscribe'),
        headers: {
          'Authorization': 'Bearer $anon',
          'Content-Type': 'application/json'
        },
        body: jsonEncode({
          'email': email,
          'pet_type': petType,
          'radius': radius,
          'lat': lat,
          'lng': lng
        }));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Subscribed (${r.statusCode})')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(title: const Text('Alerts')),
        body: Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              TextFormField(
                  decoration: const InputDecoration(labelText: 'Email'),
                  onSaved: (v) => email = v ?? '',
                  initialValue: ''),
              const SizedBox(height: 12),
              DropdownButtonFormField(
                  value: petType,
                  items: const [
                    DropdownMenuItem(value: 'DOG', child: Text('Dog')),
                    DropdownMenuItem(value: 'CAT', child: Text('Cat'))
                  ],
                  onChanged: (v) => setState(() => petType = v as String)),
              const SizedBox(height: 12),
              TextFormField(
                  decoration:
                      const InputDecoration(labelText: 'Radius (miles)'),
                  initialValue: '10',
                  onSaved: (v) => radius = int.tryParse(v ?? '10') ?? 10),
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: () {
                    _form.currentState!.save();
                    _submit();
                  },
                  child: const Text('Subscribe'))
            ])));
  }
}
