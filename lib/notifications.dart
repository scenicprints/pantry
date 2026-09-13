import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// ═══════════════════════════════════════════════════════════════════════
// NOTIFICATIONS — a loud, high-priority alarm when a cooking step timer
// finishes, so it's heard from across the kitchen (not just a silent buzz).
// Uses immediate .show() fired by the in-app countdown (no scheduling), so
// no exact-alarm / timezone setup is needed.
//
// iOS/iPadOS takes the same calls through the Darwin settings below. It has no
// notification channels and no full-screen intent, so the alarm there is a
// banner + sound; the in-app countdown, the buzz and the wakelock carry the
// rest. Permission is asked at init on iOS (Android 13+ asks separately).
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
      const DarwinInitializationSettings darwin = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: false,
        requestSoundPermission: true,
      );
      await _p.initialize(
          const InitializationSettings(android: android, iOS: darwin));
      await _p
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_channel);
      _inited = true;
    } catch (_) {}
  }

  /// Ask for notification permission — POST_NOTIFICATIONS on Android 13+,
  /// the alert/sound prompt on iOS. Safe to call repeatedly; no-op if already
  /// granted or on older Android.
  static Future<void> requestPermission() async {
    try {
      await init();
      await _p
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      await _p
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, sound: true);
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
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          // Not timeSensitive: that level needs a signed entitlement on the
          // App ID. Raise it later if the kitchen timer is too quiet.
          interruptionLevel: InterruptionLevel.active,
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
