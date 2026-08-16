import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Battery percentage and temperature for the per-turn log.
///
/// Protocol section 1b records both on every turn, and section 2 builds a whole
/// thermal-control procedure around them, so a reading that silently fails
/// would undermine the timing data.
///
/// Android only. Temperature is not exposed by any battery plugin because it
/// lives in the `ACTION_BATTERY_CHANGED` sticky broadcast rather than
/// `BatteryManager`, so this goes through a dedicated channel.
class BatteryStatus {
  const BatteryStatus({this.percent, this.temperatureC});

  /// 0-100, or null when unavailable.
  final int? percent;

  /// Degrees Celsius. Android reports tenths of a degree; already converted.
  final double? temperatureC;

  bool get isAvailable => percent != null || temperatureC != null;

  @override
  String toString() =>
      'BatteryStatus(percent: $percent, temperatureC: $temperatureC)';
}

class BatteryStatusService {
  BatteryStatusService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(defaultChannelName);

  static const String defaultChannelName = 'mybuddy/battery';

  final MethodChannel _channel;

  /// Never throws. An unreadable battery must not abort a turn or drop its log
  /// row — the row is written with blank battery columns instead.
  Future<BatteryStatus> read() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('read');
      if (result == null) return const BatteryStatus();

      final percent = result['percent'];
      final temperature = result['temperatureC'];

      return BatteryStatus(
        percent: percent is int
            ? percent
            : percent is num
            ? percent.toInt()
            : null,
        temperatureC: temperature is double
            ? temperature
            : temperature is num
            ? temperature.toDouble()
            : null,
      );
    } on MissingPluginException {
      // Expected on desktop, web and in tests.
      return const BatteryStatus();
    } catch (e) {
      debugPrint('BatteryStatusService: read failed: $e');
      return const BatteryStatus();
    }
  }
}
