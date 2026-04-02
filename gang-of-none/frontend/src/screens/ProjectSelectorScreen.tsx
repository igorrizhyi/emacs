import React, { useCallback } from 'react';
import { FlatList, Pressable, ListRenderItem } from 'react-native';
import styled from 'styled-components/native';
import { useSelector } from 'react-redux';
import { useNavigation } from '@react-navigation/native';
import type { DrawerNavigationProp } from '@react-navigation/drawer';
import type { RootState } from '../store';
import type { Session } from '../store/types';
import type { RootDrawerParamList } from '../navigation/types';
import { useUIStore } from '../store/uiStore';

// ── Styled components ───────────────────────────────────────────────

const Container = styled.View`
  flex: 1;
  background-color: ${({ theme }) => theme.colors.background};
  padding: ${({ theme }) => theme.spacing.md}px;
`;

const Title = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeLarge}px;
  color: ${({ theme }) => theme.colors.foreground};
  margin-bottom: ${({ theme }) => theme.spacing.md}px;
`;

const Card = styled.View`
  background-color: ${({ theme }) => theme.colors.surface};
  border: 1px solid ${({ theme }) => theme.colors.separator};
  padding: ${({ theme }) => theme.spacing.md}px;
  margin-bottom: ${({ theme }) => theme.spacing.sm}px;
`;

const CardHeader = styled.View`
  flex-direction: row;
  align-items: center;
`;

const ProjectName = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreground};
  flex-shrink: 1;
`;

const SessionId = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.hint};
  margin-top: ${({ theme }) => theme.spacing.xs}px;
`;

const CardMeta = styled.View`
  flex-direction: row;
  align-items: center;
  margin-top: ${({ theme }) => theme.spacing.sm}px;
`;

const Badge = styled.View`
  background-color: ${({ theme }) => theme.colors.foreground};
  padding: 2px 6px;
  margin-right: ${({ theme }) => theme.spacing.sm}px;
`;

const BadgeText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.background};
`;

const Timestamp = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.hint};
`;

const StatusDot = styled.View<{ active: boolean }>`
  width: 8px;
  height: 8px;
  border-radius: 4px;
  background-color: ${({ active, theme }) =>
    active ? theme.colors.idle : theme.colors.hint};
  margin-right: ${({ theme }) => theme.spacing.sm}px;
`;

const EmptyContainer = styled.View`
  flex: 1;
  align-items: center;
  justify-content: center;
`;

const EmptyText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.hint};
`;

const NewButton = styled.View`
  background-color: ${({ theme }) => theme.colors.surface};
  border: 1px solid ${({ theme }) => theme.colors.foreground};
  padding: ${({ theme }) => theme.spacing.md}px;
  align-items: center;
  margin-top: ${({ theme }) => theme.spacing.sm}px;
`;

const NewButtonText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreground};
`;

// ── Helpers ─────────────────────────────────────────────────────────

function projectName(projectRoot: string): string {
  const segments = projectRoot.replace(/\/+$/, '').split('/');
  return segments[segments.length - 1] || projectRoot;
}

function shortId(id: string): string {
  return id.slice(0, 8);
}

function formatTime(iso: string): string {
  try {
    const d = new Date(iso);
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  } catch {
    return iso;
  }
}

// ── Component ───────────────────────────────────────────────────────

type NavProp = DrawerNavigationProp<RootDrawerParamList>;

export default function ProjectSelectorScreen() {
  const sessions = useSelector((state: RootState) => state.sessions.byId);
  const sessionList = Object.values(sessions);
  const navigation = useNavigation<NavProp>();
  const setActiveSession = useUIStore((s) => s.setActiveSession);

  const handleSelect = useCallback(
    (session: Session) => {
      setActiveSession(session.id);
      navigation.navigate('Chat');
    },
    [navigation, setActiveSession],
  );

  const renderItem: ListRenderItem<Session> = useCallback(
    ({ item }) => {
      const isActive = item.agentIds.length > 0;
      return (
        <Pressable onPress={() => handleSelect(item)}>
          <Card>
            <CardHeader>
              <StatusDot active={isActive} />
              <ProjectName numberOfLines={1}>
                {projectName(item.projectRoot)}
              </ProjectName>
            </CardHeader>
            <SessionId>{shortId(item.id)}</SessionId>
            <CardMeta>
              <Badge>
                <BadgeText>{item.agentIds.length} agents</BadgeText>
              </Badge>
              <Timestamp>{formatTime(item.createdAt)}</Timestamp>
            </CardMeta>
          </Card>
        </Pressable>
      );
    },
    [handleSelect],
  );

  const keyExtractor = useCallback((item: Session) => item.id, []);

  if (sessionList.length === 0) {
    return (
      <Container>
        <Title>Sessions</Title>
        <EmptyContainer>
          <EmptyText>No active sessions</EmptyText>
        </EmptyContainer>
        <Pressable>
          <NewButton>
            <NewButtonText>+ New Session</NewButtonText>
          </NewButton>
        </Pressable>
      </Container>
    );
  }

  return (
    <Container>
      <Title>Sessions</Title>
      <FlatList
        data={sessionList}
        renderItem={renderItem}
        keyExtractor={keyExtractor}
      />
      <Pressable>
        <NewButton>
          <NewButtonText>+ New Session</NewButtonText>
        </NewButton>
      </Pressable>
    </Container>
  );
}
