import React from 'react';
import styled from 'styled-components/native';

export type AgentStatus = 'idle' | 'busy' | 'pending' | 'initializing' | 'dead' | 'reserved';

const statusMap: Record<AgentStatus, { icon: string; colorKey: AgentStatus }> = {
  idle:         { icon: '●', colorKey: 'idle' },
  busy:         { icon: '◉', colorKey: 'busy' },
  pending:      { icon: '◎', colorKey: 'pending' },
  initializing: { icon: '○', colorKey: 'initializing' },
  dead:         { icon: '✕', colorKey: 'dead' },
  reserved:     { icon: '◆', colorKey: 'reserved' },
};

interface StatusIconProps {
  status: AgentStatus;
}

const Icon = styled.Text<{ statusColor: AgentStatus }>`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme, statusColor }) => theme.colors[statusColor]};
`;

export default function StatusIcon({ status }: StatusIconProps) {
  const { icon, colorKey } = statusMap[status] ?? statusMap.idle;
  return <Icon statusColor={colorKey}>{icon}</Icon>;
}
