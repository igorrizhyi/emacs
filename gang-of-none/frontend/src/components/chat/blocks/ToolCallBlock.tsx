import React, { useState, useCallback } from 'react';
import { TouchableOpacity, ActivityIndicator } from 'react-native';
import styled from 'styled-components/native';

type ToolCallStatus = 'pending' | 'running' | 'success' | 'failed';

interface ToolCallBlockProps {
  toolName: string;
  status: ToolCallStatus;
  command?: string;
  output?: string;
}

const Container = styled.View`
  margin: ${({ theme }) => theme.spacing.xs}px 0;
  background-color: ${({ theme }) => theme.colors.surface};
  border-radius: 4px;
  overflow: hidden;
`;

const Header = styled.View`
  flex-direction: row;
  align-items: center;
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
`;

const StatusIcon = styled.Text`
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  margin-right: ${({ theme }) => theme.spacing.sm}px;
`;

const ToolName = styled.Text`
  color: ${({ theme }) => theme.colors.foreground};
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  flex: 1;
`;

const Chevron = styled.Text`
  color: ${({ theme }) => theme.colors.hint};
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
`;

const Body = styled.View`
  padding: 0 ${({ theme }) => theme.spacing.md}px ${({ theme }) => theme.spacing.sm}px;
`;

const OutputText = styled.Text`
  color: ${({ theme }) => theme.colors.unchecked};
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
`;

const statusIcons: Record<ToolCallStatus, string> = {
  pending: '⏳',
  running: '', // uses ActivityIndicator
  success: '✓',
  failed: '✗',
};

const statusColors: Record<ToolCallStatus, string> = {
  pending: '#88aaff',
  running: '#ffb000',
  success: '#33ff33',
  failed: '#ff3333',
};

function StatusDisplay({ status }: { status: ToolCallStatus }) {
  if (status === 'running') {
    return (
      <ActivityIndicator
        size="small"
        color={statusColors.running}
        style={{ marginRight: 8 }}
      />
    );
  }
  return (
    <StatusIcon style={{ color: statusColors[status] }}>
      {statusIcons[status]}
    </StatusIcon>
  );
}

function ToolCallBlock({ toolName, status, command, output }: ToolCallBlockProps) {
  const [expanded, setExpanded] = useState(false);

  const toggle = useCallback(() => setExpanded(prev => !prev), []);

  const hasBody = Boolean(command || output);

  return (
    <Container>
      <TouchableOpacity onPress={toggle} activeOpacity={0.7} disabled={!hasBody}>
        <Header>
          <StatusDisplay status={status} />
          <ToolName>{toolName}</ToolName>
          {hasBody && <Chevron>{expanded ? '▼' : '▶'}</Chevron>}
        </Header>
      </TouchableOpacity>
      {expanded && hasBody && (
        <Body>
          {command ? <OutputText>{`$ ${command}`}</OutputText> : null}
          {output ? <OutputText>{output}</OutputText> : null}
        </Body>
      )}
    </Container>
  );
}

export default React.memo(ToolCallBlock);
