import React, { useCallback } from 'react';
import { ScrollView } from 'react-native';
import styled from 'styled-components/native';
import { DrawerContentComponentProps } from '@react-navigation/drawer';
import ContextBar from './ContextBar';
import AgentList from './AgentList';
import { AgentData } from './AgentRow';
import ForeignAgents from './ForeignAgents';
import PendingTasks from './PendingTasks';
import HistorySection from './HistorySection';
import { useUIStore } from '../../store/uiStore';

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

interface TeamSidebarProps extends DrawerContentComponentProps {}

export default function TeamSidebar(props: TeamSidebarProps) {
  const setActiveAgent = useUIStore((s) => s.setActiveAgent);

  const handleAgentPress = useCallback(
    (agent: AgentData) => {
      setActiveAgent(agent.id);
      props.navigation.navigate('Chat', { agentId: agent.id });
    },
    [props.navigation, setActiveAgent],
  );

  return (
    <Container>
      <ContextBar used={MOCK_CONTEXT.used} total={MOCK_CONTEXT.total} />
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
