import React, { useCallback, useEffect, useMemo, useRef } from 'react';
import { FlashList } from '@shopify/flash-list';
import styled from 'styled-components/native';
import { useAppSelector } from '@/store';
import { MessageBubble, TaskInput } from '@/components/chat';
import { createTask } from '@/services/api';
import type { Task, AgentRole, TaskPriority } from '@/store/types';

// ── Styled ────────────────────────────────────────────────────────────

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

const SessionLabel = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.hint};
  margin-right: ${({ theme }) => theme.spacing.sm}px;
`;

const SessionId = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreground};
  flex-shrink: 1;
`;

const NoSession = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.hint};
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

// ── Component ─────────────────────────────────────────────────────────

export default function ChatScreen() {
  const activeSessionId = useAppSelector((s) => s.sessions.activeSessionId);
  const tasksById = useAppSelector((s) => s.tasks.byId);
  const listRef = useRef<FlashList<Task>>(null);

  const tasks = useMemo(() => {
    return Object.values(tasksById).sort(
      (a, b) =>
        new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime(),
    );
  }, [tasksById]);

  // Auto-scroll to bottom when new tasks arrive
  const prevCount = useRef(tasks.length);
  useEffect(() => {
    if (tasks.length > prevCount.current && tasks.length > 0) {
      // Small delay to let FlashList finish layout
      setTimeout(() => {
        listRef.current?.scrollToEnd({ animated: true });
      }, 100);
    }
    prevCount.current = tasks.length;
  }, [tasks.length]);

  const handleSubmit = useCallback(
    async (message: string, role: AgentRole, priority: TaskPriority) => {
      if (!activeSessionId) return;
      try {
        await createTask(activeSessionId, {
          role: role as unknown as import('@/services/types').AgentRole,
          message,
          priority: priority as unknown as import('@/services/types').TaskPriority,
        });
      } catch {
        // TODO: surface error to user via toast/notification
      }
    },
    [activeSessionId],
  );

  const renderItem = useCallback(
    ({ item }: { item: Task }) => <MessageBubble task={item} />,
    [],
  );

  const keyExtractor = useCallback((item: Task) => item.id, []);

  return (
    <Container>
      <Header>
        <SessionLabel>SESSION</SessionLabel>
        {activeSessionId ? (
          <SessionId numberOfLines={1}>{activeSessionId}</SessionId>
        ) : (
          <NoSession>No active session</NoSession>
        )}
      </Header>
      {tasks.length === 0 ? (
        <EmptyContainer>
          <EmptyText>No tasks yet</EmptyText>
        </EmptyContainer>
      ) : (
        <FlashList
          ref={listRef}
          data={tasks}
          renderItem={renderItem}
          keyExtractor={keyExtractor}
          estimatedItemSize={100}
          contentContainerStyle={{ paddingHorizontal: 8, paddingVertical: 4 }}
        />
      )}
      <TaskInput onSubmit={handleSubmit} disabled={!activeSessionId} />
    </Container>
  );
}
