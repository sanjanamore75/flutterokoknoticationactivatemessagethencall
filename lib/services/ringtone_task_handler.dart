import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:vibration/vibration.dart';

/// Entry-point for the foreground service isolate.
/// Must be a top-level function annotated with @pragma('vm:entry-point').
@pragma('vm:entry-point')
void ringtoneTaskEntryPoint() {
  FlutterForegroundTask.setTaskHandler(RingtoneTaskHandler());
}

/// Plays incoming.mp3 on a loop inside an Android foreground service.
/// The service keeps running even when the host app is killed, so the
/// ringtone continues until the user accepts or declines the call.
class RingtoneTaskHandler extends TaskHandler {
  final AudioPlayer _player = AudioPlayer();
  Timer? _stopTimer;
  Timer? _vibrationTimer;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    print('🔔 RingtoneTaskHandler: starting ringtone');
    // Configure audio context to play loudly as a ringtone and keep device awake
    await _player.setAudioContext(AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: true,
        contentType: AndroidContentType.music,
        usageType: AndroidUsageType.notificationRingtone,
        audioFocus: AndroidAudioFocus.gainTransientExclusive,
      ),
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playback,
        options: {
          AVAudioSessionOptions.defaultToSpeaker,
          AVAudioSessionOptions.mixWithOthers,
        },
      ),
    ));

    // Play audio in a loop
    await _player.setReleaseMode(ReleaseMode.loop);
    await _player.play(AssetSource('ringtone/incoming.mp3'));

    // Start vibration
    bool? hasVibrator = await Vibration.hasVibrator();
    if (hasVibrator == true) {
      bool? hasCustomSupport = await Vibration.hasCustomVibrationsSupport();
      if (hasCustomSupport == true) {
        // Wait 0ms, vibrate 1000ms, wait 1000ms, vibrate 1000ms, etc.
        Vibration.vibrate(pattern: [0, 1000, 1000, 1000], intensities: [0, 255, 0, 255], repeat: 1);
      } else {
        // Fallback for iOS / devices without custom patterns
        Vibration.vibrate();
        _vibrationTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
          Vibration.vibrate();
        });
      }
    }

    // Stop automatically after 60 seconds (normal phone call duration)
    _stopTimer = Timer(const Duration(seconds: 60), () {
      print('⏱️ RingtoneTaskHandler: 60 seconds elapsed, stopping service');
      FlutterForegroundTask.stopService();
    });
  }

  /// Called at the interval set in [FlutterForegroundTask.init] — not used.
  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    print('🔕 RingtoneTaskHandler: stopping ringtone');
    _stopTimer?.cancel();
    _vibrationTimer?.cancel();
    await _player.stop();
    await _player.dispose();
    await Vibration.cancel();
  }

  /// Receives messages sent via [FlutterForegroundTask.sendDataToTask].
  @override
  void onReceiveData(Object data) {
    if (data == 'stop') {
      FlutterForegroundTask.stopService();
    }
  }
}
