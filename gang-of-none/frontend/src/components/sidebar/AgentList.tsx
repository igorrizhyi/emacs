import React from 'react';
import { View } from 'react-native';
import styled from 'styled-components/native';
import AgentRow, { AgentActions, AgentData } from './AgentRow';

interface AgentListProps {
  agents: AgentData[];
  onAgentPress?: (agent: AgentData) => void;
  actions?: AgentActions;
}

const Header = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreground};
  padding: ${({ theme }) => theme.spacing.sm}px;
`;

const Empty = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.hint};
  padding: ${({ theme }) => theme.spacing.xs}px ${({ theme }) => theme.spacing.sm}px;
`;

export default function AgentList({ agents, onAgentPress, actions }: AgentListProps) {
  return (
    <View>
      <Header>Agents</Header>
      {agents.length === 0 && <Empty>No agents</Empty>}
      {agents.map((agent) => (
        <AgentRow key={agent.id} agent={agent} onPress={onAgentPress} actions={actions} />
      ))}
    </View>
  );
}
