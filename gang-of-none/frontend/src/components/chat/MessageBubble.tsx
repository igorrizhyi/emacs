import React from 'react';
import styled from 'styled-components/native';
import type { Task, TaskStatus, TaskPriority, AgentRole } from '@/store/types';

// ── Color maps ────────────────────────────────────────────────────────

const roleColors: Record<AgentRole, string> = {
  lead: '#ffb000',
  dev: '#33ff33',
  tester: '#88aaff',
  researcher: '#aa88ff',
};

const statusBadgeColors: Record<TaskStatus, string> = {
  pending: '#88aaff',
  assigned: '#ffb000',
  finished: '#33ff33',
  updated: '#cc8800',
  blocked: '#ff3333',
};

const statusLabels: Record<TaskStatus, string> = {
  pending: 'PENDING',
  assigned: 'ASSIGNED',
  finished: 'DONE',
  updated: 'UPDATED',
  blocked: 'BLOCKED',
};

// ── Styled ────────────────────────────────────────────────────────────

const Container = styled.View<{ borderColor: string }>`
  margin: ${({ theme }) => theme.spacing.xs}px 0;
  background-color: ${({ theme }) => theme.colors.surface};
  border-left-width: 3px;
  border-left-color: ${({ borderColor }) => borderColor};
  border-radius: 4px;
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
`;

const HeaderRow = styled.View`
  flex-direction: row;
  align-items: center;
  margin-bottom: ${({ theme }) => theme.spacing.xs}px;
`;

const RoleTag = styled.Text<{ tagColor: string }>`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ tagColor }) => tagColor};
  text-transform: uppercase;
`;

const PriorityTag = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: #ff3333;
  margin-left: ${({ theme }) => theme.spacing.sm}px;
`;

const Spacer = styled.View`
  flex: 1;
`;

const StatusBadge = styled.View<{ bgColor: string }>`
  background-color: ${({ bgColor }) => bgColor};
  border-radius: 3px;
  padding: 1px 5px;
`;

const StatusText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: 10px;
  color: ${({ theme }) => theme.colors.background};
`;

const Content = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreground};
`;

const Timestamp = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: 10px;
  color: ${({ theme }) => theme.colors.hint};
  margin-top: ${({ theme }) => theme.spacing.xs}px;
`;

// ── Helpers ───────────────────────────────────────────────────────────

function formatTime(iso: string): string {
  const d = new Date(iso);
  const h = d.getHours().toString().padStart(2, '0');
  const m = d.getMinutes().toString().padStart(2, '0');
  return `${h}:${m}`;
}

function truncate(text: string, maxLen: number): string {
  if (text.length <= maxLen) return text;
  return text.slice(0, maxLen - 1) + '…';
}

// ── Component ─────────────────────────────────────────────────────────

interface MessageBubbleProps {
  task: Task;
}

function MessageBubble({ task }: MessageBubbleProps) {
  const borderColor = roleColors[task.role] ?? '#555555';
  const badgeColor = statusBadgeColors[task.status] ?? '#555555';
  const isInterrupt = task.priority === 'interrupt';

  return (
    <Container borderColor={borderColor}>
      <HeaderRow>
        <RoleTag tagColor={borderColor}>{task.role}</RoleTag>
        {isInterrupt && <PriorityTag>!</PriorityTag>}
        <Spacer />
        <StatusBadge bgColor={badgeColor}>
          <StatusText>{statusLabels[task.status] ?? task.status}</StatusText>
        </StatusBadge>
      </HeaderRow>
      <Content>{truncate(task.message, 280)}</Content>
      <Timestamp>{formatTime(task.createdAt)}</Timestamp>
    </Container>
  );
}

export default React.memo(MessageBubble);
