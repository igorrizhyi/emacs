import React from 'react';
import { View } from 'react-native';
import styled from 'styled-components/native';

interface PendingTask {
  id: string;
  role: string;
  message: string;
}

interface PendingTasksProps {
  tasks: PendingTask[];
}

const Header = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreground};
  padding: ${({ theme }) => theme.spacing.sm}px;
`;

const TaskRow = styled.View`
  flex-direction: row;
  padding: ${({ theme }) => theme.spacing.xs}px ${({ theme }) => theme.spacing.sm}px;
`;

const RoleTag = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.foreground};
`;

const Message = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.hint};
  margin-left: ${({ theme }) => theme.spacing.xs}px;
  flex: 1;
`;

export default function PendingTasks({ tasks }: PendingTasksProps) {
  if (tasks.length === 0) return null;

  return (
    <View>
      <Header>Pending Tasks</Header>
      {tasks.map((task) => (
        <TaskRow key={task.id}>
          <RoleTag>[{task.role}]</RoleTag>
          <Message numberOfLines={1}>{task.message}</Message>
        </TaskRow>
      ))}
    </View>
  );
}
