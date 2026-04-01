import React, { useMemo } from 'react';
import { Text as RNText } from 'react-native';
import styled from 'styled-components/native';

interface AssistantMessageProps {
  content: string;
}

const Container = styled.View`
  padding: ${({ theme }) => theme.spacing.xs}px 0;
`;

const MessageText = styled.Text`
  color: ${({ theme }) => theme.colors.foreground};
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  line-height: 20px;
`;

const BoldText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
`;

const CodeText = styled.Text`
  background-color: ${({ theme }) => theme.colors.surface};
  font-family: ${({ theme }) => theme.fonts.mono};
  color: ${({ theme }) => theme.colors.barWarn};
`;

const HeaderText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeLarge}px;
  color: ${({ theme }) => theme.colors.foreground};
`;

/**
 * Simple inline markdown renderer. Handles **bold**, `code`, and # headers.
 * Will be replaced by react-native-streamdown for streaming support.
 */
function parseMarkdown(text: string): React.ReactNode[] {
  const lines = text.split('\n');
  const elements: React.ReactNode[] = [];

  lines.forEach((line, lineIdx) => {
    if (lineIdx > 0) {
      elements.push(<RNText key={`nl-${lineIdx}`}>{'\n'}</RNText>);
    }

    // Headers
    const headerMatch = line.match(/^(#{1,3})\s+(.+)$/);
    if (headerMatch) {
      elements.push(
        <HeaderText key={`h-${lineIdx}`}>{headerMatch[2]}</HeaderText>,
      );
      return;
    }

    // Inline formatting: **bold** and `code`
    const parts = line.split(/(\*\*[^*]+\*\*|`[^`]+`)/g);
    parts.forEach((part, partIdx) => {
      const key = `${lineIdx}-${partIdx}`;
      if (part.startsWith('**') && part.endsWith('**')) {
        elements.push(
          <BoldText key={key}>{part.slice(2, -2)}</BoldText>,
        );
      } else if (part.startsWith('`') && part.endsWith('`')) {
        elements.push(
          <CodeText key={key}>{part.slice(1, -1)}</CodeText>,
        );
      } else if (part) {
        elements.push(
          <RNText key={key}>{part}</RNText>,
        );
      }
    });
  });

  return elements;
}

function AssistantMessage({ content }: AssistantMessageProps) {
  const rendered = useMemo(() => parseMarkdown(content), [content]);

  return (
    <Container>
      <MessageText>{rendered}</MessageText>
    </Container>
  );
}

export default React.memo(AssistantMessage);
