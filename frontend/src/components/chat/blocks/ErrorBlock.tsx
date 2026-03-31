import React from 'react';
import styled from 'styled-components/native';

interface ErrorBlockProps {
  message: string;
}

const Container = styled.View`
  margin: ${({ theme }) => theme.spacing.xs}px 0;
  background-color: #2a0000;
  border-radius: 4px;
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
  border-left-width: 3px;
  border-left-color: ${({ theme }) => theme.colors.dead};
`;

const ErrorText = styled.Text`
  color: ${({ theme }) => theme.colors.dead};
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
`;

const ErrorIcon = styled.Text`
  color: ${({ theme }) => theme.colors.dead};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  margin-right: ${({ theme }) => theme.spacing.sm}px;
`;

const Row = styled.View`
  flex-direction: row;
  align-items: flex-start;
`;

function ErrorBlock({ message }: ErrorBlockProps) {
  return (
    <Container>
      <Row>
        <ErrorIcon>✗</ErrorIcon>
        <ErrorText style={{ flex: 1 }}>{message}</ErrorText>
      </Row>
    </Container>
  );
}

export default React.memo(ErrorBlock);
