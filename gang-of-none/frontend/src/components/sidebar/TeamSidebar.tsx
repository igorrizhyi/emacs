import React, { useCallback } from 'react';
import { ScrollView, TouchableOpacity } from 'react-native';
import styled from 'styled-components/native';
import { DrawerContentComponentProps } from '@react-navigation/drawer';
import { useSelector } from 'react-redux';
import ContextBar from './ContextBar';
import AgentList from './AgentList';
import { AgentData } from './AgentRow';
import ForeignAgents from './ForeignAgents';
import PendingTasks from './PendingTasks';
import HistorySection from './HistorySection';
import { useUIStore } from '../../store/uiStore';
import { selectUnreadCount } from '../../store/slices/notificationsSlice';

const Container = styled.ScrollView`
  flex: 1;
  background-color: ${({ theme }) => theme.colors.background};
`;

const Separator = styled.View`
  height: 1px;
  background-color: ${({ theme }) => theme.colors.separator};
  margin: ${({ theme }) => theme.spacing.xs}px 0;
`;

// TODO: Wire to real data from store/websocket
const MOCK_CONTEXT = { used: 41000, total: 80000 };

const MOCK_AGENTS: AgentData[] = [
  { id: '1', role: 'dev', worktreeName: 'gracious-cori', status: 'busy', requestId: 'fe-team-sidebar' },
  { id: '2', role: 'dev', worktreeName: 'clever-turing', status: 'idle' },
  { id: '3', role: 'tester', worktreeName: 'brave-hopper', status: 'pending' },
];

const MOCK_PEERS = [
  {
    pid: 12345,
    projectName: 'backend',
    hostname: 'dev-01',
    agents: [
      { role: 'dev', worktreeName: 'swift-knuth', status: 'busy' as const },
    ],
  },
];

const MOCK_PENDING = [
  { id: 't1', role: 'dev', message: 'Implement WebSocket reconnection logic' },
];

const MOCK_HISTORY = [
  {
    id: 's1',
    date: '2026-03-31',
    shortId: 'aa452',
    tasks: [
      { id: 'h1', label: 'React Native scaffolding', role: 'dev', status: 'finished' as const },
      { id: 'h2', label: 'Theme and navigation', role: 'dev', status: 'finished' as const },
      { id: 'h3', label: 'Team sidebar', role: 'dev', status: 'in-progress' as const },
    ],
  },
];

const NotifRow = styled.View`
  flex-direction: row;
  align-items: center;
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
`;

const NotifLabel = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.foreground};
`;

const Badge = styled.View`
  background-color: ${({ theme }) => theme.colors.barCritical};
  border-radius: 8px;
  min-width: 16px;
  height: 16px;
  align-items: center;
  justify-content: center;
  margin-left: ${({ theme }) => theme.spacing.sm}px;
  padding-horizontal: 4px;
`;

const BadgeText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: 10px;
  color: #ffffff;
`;

interface TeamSidebarProps extends DrawerContentComponentProps {}

export default function TeamSidebar(props: TeamSidebarProps) {
  const setActiveAgent = useUIStore((s) => s.setActiveAgent);
  const unreadCount = useSelector(selectUnreadCount);

  const handleAgentPress = useCallback(
    (agent: AgentData) => {
      setActiveAgent(agent.id);
      props.navigation.navigate('Chat', { agentId: agent.id });
    },
    [props.navigation, setActiveAgent],
  );

  const handleNotificationsPress = useCallback(() => {
    props.navigation.navigate('Notifications');
  }, [props.navigation]);

  return (
    <Container>
      <ContextBar used={MOCK_CONTEXT.used} total={MOCK_CONTEXT.total} />
      <Separator />
      <TouchableOpacity onPress={handleNotificationsPress}>
        <NotifRow>
          <NotifLabel>Notifications</NotifLabel>
          {unreadCount > 0 && (
            <Badge>
              <BadgeText>{unreadCount > 99 ? '99+' : unreadCount}</BadgeText>
            </Badge>
          )}
        </NotifRow>
      </TouchableOpacity>
      <Separator />
      <AgentList agents={MOCK_AGENTS} onAgentPress={handleAgentPress} />
      <Separator />
      <ForeignAgents peers={MOCK_PEERS} />
      <Separator />
      <PendingTasks tasks={MOCK_PENDING} />
      <Separator />
      <HistorySection sessions={MOCK_HISTORY} />
    </Container>
  );
}
