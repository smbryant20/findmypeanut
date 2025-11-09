import 'dart:convert';
import 'package:http/http.dart' as http;

class Api {
  final String base; // e.g., https://<project>.supabase.co/functions/v1
  final String
  serviceKey; // use anon for public GETs; service for admin tools only (server-side)
  Api(this.base, this.serviceKey);

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $serviceKey',
    'Content-Type': 'application/json',
  };

  Future<Map<String, dynamic>> createReport(Map<String, dynamic> body) async {
    final r = await http.post(
      Uri.parse('$base/reports'),
      headers: _headers,
      body: jsonEncode(body),
    );
    return jsonDecode(r.body);
  }

  Future<List<dynamic>> listReports({
    String? kind,
    double? lat,
    double? lng,
    int radius = 25,
  }) async {
    final q = Uri.parse('$base/reports').replace(
      queryParameters: {
        if (kind != null) 'kind': kind,
        if (lat != null && lng != null) 'near': '$lat,$lng',
        if (radius != 25) 'radius': '$radius',
      },
    );
    final r = await http.get(q, headers: _headers);
    return jsonDecode(r.body) as List;
  }

  Future<Map<String, dynamic>> runMatch(String reportId) async {
    final r = await http.post(
      Uri.parse('$base/match?report_id=$reportId'),
      headers: _headers,
    );
    return jsonDecode(r.body);
  }
}
