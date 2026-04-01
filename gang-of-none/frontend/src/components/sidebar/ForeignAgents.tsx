import React from 'react';
import { View } from 'react-native';
import styled from 'styled-components/native';
import StatusIcon, { AgentStatus } from './StatusIcon';

interface ForeignAgent {
  role: string;
  worktreeName: string;
  status: AgentStatus;
}

interface Peer {
  pid: number;
  projectName: string;
  hostname: string;
  agents: ForeignAgent[];
}

interface ForeignAgentsProps {
  peers: Peer[];
}

const Header = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreground};
  padding: ${({ theme }) => theme.spacing.sm}px;
`;

const PeerLine = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.hint};
  padding-left: ${({ theme }) => theme.spacing.sm}px;
`;

const AgentLine = styled.View`
  flex-direction: row;
  align-items: center;
  padding: ${({ theme }) => theme.spacing.xs}px ${({ theme }) => theme.spacing.sm}px;
  padding-left: ${({ theme }) => theme.spacing.md}px;
`;

const ForeignText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoItalic};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreignAgent};
  margin-left: ${({ theme }) => theme.spacing.xs}px;
`;

export default function ForeignAgents({ peers }: ForeignAgentsProps) {
  if (peers.length === 0) return null;

  return (
    <View>
      <Header> Namespace Peers</Header>
      {peers.map((peer) => (
        <View key={peer.pid}>
          <PeerLine>  {peer.projectName} · {peer.hostname}</PeerLine>
          {peer.agents.map((agent, i) => (
            <AgentLine key={`${peer.pid}-${i}`}>
              <StatusIcon status={agent.status} />
              <ForeignText>{agent.role} {agent.worktreeName}</ForeignText>
            </AgentLine>
          ))}
        </View>
      ))}
    </View>
  );
}
