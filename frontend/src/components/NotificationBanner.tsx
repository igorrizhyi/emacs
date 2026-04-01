import React, { useEffect, useRef, useCallback } from 'react';
import { TouchableOpacity } from 'react-native';
import styled from 'styled-components/native';
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withTiming,
  withDelay,
  runOnJS,
} from 'react-native-reanimated';
import { useSelector, useDispatch } from 'react-redux';
import { useNavigation } from '@react-navigation/native';
import type { DrawerNavigationProp } from '@react-navigation/drawer';
import { theme } from '../theme';
import {
  selectNotifications,
  markRead,
  type AppNotification,
} from '../store/slices/notificationsSlice';
import type { RootDrawerParamList } from '../navigation/types';

// ── Constants ────────────────────────────────────────────────────────

const DISPLAY_DURATION = 3500;
const SLIDE_DURATION = 300;
const BANNER_HEIGHT = 72;

// ── Styled components ────────────────────────────────────────────────

const BannerContainer = styled(Animated.View)`
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  z-index: 1000;
`;

const BannerContent = styled.View`
  margin: ${theme.spacing.sm}px;
  padding: ${theme.spacing.sm}px ${theme.spacing.md}px;
  background-color: ${theme.colors.surface};
  border-width: 1px;
  border-color: ${theme.colors.foreground};
  border-radius: 4px;
`;

const Title = styled.Text`
  font-family: ${theme.fonts.monoBold};
  font-size: ${theme.sizes.fontSizeSmall}px;
  color: ${theme.colors.foreground};
`;

const Message = styled.Text`
  font-family: ${theme.fonts.mono};
  font-size: ${theme.sizes.fontSizeSmall}px;
  color: ${theme.colors.hint};
  margin-top: 2px;
` as unknown as typeof Animated.Text;

// ── Component ────────────────────────────────────────────────────────

export default function NotificationBanner() {
  const dispatch = useDispatch();
  const navigation =
    useNavigation<DrawerNavigationProp<RootDrawerParamList>>();
  const notifications = useSelector(selectNotifications);
  const lastSeenId = useRef<string | null>(null);

  const translateY = useSharedValue(-BANNER_HEIGHT);
  const currentNotif = useRef<AppNotification | null>(null);

  const animatedStyle = useAnimatedStyle(() => ({
    transform: [{ translateY: translateY.value }],
  }));

  const hide = useCallback(() => {
    currentNotif.current = null;
  }, []);

  // Show banner when a new notification arrives
  useEffect(() => {
    if (notifications.length === 0) return;
    const latest = notifications[0];
    if (latest.id === lastSeenId.current) return;

    lastSeenId.current = latest.id;
    currentNotif.current = latest;

    // Slide in
    translateY.value = withTiming(0, { duration: SLIDE_DURATION });
    // Auto-hide after delay
    translateY.value = withDelay(
      DISPLAY_DURATION,
      withTiming(-BANNER_HEIGHT, { duration: SLIDE_DURATION }, () => {
        runOnJS(hide)();
      }),
    );
  }, [notifications, translateY, hide]);

  const handlePress = useCallback(() => {
    const notif = currentNotif.current;
    if (!notif) return;

    dispatch(markRead(notif.id));
    translateY.value = withTiming(-BANNER_HEIGHT, {
      duration: SLIDE_DURATION,
    });

    // Navigate based on notification type
    if (notif.type === 'approval_request') {
      // Open approval sheet via zustand
      try {
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        const { useUIStore } = require('../store/uiStore') as {
          useUIStore: {
            getState: () => { setApprovalVisible: (v: boolean) => void };
          };
        };
        useUIStore.getState().setApprovalVisible(true);
      } catch {
        // Approval UI not available
      }
    } else if (notif.type === 'task_update' && notif.data?.agentId) {
      navigation.navigate('Chat', {
        agentId: notif.data.agentId as string,
      });
    } else {
      navigation.navigate('Notifications' as keyof RootDrawerParamList);
    }
  }, [dispatch, navigation, translateY]);

  return (
    <BannerContainer style={animatedStyle}>
      <TouchableOpacity activeOpacity={0.8} onPress={handlePress}>
        <BannerContent>
          <Title numberOfLines={1}>
            {currentNotif.current?.title ?? ''}
          </Title>
          <Message numberOfLines={1}>
            {currentNotif.current?.message ?? ''}
          </Message>
        </BannerContent>
      </TouchableOpacity>
    </BannerContainer>
  );
}
