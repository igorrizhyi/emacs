import React from 'react';
import { View } from 'react-native';
import AgentRow, { AgentData } from './AgentRow';

interface AgentListProps {
  agents: AgentData[];
  onAgentPress?: (agent: AgentData) => void;
}

export default function AgentList({ agents, onAgentPress }: AgentListProps) {
  return (
    <View>
      {agents.map((agent) => (
        <AgentRow key={agent.id} agent={agent} onPress={onAgentPress} />
      ))}
    </View>
  );
}
