import React, { useCallback } from 'react';
import { FlatList, TouchableOpacity } from 'react-native';
import styled from 'styled-components/native';
import { useSelector, useDispatch } from 'react-redux';
import { useNavigation } from '@react-navigation/native';
import type { DrawerNavigationProp } from '@react-navigation/drawer';
import { theme } from '../theme';
import {
  selectNotifications,
  markRead,
  markAllRead,
  type AppNotification,
} from '../store/slices/notificationsSlice';
import type { RootDrawerParamList } from '../navigation/types';

// ── Styled components ────────────────────────────────────────────────

const Container = styled.View`
  flex: 1;
  background-color: ${theme.colors.background};
`;

const HeaderBar = styled.View`
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  padding: ${theme.spacing.sm}px ${theme.spacing.md}px;
  background-color: ${theme.colors.surface};
  border-bottom-width: 1px;
  border-bottom-color: ${theme.colors.separator};
`;

const HeaderTitle = styled.Text`
  font-family: ${theme.fonts.monoBold};
  font-size: ${theme.sizes.fontSize}px;
  color: ${theme.colors.foreground};
`;

const MarkAllButton = styled.Text`
  font-family: ${theme.fonts.mono};
  font-size: ${theme.sizes.fontSizeSmall}px;
  color: ${theme.colors.foreground};
`;

const NotificationRow = styled.View<{ unread: boolean }>`
  padding: ${theme.spacing.sm}px ${theme.spacing.md}px;
  background-color: ${({ unread }) =>
    unread ? theme.colors.itemHighlight : 'transparent'};
  border-bottom-width: 1px;
  border-bottom-color: ${theme.colors.separator};
`;

const RowHeader = styled.View`
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
`;

const NotifTitle = styled.Text`
  font-family: ${theme.fonts.monoBold};
  font-size: ${theme.sizes.fontSizeSmall}px;
  color: ${theme.colors.foreground};
  flex: 1;
`;

const TypeBadge = styled.Text<{ notifType: string }>`
  font-family: ${theme.fonts.mono};
  font-size: 10px;
  color: ${({ notifType }) => {
    switch (notifType) {
      case 'approval_request':
        return theme.colors.barCritical;
      case 'task_update':
        return theme.colors.busy;
      case 'agent_status':
        return theme.colors.idle;
      default:
        return theme.colors.hint;
    }
  }};
  margin-left: ${theme.spacing.sm}px;
`;

const NotifMessage = styled.Text`
  font-family: ${theme.fonts.mono};
  font-size: ${theme.sizes.fontSizeSmall}px;
  color: ${theme.colors.hint};
  margin-top: 2px;
`;

const Timestamp = styled.Text`
  font-family: ${theme.fonts.mono};
  font-size: 10px;
  color: ${theme.colors.hint};
  margin-top: 2px;
`;

const EmptyContainer = styled.View`
  flex: 1;
  align-items: center;
  justify-content: center;
`;

const EmptyText = styled.Text`
  font-family: ${theme.fonts.mono};
  font-size: ${theme.sizes.fontSize}px;
  color: ${theme.colors.hint};
`;

const UnreadDot = styled.View`
  width: 6px;
  height: 6px;
  border-radius: 3px;
  background-color: ${theme.colors.foreground};
  margin-right: ${theme.spacing.sm}px;
`;

// ── Helpers ──────────────────────────────────────────────────────────

function formatTime(ts: number): string {
  const d = new Date(ts);
  const now = new Date();
  const diffMs = now.getTime() - d.getTime();
  const diffMin = Math.floor(diffMs / 60000);

  if (diffMin < 1) return 'just now';
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHr = Math.floor(diffMin / 60);
  if (diffHr < 24) return `${diffHr}h ago`;
  return d.toLocaleDateString();
}

function typeLabel(type: string): string {
  switch (type) {
    case 'task_update':
      return 'TASK';
    case 'approval_request':
      return 'APPROVAL';
    case 'agent_status':
      return 'AGENT';
    default:
      return 'SYSTEM';
  }
}

// ── Component ────────────────────────────────────────────────────────

export default function NotificationsScreen() {
  const dispatch = useDispatch();
  const navigation =
    useNavigation<DrawerNavigationProp<RootDrawerParamList>>();
  const notifications = useSelector(selectNotifications);

  const handlePress = useCallback(
    (notif: AppNotification) => {
      if (!notif.read) {
        dispatch(markRead(notif.id));
      }

      // Navigate based on type
      if (notif.type === 'approval_request') {
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
      }
    },
    [dispatch, navigation],
  );

  const handleMarkAllRead = useCallback(() => {
    dispatch(markAllRead());
  }, [dispatch]);

  const renderItem = useCallback(
    ({ item }: { item: AppNotification }) => (
      <TouchableOpacity
        activeOpacity={0.7}
        onPress={() => handlePress(item)}
      >
        <NotificationRow unread={!item.read}>
          <RowHeader>
            {!item.read && <UnreadDot />}
            <NotifTitle numberOfLines={1}>{item.title}</NotifTitle>
            <TypeBadge notifType={item.type}>
              {typeLabel(item.type)}
            </TypeBadge>
          </RowHeader>
          <NotifMessage numberOfLines={2}>{item.message}</NotifMessage>
          <Timestamp>{formatTime(item.timestamp)}</Timestamp>
        </NotificationRow>
      </TouchableOpacity>
    ),
    [handlePress],
  );

  const keyExtractor = useCallback((item: AppNotification) => item.id, []);

  if (notifications.length === 0) {
    return (
      <Container>
        <HeaderBar>
          <HeaderTitle>Notifications</HeaderTitle>
        </HeaderBar>
        <EmptyContainer>
          <EmptyText>No notifications</EmptyText>
        </EmptyContainer>
      </Container>
    );
  }

  return (
    <Container>
      <HeaderBar>
        <HeaderTitle>Notifications</HeaderTitle>
        <TouchableOpacity onPress={handleMarkAllRead}>
          <MarkAllButton>Mark all read</MarkAllButton>
        </TouchableOpacity>
      </HeaderBar>
      <FlatList
        data={notifications}
        renderItem={renderItem}
        keyExtractor={keyExtractor}
      />
    </Container>
  );
}
