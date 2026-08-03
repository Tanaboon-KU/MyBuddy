import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

abstract final class NotificationStorageKeys {
  static const String scheduledDays = 'notification_scheduled_days';
  static const String dailyReminderEnabled = 'daily_reminder_enabled';
}

abstract final class NotificationConfig {
  static const int baseNotificationId = 1001;
  static const int daysToSchedule = 6;
  static const String channelId = 'buddy_reminders';
  static const String channelName = 'Buddy Reminders';
  static const String channelDescription = 'Friendly reminders from your buddy';
}

class NotificationService extends ChangeNotifier {
  factory NotificationService() => _instance;
  NotificationService._internal();
  static final NotificationService _instance = NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _isAppInForeground = true;
  bool _isInitialized = false;
  bool _isDailyReminderEnabled = true;

  bool get isDailyReminderEnabled => _isDailyReminderEnabled;
  bool get isAppInForeground => _isAppInForeground;

  static const List<String> _notificationMessages = [
    "Hey there! 🌟 I've been waiting for you~ Come back and chat with me!",
    "Missing you already! 💕 Let's have a fun conversation today!",
    'Psst! 🐾 Your buddy is feeling lonely... Come say hi!',
    'Where did you go? 🥺 I saved some cool stories just for you!',
    "Hello sunshine! ☀️ It's been a while. I miss our chats!",
    "Guess who's thinking about you? 💭 Hint: It's me, your buddy!",
    "I've been practicing new jokes! 🎉 Come hear them~",
    'Your buddy is sending virtual hugs! 🤗 Come get them!',
    "The app feels empty without you! 🌈 Let's brighten it up together!",
    "Knock knock! 🚪 Oh wait, you're not here... Come back soon!",
    "I learned something new today! 📚 Can't wait to share it with you!",
    'Feeling lonely here... 🌙 A quick hello would make my day!',
    "Your favorite buddy is waiting! 🎀 Don't keep me waiting too long~",
    "I promise I'll be extra fun today! 🌺 Come and see!",
    "Someone special hasn't visited in a while... 💫 Is it you?",
  ];

  static const List<String> _notificationTitles = [
    'Your Buddy Misses You! 💕',
    'Hey, Remember Me? 🌟',
    'Come Back Soon! 🥰',
    'Missing You! 💭',
    'Your Buddy Says Hi! 👋',
  ];

  Future<void> initialize() async {
    if (_isInitialized) return;

    tz_data.initializeTimeZones();
    await _setLocalTimezone();

    final prefs = await SharedPreferences.getInstance();
    _isDailyReminderEnabled =
        prefs.getBool(NotificationStorageKeys.dailyReminderEnabled) ?? true;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    // Every platform whose plugin implementation is compiled into the build
    // must get settings, otherwise initialize() throws. The Windows
    // implementation ships with flutter_local_notifications and is always
    // compiled on desktop, so omitting it made the app die before runApp().
    const windowsSettings = WindowsInitializationSettings(
      appName: 'MyBuddy',
      appUserModelId: 'com.example.mybuddy',
      // Stable identifier for the activation callback. Must not change between
      // releases or previously scheduled toasts stop routing back to the app.
      guid: 'f2b0c1a4-6d3e-4a58-9c17-8e5b2d740af3',
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: iosSettings,
      windows: windowsSettings,
    );

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    await _requestPermissions();

    _isInitialized = true;
    debugPrint('NotificationService initialized');
    debugPrint('Daily reminders enabled: $_isDailyReminderEnabled');
  }

  Future<void> _setLocalTimezone() async {
    try {
      final timezoneInfo = await FlutterTimezone.getLocalTimezone();
      final location = tz.getLocation(timezoneInfo.identifier);
      tz.setLocalLocation(location);
      debugPrint(
        'NotificationService timezone set to ${timezoneInfo.identifier}',
      );
    } catch (e) {
      debugPrint('NotificationService timezone fallback to default: $e');
    }
  }

  Future<void> _requestPermissions() async {
    final androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin != null) {
      await androidPlugin.requestNotificationsPermission();
      await androidPlugin.requestExactAlarmsPermission();
    }

