import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:zego_zpns/zego_zpns.dart';
import 'package:chating/services/user_service.dart';
import 'package:chating/services/ringtone_service.dart';

/// Manages FCM token retrieval, ZIM push registration,
/// ZPNs registration, and notification permission requests.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  String? _fcmToken;
  String? get fcmToken => _fcmToken;

  String? _pendingAction;
  String? get pendingAction => _pendingAction;
  void clearPendingAction() => _pendingAction = null;

  // ── Initialization ─────────────────────────────────────────────────────────

  Future<void> init() async {
    // 1. Request notification permission
    await _requestPermission();

    // 2. Initialize local notifications (for background messages)
    await _initLocalNotifications();

    // 3. Get FCM token
    _fcmToken = await _fcm.getToken();
    print('📲 NotificationService: FCM Token: $_fcmToken');

    // 4. Sync token with Firebase if logged in
    _syncToken();

    // 5. Listen for token refresh
    _fcm.onTokenRefresh.listen((newToken) {
      _fcmToken = newToken;
      print('📲 NotificationService: FCM Token refreshed: $newToken');
      _registerTokenWithZPNs(newToken);
      _syncToken();
    });

    // 6. Register with ZPNs (for offline call notifications)
    if (_fcmToken != null) {
      _registerTokenWithZPNs(_fcmToken!);
    }

    // 7. Register ZPNs push
    try {
      await ZPNs.getInstance().registerPush();
      print('✅ NotificationService: ZPNs push registered');
    } catch (e) {
      print('⚠️ NotificationService: ZPNs registration error: $e');
    }

    // 8. Handle foreground FCM messages (app is open)
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // 9. Handle notification tap when app was in background (not killed)
    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

    // 10. Check for initial message (app launched from notification tap)
    final initial = await _fcm.getInitialMessage();
    if (initial != null) {
      _handleNotificationTap(initial);
    }

    // 11. Check for notification action launch
    final launchDetails =
        await _localNotifications.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      _pendingAction = launchDetails?.notificationResponse?.actionId;
      print('🚀 App launched from notification action: $_pendingAction');
    }
  }

  void _syncToken() {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && _fcmToken != null) {
      UserService.updateUserToken(user.uid, _fcmToken!);
    }
  }

  // ── Local Notifications Setup ──────────────────────────────────────────────

  /// Initialises the plugin and registers the notification channel.
  /// Safe to call multiple times — runs only once per isolate thanks to [_initialized].
  /// Called by [init] (foreground) AND by [showNotification] (background isolate).
  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const initSettings =
        InitializationSettings(android: androidInit, iOS: iosInit);

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        final actionId = response.actionId;
        final payload = response.payload;
        print(
            '👆 Local notification interaction: Action=$actionId, Payload=$payload');

        // Stop ringtone whenever the user interacts with the notification
        stopRingtone();

        if (actionId == 'accept') {
          _pendingAction = 'accept';
          print('✅ Call accepted from notification');
        } else if (actionId == 'decline') {
          print('❌ Call declined from notification');
        }
      },
    );

    // Register the call notification channel with the custom ringtone.
    // Android persists channels after first creation, but we re-declare it
    // here so the background isolate also has it when the app is killed.
    if (Platform.isAndroid) {
      const callSound = RawResourceAndroidNotificationSound('incoming');

      const callChannel = AndroidNotificationChannel(
        'incoming_call_channel',
        'Incoming Calls',
        description: 'Rings incoming.mp3 for incoming call notifications',
        importance: Importance.max,
        playSound: true,
        sound: callSound,
        enableVibration: true,
      );

      const msgChannel = AndroidNotificationChannel(
        'call_notifications',
        'Messages',
        description: 'Notifications for chat messages',
        importance: Importance.high,
        playSound: true,
      );

      final androidPlugin =
          _localNotifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(callChannel);
      await androidPlugin?.createNotificationChannel(msgChannel);
    }

    print('✅ NotificationService: local notifications initialised');
  }

  // Keep old name as thin alias so the foreground init() call still compiles.
  Future<void> _initLocalNotifications() => _ensureInitialized();

  // ── Permission ─────────────────────────────────────────────────────────────

  Future<void> _requestPermission() async {
    final settings = await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    print(
        '🔔 NotificationService: Notification permission: ${settings.authorizationStatus}');
  }

  // ── ZPNs Token Registration ─────────────────────────────────────────────────

  void _registerTokenWithZPNs(String token) {
    print('✅ NotificationService: Syncing token with ZPNs...');
    ZPNsConfig config = ZPNsConfig();
    ZPNs.setPushConfig(config);
  }

  // ── Foreground Message Handler ─────────────────────────────────────────────

  void _handleForegroundMessage(RemoteMessage message) {
    print(
        '📩 NotificationService: FCM foreground message: ${message.notification?.title}');
    // Detect call in foreground and play ringtone
    final data = message.data;
    bool isCall = data.containsKey('call_id') ||
        data.containsKey('zego') ||
        (message.notification?.title?.toLowerCase().contains('call') ??
            false) ||
        (data['title']?.toLowerCase().contains('call') ?? false);
    if (isCall) {
      playRingtone();
    }
  }

  // ── Notification Tap Handler ────────────────────────────────────────────────

  void _handleNotificationTap(RemoteMessage message) {
    print('👆 NotificationService: FCM Notification tapped: ${message.data}');
  }

  // ── Show Notification ──────────────────────────────────────────────────────

  /// Shows a local notification.
  /// Works in both the foreground app and the killed-app background isolate
  /// because [_ensureInitialized] is called first, guaranteeing the channel exists.
  Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
    bool isCall = false,
  }) async {
    // Ensure the plugin + channel exist — critical for the background isolate.
    await _ensureInitialized();

    // For call notifications use the dedicated channel with incoming.mp3.
    // Android plays the channel sound at OS level — works even when app is killed.
    final String channelId =
        isCall ? 'incoming_call_channel' : 'call_notifications';
    final String channelName =
        isCall ? 'Incoming Calls' : 'Call & Message Notifications';
    final AndroidNotificationSound? sound =
        isCall ? const RawResourceAndroidNotificationSound('incoming') : null;

    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: 'Notifications for incoming calls and messages',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
      playSound: true,
      sound: sound,
      enableVibration: true,
      autoCancel: true,
      additionalFlags: isCall ? Int32List.fromList(<int>[4]) : null, // FLAG_INSISTENT to loop sound/vibration natively
      // Accept / Decline buttons for call notifications
      actions: isCall
          ? <AndroidNotificationAction>[
              const AndroidNotificationAction(
                'accept',
                'Receive',
                showsUserInterface: true,
                cancelNotification: true,
              ),
              const AndroidNotificationAction(
                'decline',
                'Decline',
                showsUserInterface: false,
                cancelNotification: true,
              ),
            ]
          : null,
      fullScreenIntent: isCall,
      category: isCall
          ? AndroidNotificationCategory.call
          : AndroidNotificationCategory.message,
    );

    final notificationDetails = NotificationDetails(android: androidDetails);

    // (Ringtone is handled natively by FLAG_INSISTENT in the notification itself)

    await _localNotifications.show(
      DateTime.now().millisecond,
      title,
      body,
      notificationDetails,
      payload: payload,
    );
  }

  // ── Ringtone Control ───────────────────────────────────────────────────────

  /// Plays incoming.mp3 on a loop until [stopRingtone] is called.
  Future<void> playRingtone() async {
    try {
      await RingtoneService.start();
      print('🔔 NotificationService: RingtoneService started');
    } catch (e) {
      print('⚠️ NotificationService: Could not start RingtoneService: $e');
    }
  }

  /// Stops the ringtone immediately.
  Future<void> stopRingtone() async {
    try {
      await RingtoneService.stop();
      print('🔕 NotificationService: RingtoneService stopped');
    } catch (e) {
      print('⚠️ NotificationService: Could not stop RingtoneService: $e');
    }
  }

  bool get isAndroid => Platform.isAndroid;
}
