import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// ═══════════════════════════════════════════════════════════════════════
// NOTIFICATIONS — a loud, high-priority alarm when a cooking step timer
// finishes, so it's heard from across the kitchen (not just a silent buzz).
// Uses immediate .show() fired by the in-app countdown (no scheduling), so
// no exact-alarm / timezone setup is needed.
// ═══════════════════════════════════════════════════════════════════════

class Notifications {
  static final FlutterLocalNotificationsPlugin _p =
      FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'cook_timers',
    'Cook timers',
    description: 'Alerts when a cooking step timer finishes',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  static Future<void> init() async {
    if (_inited) {
      return;
    }
    try {
      const AndroidInitializationSettings android =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      await _p.initialize(
          const InitializationSettings(android: android));
      await _p
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_channel);
      _inited = true;
    } catch (_) {}
  }

  /// Ask for the POST_NOTIFICATIONS permission (Android 13+). Safe to call
  /// repeatedly; no-op if already granted or on older Android.
  static Future<void> requestPermission() async {
    try {
      await init();
      await _p
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {}
  }

  static Future<void> alarm(String title, String body) async {
    try {
      await init();
      const NotificationDetails details = NotificationDetails(
        android: AndroidNotificationDetails(
          'cook_timers',
          'Cook timers',
          channelDescription: 'Alerts when a cooking step timer finishes',
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          category: AndroidNotificationCategory.alarm,
          fullScreenIntent: true,
        ),
      );
      await _p.show(
          8000 + (DateTime.now().millisecondsSinceEpoch % 1000),
          title,
          body,
          details);
    } catch (_) {}
  }
}
