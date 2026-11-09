import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

const String kAlarmChannelId = 'smart_notes_alarms_v2';
const int kSnoozeMinutes = 5;

NotificationDetails buildAlarmDetails({int level = 0}) {
  const ios = DarwinNotificationDetails(
    presentAlert: true,
    presentSound: true,
    presentBanner: true,
    presentList: true,
  );

  if (level >= 2) {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        'smart_notes_reminders',
        'تذكيرات مذكرتي الذكية',
        channelDescription: 'إشعارات المهام والتذكيرات',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
      ),
      iOS: ios,
    );
  }

  final custom = level == 0;

  return NotificationDetails(
    android: AndroidNotificationDetails(
      custom ? kAlarmChannelId : '${kAlarmChannelId}_default',
      'منبّهات المذكرة',
      channelDescription: 'منبّه يرنّ حتى تتفاعل معه',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      sound: custom
          ? const RawResourceAndroidNotificationSound('alarm')
          : null,
      playSound: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 800, 500, 800]),
      fullScreenIntent: true,
      visibility: NotificationVisibility.public,
      additionalFlags: Int32List.fromList(<int>[4]),
      actions: const [
        AndroidNotificationAction(
          'snooze',
          'غفوة $kSnoozeMinutes دقائق',
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          'stop',
          'إيقاف',
          cancelNotification: true,
        ),
      ],
    ),
    iOS: ios,
  );
}

/// مسار الغفوة من زر الإشعار.
Future<void> handleNotificationAction(
  NotificationResponse response,
) async {
  if (response.actionId != 'snooze') return;

  DartPluginRegistrant.ensureInitialized();

  tz.initializeTimeZones();

  final plugin = FlutterLocalNotificationsPlugin();

  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );

  final now = tz.TZDateTime.now(tz.UTC);
  final when = now.add(
    const Duration(minutes: kSnoozeMinutes),
  );

  for (var level = 0; level <= 2; level++) {
    try {
      await plugin.zonedSchedule(
        id: response.id ?? 0,
        title: 'حان موعد التذكير',
        body: response.payload ?? '',
        scheduledDate: when,
        notificationDetails: buildAlarmDetails(level: level),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: response.payload,
      );

      debugPrint('BACKGROUND SNOOZE: $now -> $when');
      return;
    } catch (e) {
      debugPrint('BACKGROUND SNOOZE level $level failed: $e');
    }
  }
}

@pragma('vm:entry-point')
void notificationBackgroundHandler(
  NotificationResponse response,
) async {
  DartPluginRegistrant.ensureInitialized();
  await handleNotificationAction(response);
}

class NotificationService {
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static void Function(int id, String task)? onAlarmOpened;

  bool _initialized = false;
  Future<void>? _initializing;

  String lastWarning = '';

  void _onResponse(NotificationResponse response) {
    if (response.actionId == 'snooze') {
      unawaited(handleNotificationAction(response));
      return;
    }

    if (response.actionId == 'stop') return;

    onAlarmOpened?.call(
      response.id ?? 0,
      response.payload ?? '',
    );
  }

  Future<void> initialize() async {
    if (_initialized) return;

    if (_initializing != null) {
      await _initializing;
      return;
    }

    _initializing = _initializeInternal();

    try {
      await _initializing;
    } finally {
      _initializing = null;
    }
  }

  Future<void> _initializeInternal() async {
    tz.initializeTimeZones();

    final timeZone = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(timeZone.identifier));

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: true,
        requestSoundPermission: true,
        requestBadgePermission: true,
      ),
    );

    await _notifications.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onResponse,
      onDidReceiveBackgroundNotificationResponse:
          notificationBackgroundHandler,
    );

    final android = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();

    _initialized = true;
  }

  Future<void> checkLaunchFromNotification() async {
    await initialize();

    final details =
        await _notifications.getNotificationAppLaunchDetails();

    final response = details?.notificationResponse;

    if (details != null &&
        details.didNotificationLaunchApp &&
        response != null &&
        (response.actionId == null || response.actionId!.isEmpty)) {
      onAlarmOpened?.call(
        response.id ?? 0,
        response.payload ?? '',
      );
    }
  }

  Future<int> scheduleReminder({
    required int id,
    required String task,
    required DateTime dateTime,
  }) async {
    await initialize();

    final scheduledDate = tz.TZDateTime.from(dateTime, tz.local);
    final now = tz.TZDateTime.now(tz.local);

    if (!scheduledDate.isAfter(now)) {
      throw Exception('موعد التذكير يجب أن يكون في المستقبل');
    }

    final errors = <String>[];
    lastWarning = '';

    for (var level = 0; level <= 2; level++) {
      try {
        await _notifications.zonedSchedule(
          id: id,
          title: 'حان موعد التذكير',
          body: task,
          scheduledDate: scheduledDate,
          notificationDetails: buildAlarmDetails(level: level),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          payload: task,
        );

        debugPrint(
          'REMINDER SCHEDULED: id=$id, now=$now, target=$scheduledDate',
        );

        lastWarning = errors.join('\n\n');
        return level;
      } catch (e) {
        debugPrint('SCHEDULE level $level failed: $e');
        errors.add('المستوى $level: $e');
      }
    }

    throw Exception(errors.join('\n\n'));
  }

  /// الغفوة من داخل صفحة المنبّهات.
  /// تلغي الموعد الحالي ثم تحسب موعداً جديداً بعد خمس دقائق كاملة.
  Future<void> snoozeNow(int id, String task) async {
    await initialize();

    await cancel(id);

    final pressedAt = DateTime.now();
    final newDate = pressedAt.add(
      const Duration(minutes: kSnoozeMinutes),
    );

    debugPrint(
      'SNOOZE PRESSED: $pressedAt | NEW TIME: $newDate',
    );

    await scheduleReminder(
      id: id,
      task: task,
      dateTime: newDate,
    );
  }

  Future<void> cancel(int id) async {
    await initialize();
    await _notifications.cancel(id: id);
  }
}
