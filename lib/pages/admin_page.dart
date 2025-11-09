import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class AdminPage extends StatefulWidget {
  const AdminPage({super.key});
  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  final ctrl = TextEditingController();
  Future<void> _ingest() async {
    final fun =
        const String.fromEnvironment('SUPABASE_FUN_URL', defaultValue: '');
    final service =
        const String.fromEnvironment('SUPABASE_SERVICE_ROLE', defaultValue: '');
    final r = await http.post(Uri.parse('$fun/ingest'),
        headers: {
          'Authorization': 'Bearer $service',
          'Content-Type': 'application/json'
        },
        body: jsonEncode({'url': ctrl.text}));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Ingest: ${r.statusCode}')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(title: const Text('Admin')),
        body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              TextField(
                  controller: ctrl,
                  decoration:
                      const InputDecoration(labelText: 'Shelter CSV/RSS URL')),
              const SizedBox(height: 12),
              FilledButton(onPressed: _ingest, child: const Text('Import'))
            ])));
  }
}
