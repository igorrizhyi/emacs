import messaging, {
  FirebaseMessagingTypes,
} from '@react-native-firebase/messaging';
import PushNotification from 'react-native-push-notification';
import { AppState, Platform } from 'react-native';
import { wsService } from './ws';

// ── Types ────────────────────────────────────────────────────────────

export interface LocalNotificationPayload {
  title: string;
  message: string;
  data?: Record<string, unknown>;
}

// ── Channel ID ───────────────────────────────────────────────────────

const CHANNEL_ID = 'gang-of-none-default';

// ── Service ──────────────────────────────────────────────────────────

class NotificationService {
  private initialized = false;

  /**
   * Initialize FCM and local notification channels.
   * Call once on app start.
   */
  async initialize(): Promise<void> {
    if (this.initialized) return;
    this.initialized = true;

    // Create Android notification channel
    PushNotification.createChannel(
      {
        channelId: CHANNEL_ID,
        channelName: 'Gang of None',
        channelDescription: 'Agent orchestrator notifications',
        importance: 4, // HIGH
        vibrate: true,
      },
      () => {
        // Channel created callback — no action needed
      },
    );

    // Configure local notifications
    PushNotification.configure({
      onNotification(notification) {
        // Required callback — handled by navigation layer
        void notification;
      },
      popInitialNotification: true,
      requestPermissions: false, // We request manually via FCM
    });

    await this.requestPermission();
    this.registerBackgroundHandler();
    await this.registerToken();
  }

  /**
   * Request notification permission from the user (iOS primarily).
   */
  async requestPermission(): Promise<boolean> {
    const authStatus = await messaging().requestPermission();
    const enabled =
      authStatus === messaging.AuthorizationStatus.AUTHORIZED ||
      authStatus === messaging.AuthorizationStatus.PROVISIONAL;
    return enabled;
  }

  /**
   * Register background/quit-state message handler for FCM.
   */
  private registerBackgroundHandler(): void {
    messaging().setBackgroundMessageHandler(
      async (remoteMessage: FirebaseMessagingTypes.RemoteMessage) => {
        // Background messages trigger local notification automatically on Android.
        // On iOS we show a local notification so it appears in the tray.
        if (Platform.OS === 'ios' && remoteMessage.notification) {
          this.showLocalNotification({
            title: remoteMessage.notification.title ?? 'Gang of None',
            message: remoteMessage.notification.body ?? '',
            data: remoteMessage.data as Record<string, unknown> | undefined,
          });
        }
      },
    );
  }

  /**
   * Get FCM token and send it to the server via the WS connection.
   */
  async registerToken(): Promise<void> {
    try {
      const token = await messaging().getToken();
      if (wsService.getStatus() === 'connected') {
        wsService.sendRequest('device/registerPushToken', {
          token,
          platform: Platform.OS,
        });
      }

      // Listen for token refresh
      messaging().onTokenRefresh((newToken) => {
        if (wsService.getStatus() === 'connected') {
          wsService.sendRequest('device/registerPushToken', {
            token: newToken,
            platform: Platform.OS,
          });
        }
      });
    } catch {
      // FCM not available (e.g. simulator) — silently ignore
    }
  }

  /**
   * Trigger a local notification (used for in-app push when app is backgrounded).
   */
  showLocalNotification(payload: LocalNotificationPayload): void {
    PushNotification.localNotification({
      channelId: CHANNEL_ID,
      title: payload.title,
      message: payload.message,
      userInfo: payload.data ?? {},
      smallIcon: 'ic_notification',
      largeIcon: '',
      vibrate: true,
      playSound: true,
    });
  }

  /**
   * Check if app is in background or inactive state.
   */
  isAppInBackground(): boolean {
    return AppState.currentState !== 'active';
  }

  /**
   * Listen for foreground FCM messages.
   * Returns unsubscribe function.
   */
  onForegroundMessage(
    callback: (message: FirebaseMessagingTypes.RemoteMessage) => void,
  ): () => void {
    return messaging().onMessage(callback);
  }
}

// Export singleton
export const notificationService = new NotificationService();
