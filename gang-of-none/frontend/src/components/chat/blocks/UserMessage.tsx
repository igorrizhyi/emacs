import React from 'react';
import styled from 'styled-components/native';

interface UserMessageProps {
  content: string;
}

const Container = styled.View`
  background-color: #2a2200;
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
  margin: ${({ theme }) => theme.spacing.xs}px 0;
  border-radius: 4px;
`;

const MessageText = styled.Text`
  color: ${({ theme }) => theme.colors.foreground};
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
`;

function UserMessage({ content }: UserMessageProps) {
  return (
    <Container>
      <MessageText>{content}</MessageText>
    </Container>
  );
}

export default React.memo(UserMessage);
