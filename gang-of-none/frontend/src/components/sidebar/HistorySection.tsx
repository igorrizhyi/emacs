import React, { useState, useCallback } from 'react';
import { View, Pressable } from 'react-native';
import styled from 'styled-components/native';

type TaskStatus = 'finished' | 'blocked' | 'in-progress' | 'pending';

interface HistoryTask {
  id: string;
  label: string;
  role: string;
  status: TaskStatus;
}

interface HistorySession {
  id: string;
  date: string;
  shortId: string;
  tasks: HistoryTask[];
}

interface HistorySectionProps {
  sessions: HistorySession[];
}

const Header = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.historyHeader};
  padding: ${({ theme }) => theme.spacing.sm}px;
`;

const SessionHeader = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.historySession};
  padding: ${({ theme }) => theme.spacing.xs}px ${({ theme }) => theme.spacing.sm}px;
`;

const TaskRow = styled.View`
  flex-direction: row;
  padding: 2px ${({ theme }) => theme.spacing.sm}px;
  padding-left: ${({ theme }) => theme.spacing.md}px;
`;

const TaskLabel = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.hint};
  margin-left: ${({ theme }) => theme.spacing.xs}px;
  flex: 1;
`;

const taskStatusMap: Record<TaskStatus, { icon: string; color: string }> = {
  finished:      { icon: '✓', color: '#33ff33' },
  blocked:       { icon: '✗', color: '#ff3333' },
  'in-progress': { icon: '●', color: '#ffb000' },
  pending:       { icon: '○', color: '#cc8800' },
};

const StatusChar = styled.Text<{ statusColor: string }>`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ statusColor }) => statusColor};
`;

const RoleTag = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.hint};
  margin-left: ${({ theme }) => theme.spacing.xs}px;
`;

const AUTO_EXPAND_COUNT = 3;

export default function HistorySection({ sessions }: HistorySectionProps) {
  const [expanded, setExpanded] = useState<Set<string>>(() => {
    const initial = new Set<string>();
    sessions.slice(0, AUTO_EXPAND_COUNT).forEach((s) => initial.add(s.id));
    return initial;
  });

  const toggleSession = useCallback((id: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(id)) {
        next.delete(id);
      } else {
        next.add(id);
      }
      return next;
    });
  }, []);

  if (sessions.length === 0) return null;

  return (
    <View>
      <Header>── History ──</Header>
      {sessions.map((session) => {
        const isExpanded = expanded.has(session.id);
        return (
          <View key={session.id}>
            <Pressable onPress={() => toggleSession(session.id)}>
              <SessionHeader>
                {isExpanded ? '▾' : '▸'} {session.date} {session.shortId}
              </SessionHeader>
            </Pressable>
            {isExpanded &&
              session.tasks.map((task) => {
                const { icon, color } = taskStatusMap[task.status] ?? taskStatusMap.pending;
                return (
                  <TaskRow key={task.id}>
                    <StatusChar statusColor={color}>{icon}</StatusChar>
                    <TaskLabel numberOfLines={1}>{task.label}</TaskLabel>
                    <RoleTag>[{task.role}]</RoleTag>
                  </TaskRow>
                );
              })}
          </View>
        );
      })}
    </View>
  );
}
