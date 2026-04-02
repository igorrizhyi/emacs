import React, { useState, useRef, useCallback } from 'react';
import { TextInput, Pressable } from 'react-native';
import styled from 'styled-components/native';
import type { AgentRole, TaskPriority } from '@/store/types';

// ── Types ─────────────────────────────────────────────────────────────

interface TaskInputProps {
  onSubmit: (message: string, role: AgentRole, priority: TaskPriority) => void;
  disabled?: boolean;
}

const ROLES: AgentRole[] = ['dev', 'tester', 'researcher'];

const roleColors: Record<AgentRole, string> = {
  lead: '#ffb000',
  dev: '#33ff33',
  tester: '#88aaff',
  researcher: '#aa88ff',
};

// ── Styled ────────────────────────────────────────────────────────────

const Container = styled.View`
  background-color: ${({ theme }) => theme.colors.surface};
  border-top-width: 1px;
  border-top-color: ${({ theme }) => theme.colors.separator};
  padding: ${({ theme }) => theme.spacing.sm}px;
`;

const ToolbarRow = styled.View`
  flex-direction: row;
  align-items: center;
  margin-bottom: ${({ theme }) => theme.spacing.sm}px;
`;

const RoleButton = styled.View<{ selected: boolean; roleColor: string }>`
  padding: 3px 8px;
  margin-right: ${({ theme }) => theme.spacing.xs}px;
  border-width: 1px;
  border-color: ${({ selected, roleColor, theme }) =>
    selected ? roleColor : theme.colors.separator};
  border-radius: 3px;
  background-color: ${({ selected, roleColor }) =>
    selected ? roleColor + '22' : 'transparent'};
`;

const RoleButtonText = styled.Text<{ selected: boolean; roleColor: string }>`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ selected, roleColor, theme }) =>
    selected ? roleColor : theme.colors.hint};
  text-transform: uppercase;
`;

const PriorityButton = styled.View<{ active: boolean }>`
  padding: 3px 8px;
  margin-left: auto;
  border-width: 1px;
  border-color: ${({ active }) => (active ? '#ff3333' : '#555555')};
  border-radius: 3px;
  background-color: ${({ active }) => (active ? '#ff333322' : 'transparent')};
`;

const PriorityText = styled.Text<{ active: boolean }>`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ active }) => (active ? '#ff3333' : '#555555')};
`;

const InputRow = styled.View`
  flex-direction: row;
  align-items: flex-end;
`;

const Input = styled.TextInput`
  flex: 1;
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreground};
  background-color: ${({ theme }) => theme.colors.background};
  border: 1px solid ${({ theme }) => theme.colors.separator};
  padding: ${({ theme }) => theme.spacing.sm}px;
  max-height: 120px;
`;

const SendButton = styled.View<{ active: boolean }>`
  margin-left: ${({ theme }) => theme.spacing.sm}px;
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
  background-color: ${({ active, theme }) =>
    active ? theme.colors.foreground : theme.colors.separator};
`;

const SendText = styled.Text<{ active: boolean }>`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ active, theme }) =>
    active ? theme.colors.background : theme.colors.hint};
`;

// ── Component ─────────────────────────────────────────────────────────

export default function TaskInput({ onSubmit, disabled = false }: TaskInputProps) {
  const [text, setText] = useState('');
  const [role, setRole] = useState<AgentRole>('dev');
  const [priority, setPriority] = useState<TaskPriority>('normal');
  const inputRef = useRef<TextInput>(null);

  const canSend = text.trim().length > 0 && !disabled;

  const handleSend = useCallback(() => {
    if (!canSend) return;
    onSubmit(text.trim(), role, priority);
    setText('');
    setPriority('normal');
  }, [canSend, text, role, priority, onSubmit]);

  const togglePriority = useCallback(() => {
    setPriority((p) => (p === 'normal' ? 'interrupt' : 'normal'));
  }, []);

  return (
    <Container>
      <ToolbarRow>
        {ROLES.map((r) => (
          <Pressable key={r} onPress={() => setRole(r)}>
            <RoleButton selected={role === r} roleColor={roleColors[r]}>
              <RoleButtonText selected={role === r} roleColor={roleColors[r]}>
                {r}
              </RoleButtonText>
            </RoleButton>
          </Pressable>
        ))}
        <Pressable onPress={togglePriority}>
          <PriorityButton active={priority === 'interrupt'}>
            <PriorityText active={priority === 'interrupt'}>
              {priority === 'interrupt' ? '! INTERRUPT' : '  NORMAL'}
            </PriorityText>
          </PriorityButton>
        </Pressable>
      </ToolbarRow>
      <InputRow>
        <Input
          ref={inputRef}
          value={text}
          onChangeText={setText}
          onSubmitEditing={handleSend}
          placeholder="Assign task..."
          placeholderTextColor="#666666"
          multiline
          editable={!disabled}
          returnKeyType="send"
          blurOnSubmit={false}
        />
        <Pressable onPress={handleSend} disabled={!canSend}>
          <SendButton active={canSend}>
            <SendText active={canSend}>&gt;</SendText>
          </SendButton>
        </Pressable>
      </InputRow>
    </Container>
  );
}
