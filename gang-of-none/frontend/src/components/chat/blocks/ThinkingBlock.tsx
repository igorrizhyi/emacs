import React, { useState, useCallback } from 'react';
import { TouchableOpacity } from 'react-native';
import styled from 'styled-components/native';

interface ThinkingBlockProps {
  text: string;
  isStreaming?: boolean;
  defaultExpanded?: boolean;
}

const PREVIEW_LENGTH = 80;

const Container = styled.View`
  margin: ${({ theme }) => theme.spacing.xs}px 0;
  background-color: #1f1a00;
  border: 1px dashed ${({ theme }) => theme.colors.hint};
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
  color: #aa8800;
  font-family: ${({ theme }) => theme.fonts.monoItalic};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  flex: 1;
`;

const Chevron = styled.Text`
  color: ${({ theme }) => theme.colors.hint};
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
`;

const PreviewText = styled.Text`
  color: #aa8800;
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  opacity: 0.7;
  padding: 0 ${({ theme }) => theme.spacing.md}px ${({ theme }) => theme.spacing.sm}px;
`;

const Body = styled.View`
  padding: 0 ${({ theme }) => theme.spacing.md}px ${({ theme }) => theme.spacing.sm}px;
`;

const BodyText = styled.Text`
  color: #aa8800;
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  line-height: 18px;
`;

function ThinkingBlock({ text, isStreaming = false, defaultExpanded = false }: ThinkingBlockProps) {
  const [expanded, setExpanded] = useState(defaultExpanded);

  const toggle = useCallback(() => setExpanded(prev => !prev), []);

  const preview = text.length > PREVIEW_LENGTH
    ? text.slice(0, PREVIEW_LENGTH) + '...'
    : text;

  return (
    <Container>
      <TouchableOpacity onPress={toggle} activeOpacity={0.7}>
        <Header>
          <Icon>⚡</Icon>
          <HeaderText>{isStreaming ? 'Thinking...' : 'Thought'}</HeaderText>
          <Chevron>{expanded ? '▼' : '▶'}</Chevron>
        </Header>
      </TouchableOpacity>
      {expanded ? (
        <Body>
          <BodyText>{text}</BodyText>
        </Body>
      ) : (
        <PreviewText numberOfLines={1}>{preview}</PreviewText>
      )}
    </Container>
  );
}

export default React.memo(ThinkingBlock);
