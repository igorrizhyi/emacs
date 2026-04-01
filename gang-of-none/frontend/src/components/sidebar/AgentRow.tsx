import React from 'react';
import { Pressable } from 'react-native';
import styled from 'styled-components/native';
import StatusIcon, { AgentStatus } from './StatusIcon';

export interface AgentData {
  id: string;
  role: string;
  worktreeName: string;
  status: AgentStatus;
  requestId?: string;
}

interface AgentRowProps {
  agent: AgentData;
  onPress?: (agent: AgentData) => void;
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

export default function AgentRow({ agent, onPress }: AgentRowProps) {
  return (
    <Pressable onPress={() => onPress?.(agent)}>
      <Row>
        <StatusIcon status={agent.status} />
        <Role>{agent.role}</Role>
        <WorktreeName>{agent.worktreeName}</WorktreeName>
        <StatusText>{agent.status}</StatusText>
      </Row>
      {agent.status === 'busy' && agent.requestId && (
        <SubLine>  └ {agent.requestId}</SubLine>
      )}
    </Pressable>
  );
}
