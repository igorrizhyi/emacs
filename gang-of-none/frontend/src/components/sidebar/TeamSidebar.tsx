import React, { useCallback, useMemo } from 'react';
import { TouchableOpacity } from 'react-native';
import styled from 'styled-components/native';
import { DrawerContentComponentProps } from '@react-navigation/drawer';
import ContextBar from './ContextBar';
import AgentList from './AgentList';
import { AgentActions, AgentData } from './AgentRow';
import PendingTasks from './PendingTasks';
import { useAppSelector } from '../../store';
import { useUIStore } from '../../store/uiStore';
import { selectUnreadCount } from '../../store/slices/notificationsSlice';
import { reserveAgent, cancelAgent } from '../../services/api';
import type { AgentStatus as StatusIconStatus } from './StatusIcon';

// ── Styled ──────────────────────────────────────────────────────────────

const Container = styled.ScrollView`
  flex: 1;
  background-color: ${({ theme }) => theme.colors.background};
`;

const Separator = styled.View`
  height: 1px;
  background-color: ${({ theme }) => theme.colors.separator};
  margin: ${({ theme }) => theme.spacing.xs}px 0;
`;

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

// ── Helpers ─────────────────────────────────────────────────────────────

// TODO: Wire context window data from WebSocket once available
const PLACEHOLDER_CONTEXT = { used: 0, total: 80000 };

interface TeamSidebarProps extends DrawerContentComponentProps {}

export default function TeamSidebar(props: TeamSidebarProps) {
  const setActiveAgent = useUIStore((s) => s.setActiveAgent);
  const unreadCount = useAppSelector(selectUnreadCount);

  // Real agent data from Redux store
  const agentsMap = useAppSelector((s) => s.agents);
  const agents: AgentData[] = useMemo(
    () =>
      Object.values(agentsMap).map((a) => ({
        id: a.id,
        role: a.role,
        worktreeName: a.worktreeName ?? a.bufferName ?? a.id,
        status: a.status as StatusIconStatus,
        reserved: a.reserved,
        requestId: a.currentTaskId ?? undefined,
      })),
    [agentsMap],
  );

  // Pending tasks from Redux store
  const tasksMap = useAppSelector((s) => s.tasks.byId);
  const pendingTasks = useMemo(
    () =>
      Object.values(tasksMap)
        .filter((t) => t.status === 'pending')
        .map((t) => ({ id: t.id, role: t.role, message: t.message })),
    [tasksMap],
  );

  // Agent long-press actions — call REST API directly
  const agentActions: AgentActions = useMemo(
    () => ({
      onReserve: (agentId: string) => {
        reserveAgent(agentId).catch(() => {
          // TODO: show error toast
        });
      },
      onCancel: (agentId: string) => {
        cancelAgent(agentId).catch(() => {
          // TODO: show error toast
        });
      },
    }),
    [],
  );

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
      <ContextBar used={PLACEHOLDER_CONTEXT.used} total={PLACEHOLDER_CONTEXT.total} />
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
      <AgentList agents={agents} onAgentPress={handleAgentPress} actions={agentActions} />
      <Separator />
      <PendingTasks tasks={pendingTasks} />
      <Separator />
    </Container>
  );
}
