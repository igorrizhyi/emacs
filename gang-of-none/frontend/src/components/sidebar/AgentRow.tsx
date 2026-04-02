import React, { useCallback } from 'react';
import { Alert, Pressable } from 'react-native';
import styled from 'styled-components/native';
import StatusIcon, { AgentStatus } from './StatusIcon';

export interface AgentData {
  id: string;
  role: string;
  worktreeName: string;
  status: AgentStatus;
  reserved?: boolean;
  requestId?: string;
}

export interface AgentActions {
  onReserve?: (agentId: string) => void;
  onCancel?: (agentId: string) => void;
}

interface AgentRowProps {
  agent: AgentData;
  onPress?: (agent: AgentData) => void;
  actions?: AgentActions;
}

const Row = styled.View`
  flex-direction: row;
  align-items: center;
  padding: ${({ theme }) => theme.spacing.xs}px ${({ theme }) => theme.spacing.sm}px;
`;

const Role = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreground};
  margin-left: ${({ theme }) => theme.spacing.xs}px;
`;

const WorktreeName = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.hint};
  margin-left: ${({ theme }) => theme.spacing.xs}px;
`;

const StatusText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.hint};
  margin-left: ${({ theme }) => theme.spacing.xs}px;
`;

const SubLine = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.hint};
  padding-left: ${({ theme }) => theme.spacing.lg}px;
`;

export default function AgentRow({ agent, onPress, actions }: AgentRowProps) {
  const handleLongPress = useCallback(() => {
    if (!actions) return;

    type AlertButton = { text: string; onPress?: () => void; style?: 'cancel' | 'destructive' };
    const buttons: AlertButton[] = [];

    if (actions.onReserve) {
      buttons.push({
        text: agent.reserved ? 'Unreserve' : 'Reserve',
        onPress: () => actions.onReserve!(agent.id),
      });
    }

    if (actions.onCancel && agent.status === 'busy') {
      buttons.push({
        text: 'Cancel',
        style: 'destructive',
        onPress: () => actions.onCancel!(agent.id),
      });
    }

    buttons.push({ text: 'Close', style: 'cancel' });

    if (buttons.length <= 1) return;

    Alert.alert(
      `${agent.role} · ${agent.worktreeName}`,
      `Status: ${agent.status}${agent.reserved ? ' (reserved)' : ''}`,
      buttons,
    );
  }, [agent, actions]);

  const displayStatus = agent.reserved && agent.status === 'idle'
    ? 'reserved' as AgentStatus
    : agent.status;

  return (
    <Pressable
      onPress={() => onPress?.(agent)}
      onLongPress={actions ? handleLongPress : undefined}
    >
      <Row>
        <StatusIcon status={displayStatus} />
        <Role>{agent.role}</Role>
        <WorktreeName>{agent.worktreeName}</WorktreeName>
        <StatusText>{displayStatus}</StatusText>
      </Row>
      {agent.status === 'busy' && agent.requestId && (
        <SubLine>  └ {agent.requestId}</SubLine>
      )}
    </Pressable>
  );
}
