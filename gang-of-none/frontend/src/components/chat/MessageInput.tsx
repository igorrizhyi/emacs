import React, { useState, useRef, useCallback } from 'react';
import { TextInput, Pressable } from 'react-native';
import styled from 'styled-components/native';

interface MessageInputProps {
  onSend: (message: string) => void;
  disabled?: boolean;
}

const Container = styled.View`
  flex-direction: row;
  align-items: flex-end;
  background-color: ${({ theme }) => theme.colors.surface};
  border-top-width: 1px;
  border-top-color: ${({ theme }) => theme.colors.separator};
  padding: ${({ theme }) => theme.spacing.sm}px;
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

export default function MessageInput({ onSend, disabled = false }: MessageInputProps) {
  const [text, setText] = useState('');
  const inputRef = useRef<TextInput>(null);

  const canSend = text.trim().length > 0 && !disabled;

  const handleSend = useCallback(() => {
    if (!canSend) return;
    onSend(text.trim());
    setText('');
  }, [canSend, text, onSend]);

  const handleSubmitEditing = useCallback(() => {
    handleSend();
  }, [handleSend]);

  return (
    <Container>
      <Input
        ref={inputRef}
        value={text}
        onChangeText={setText}
        onSubmitEditing={handleSubmitEditing}
        placeholder="Message agent..."
        placeholderTextColor="#666666"
        multiline
        autoFocus
        editable={!disabled}
        returnKeyType="send"
        blurOnSubmit={false}
      />
      <Pressable onPress={handleSend} disabled={!canSend}>
        <SendButton active={canSend}>
          <SendText active={canSend}>&gt;</SendText>
        </SendButton>
      </Pressable>
    </Container>
  );
}