    final iosPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (iosPlugin != null) {
      await iosPlugin.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  Future<void> setDailyReminderEnabled(bool enabled) async {
    if (_isDailyReminderEnabled == enabled) return;

    _isDailyReminderEnabled = enabled;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(NotificationStorageKeys.dailyReminderEnabled, enabled);

    if (enabled) {
      await _scheduleNext6DaysNotifications();
      debugPrint('Daily reminders enabled - scheduled notifications');
    } else {
      await cancelAllScheduledNotifications();
      await _clearScheduledDaysData();
      debugPrint('Daily reminders disabled - cancelled all notifications');
    }

    notifyListeners();
  }

  void setAppForegroundState(bool isInForeground) {
    _isAppInForeground = isInForeground;
    debugPrint('App foreground state: $_isAppInForeground');

    if (isInForeground) {
      _cancelImmediateNotifications();
    }
  }

  Future<void> onAppOpened() async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_isDailyReminderEnabled) {
      await _scheduleNext6DaysNotifications();
    } else {
      debugPrint('Daily reminders disabled - skipping scheduling');
    }
  }

  Future<void> cancelAllScheduledNotifications() async {
    for (
      int dayOffset = 1;
      dayOffset <= NotificationConfig.daysToSchedule;
      dayOffset++
    ) {
      await _notifications.cancel(
        NotificationConfig.baseNotificationId + dayOffset,
      );
    }
    debugPrint('Cancelled all scheduled notifications');
  }

  Future<void> clearScheduledData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(NotificationStorageKeys.scheduledDays);
    await cancelAllScheduledNotifications();
    debugPrint('Cleared all scheduled notification data');
  }

  Future<Map<String, dynamic>> getScheduledInfo() async {
    final scheduledDays = await _getScheduledDays();

    final formattedDays = <String, String>{};
    for (final entry in scheduledDays.entries) {
      formattedDays[entry.key] = DateTime.fromMillisecondsSinceEpoch(
        entry.value,
      ).toString();
    }

    return {
      'scheduledDays': formattedDays,
      'totalScheduled': scheduledDays.length,
      'isInitialized': _isInitialized,
      'isAppInForeground': _isAppInForeground,
    };
  }

  void _onNotificationTapped(NotificationResponse response) {
    debugPrint('Notification tapped: ${response.payload}');
  }

  Future<void> _cancelImmediateNotifications() async {
    final scheduledDays = await _getScheduledDays();
    final now = DateTime.now();

    for (final entry in scheduledDays.entries) {
      final scheduledTimeMs = entry.value;
      final scheduledTime = DateTime.fromMillisecondsSinceEpoch(
        scheduledTimeMs,
      );

      if (scheduledTime.difference(now).inMinutes.abs() <= 1) {
        final dayOffset = int.tryParse(entry.key) ?? 0;
        await _notifications.cancel(
          NotificationConfig.baseNotificationId + dayOffset,
        );
        debugPrint(
          'Cancelled immediate notification for day ${entry.key} - user is in app',
        );
      }
    }
  }

  Future<void> _clearScheduledDaysData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(NotificationStorageKeys.scheduledDays);
  }

  Future<Map<String, int>> _getScheduledDays() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(NotificationStorageKeys.scheduledDays);

    if (jsonStr == null) {
      return {};
    }

    try {
      final Map<String, dynamic> decoded = json.decode(jsonStr);
      return decoded.map((key, value) => MapEntry(key, value as int));
    } catch (e) {
      debugPrint('Error parsing scheduled days: $e');
      return {};
    }
  }

  Future<void> _saveScheduledDays(Map<String, int> scheduledDays) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      NotificationStorageKeys.scheduledDays,
      json.encode(scheduledDays),
    );
  }

  String _getDateKey(int dayOffset) {
    final date = _getDateForOffset(dayOffset);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  DateTime _getDateForOffset(int dayOffset) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + dayOffset);
  }

  Future<void> _scheduleNext6DaysNotifications() async {
    final scheduledDays = await _getScheduledDays();
    final random = Random();
    var hasChanges = false;

    final today = DateTime.now();
    final todayKey =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

    final keysToRemove = <String>[];
    for (final key in scheduledDays.keys) {
      if (key.compareTo(todayKey) <= 0) {
        keysToRemove.add(key);
      }
    }
    for (final key in keysToRemove) {
      scheduledDays.remove(key);
      hasChanges = true;
      debugPrint('Removed past scheduled day: $key');
    }

    for (
      int dayOffset = 1;
      dayOffset <= NotificationConfig.daysToSchedule;
      dayOffset++
    ) {
      final dateKey = _getDateKey(dayOffset);

      if (scheduledDays.containsKey(dateKey)) {
        debugPrint('Day $dayOffset ($dateKey) already scheduled');
        continue;
      }

      final scheduledDateTime = _generateRandomScheduleTime(dayOffset, random);
      final (title, message) = _getRandomNotificationContent(random);

      final notificationId = NotificationConfig.baseNotificationId + dayOffset;

      await _scheduleNotification(
        id: notificationId,
        title: title,
        body: message,
        scheduledTime: scheduledDateTime,
      );

      scheduledDays[dateKey] = scheduledDateTime.millisecondsSinceEpoch;
      hasChanges = true;

      debugPrint(
        'Scheduled notification for day $dayOffset ($dateKey): $scheduledDateTime',
      );
      debugPrint('  Title: $title');
      debugPrint('  Message: $message');
    }

    if (hasChanges) {
      await _saveScheduledDays(scheduledDays);
    }

    debugPrint('Total scheduled days: ${scheduledDays.length}');
  }

  DateTime _generateRandomScheduleTime(int dayOffset, Random random) {
    final hour = 9 + random.nextInt(12); // 9 AM to 8 PM
    final minute = random.nextInt(60);
    final targetDate = _getDateForOffset(dayOffset);

    return DateTime(
      targetDate.year,
      targetDate.month,
      targetDate.day,
      hour,
      minute,
    );
  }

  (String title, String message) _getRandomNotificationContent(Random random) {
    final message =
        _notificationMessages[random.nextInt(_notificationMessages.length)];
    final title =
        _notificationTitles[random.nextInt(_notificationTitles.length)];
    return (title, message);
  }

  Future<void> _scheduleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      NotificationConfig.channelId,
      NotificationConfig.channelName,
      channelDescription: NotificationConfig.channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      enableVibration: true,
      playSound: true,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    final tzScheduledTime = tz.TZDateTime.from(scheduledTime, tz.local);

    await _notifications.zonedSchedule(
      id,
      title,
      body,
      tzScheduledTime,
      notificationDetails,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: 'buddy_reminder',
    );
  }
}
