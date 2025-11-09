// router.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'pages/home_page.dart';
import 'pages/sign_in_page.dart';
import 'pages/create_report_page.dart';
import 'pages/report_detail_page.dart';
import 'pages/edit_report_page.dart';
import 'pages/alerts_page.dart';
import 'pages/admin_page.dart';
import 'pages/profile_page.dart';

class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream stream) {
    _sub = stream.asBroadcastStream().listen((_) => notifyListeners());
  }
  late final StreamSubscription _sub;
  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

/// Call this **after** Supabase.initialize()
GoRouter buildRouter() {
  final auth = Supabase.instance.client.auth;

  String? _redirect(BuildContext context, GoRouterState state) {
    final session = auth.currentSession;
    final loggingIn = state.matchedLocation == '/signin';
    final needsAuth = const ['/create', '/profile', '/alerts', '/admin']
        .any((p) => state.matchedLocation.startsWith(p));

    if (session == null && needsAuth && !loggingIn) {
      final from = Uri.encodeComponent(state.matchedLocation);
      return '/signin?from=$from';
    }
    if (session != null && loggingIn) {
      return state.uri.queryParameters['from'] ?? '/';
    }
    return null;
  }

  return GoRouter(
    initialLocation: '/',
    refreshListenable: GoRouterRefreshStream(auth.onAuthStateChange),
    redirect: _redirect,
    routes: [
      GoRoute(path: '/', builder: (c, s) => const HomePage()),
      GoRoute(path: '/signin', builder: (c, s) => const SignInPage()),
      GoRoute(path: '/create', builder: (c, s) => const CreateReportPage()),
      GoRoute(
        path: '/report/:id',
        builder: (c, s) => ReportDetailPage(id: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/report/:id/edit',
        builder: (c, s) => EditReportPage(id: s.pathParameters['id']!),
      ),
      GoRoute(path: '/alerts', builder: (c, s) => const AlertsPage()),
      GoRoute(path: '/admin', builder: (c, s) => const AdminPage()),
      GoRoute(path: '/profile', builder: (c, s) => const ProfilePage()),
    ],
  );
}
