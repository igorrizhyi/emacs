import React, { useCallback } from 'react';
import styled from 'styled-components/native';
import { useSelector } from 'react-redux';
import { useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import type { RootDrawerParamList } from '../navigation/types';
import { useUIStore } from '../store/uiStore';
import type { RootState } from '../store';
import MessageList from '../components/chat/MessageList';
import MessageInput from '../components/chat/MessageInput';
import { websocketService } from '../services/websocket';

// ── Styled components ───────────────────────────────────────────────

const Container = styled.View`
  flex: 1;
  background-color: ${({ theme }) => theme.colors.background};
`;

const Header = styled.View`
  flex-direction: row;
  align-items: center;
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
  background-color: ${({ theme }) => theme.colors.surface};
  border-bottom-width: 1px;
  border-bottom-color: ${({ theme }) => theme.colors.separator};
`;

const AgentName = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreground};
`;

const StatusDot = styled.View<{ color: string }>`
  width: 8px;
  height: 8px;
  border-radius: 4px;
  background-color: ${({ color }) => color};
  margin-right: ${({ theme }) => theme.spacing.sm}px;
`;

const StatusLabel = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.hint};
  margin-left: ${({ theme }) => theme.spacing.sm}px;
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

// ── Helpers ─────────────────────────────────────────────────────────

const statusColors: Record<string, string> = {
  idle: '#33ff33',
  busy: '#ffb000',
  offline: '#555555',
  error: '#ff3333',
};

// ── Component ───────────────────────────────────────────────────────

type ChatRouteProp = RouteProp<RootDrawerParamList, 'Chat'>;

export default function ChatScreen() {
  const route = useRoute<ChatRouteProp>();
  const routeAgentId = route.params?.agentId;
  const zustandAgentId = useUIStore((s) => s.activeAgentId);
  // Prefer route param, fall back to Zustand active agent
  const agentId = routeAgentId ?? zustandAgentId ?? undefined;

  const agent = useSelector((state: RootState) =>
    agentId ? state.agents[agentId] : undefined,
  );
  const blocks = useSelector((state: RootState) =>
    agentId ? state.messages[agentId] ?? [] : [],
  );

  const handleSend = useCallback(
    (message: string) => {
      if (!agentId) return;
      websocketService.sendRequest('agent/sendMessage', {
        agentId,
        message,
      });
    },
    [agentId],
  );

  if (!agentId) {
    return (
      <Container>
        <EmptyContainer>
          <EmptyText>Select an agent to start chatting</EmptyText>
        </EmptyContainer>
      </Container>
    );
  }

  const agentLabel = agent
    ? `${agent.role} (${agent.worktreeName})`
    : agentId.slice(0, 8);
  const agentStatus = agent?.status ?? 'offline';

  return (
    <Container>
      <Header>
        <StatusDot color={statusColors[agentStatus] ?? '#555555'} />
        <AgentName>{agentLabel}</AgentName>
        <StatusLabel>{agentStatus}</StatusLabel>
      </Header>
      <MessageList blocks={blocks} />
      <MessageInput onSend={handleSend} disabled={agentStatus === 'offline'} />
    </Container>
  );
}
