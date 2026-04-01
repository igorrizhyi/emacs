import React, { useState, useCallback } from 'react';
import { TouchableOpacity } from 'react-native';
import styled from 'styled-components/native';

interface ThinkingBlockProps {
  content: string;
  isComplete?: boolean;
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

const Icon = styled.Text`
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  margin-right: ${({ theme }) => theme.spacing.sm}px;
`;

const HeaderText = styled.Text`
  color: ${({ theme }) => theme.colors.unchecked};
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
`;

const Chevron = styled.Text`
  color: ${({ theme }) => theme.colors.hint};
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  margin-left: auto;
`;

const Body = styled.View`
  padding: 0 ${({ theme }) => theme.spacing.md}px ${({ theme }) => theme.spacing.sm}px;
`;

const BodyText = styled.Text`
  color: ${({ theme }) => theme.colors.unchecked};
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
`;

function ThinkingBlock({ content, isComplete = false }: ThinkingBlockProps) {
  const [expanded, setExpanded] = useState(false);

  const toggle = useCallback(() => setExpanded(prev => !prev), []);

  return (
    <Container>
      <TouchableOpacity onPress={toggle} activeOpacity={0.7}>
        <Header>
          <Icon>💡</Icon>
          <HeaderText>{isComplete ? 'Thought' : 'Thinking...'}</HeaderText>
          <Chevron>{expanded ? '▼' : '▶'}</Chevron>
        </Header>
      </TouchableOpacity>
      {expanded && (
        <Body>
          <BodyText>{content}</BodyText>
        </Body>
      )}
    </Container>
  );
}

export default React.memo(ThinkingBlock);
