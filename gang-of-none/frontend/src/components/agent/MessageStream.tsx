import React, { useEffect, useRef } from 'react';
import { Text, Animated, Easing } from 'react-native';
import styled from 'styled-components/native';

interface MessageStreamProps {
  text: string;
  isStreaming?: boolean;
}

const Container = styled.View`
  border-left-width: 2px;
  border-left-color: ${({ theme }) => theme.colors.foreground}40;
  padding-left: ${({ theme }) => theme.spacing.sm}px;
  padding-vertical: ${({ theme }) => theme.spacing.xs}px;
`;

const MessageText = styled.Text`
  color: ${({ theme }) => theme.colors.foreground};
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  line-height: ${({ theme }) => theme.sizes.fontSize * 1.5}px;
`;

const BoldText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
`;

const CodeText = styled.Text`
  background-color: ${({ theme }) => theme.colors.surface};
  color: ${({ theme }) => theme.colors.foreground};
  font-family: ${({ theme }) => theme.fonts.mono};
`;

// Parse simple markdown: **bold** and `code`
function parseInlineFormatting(input: string): React.ReactNode[] {
  const parts: React.ReactNode[] = [];
  // Match **bold** or `code` segments
  const regex = /(\*\*(.+?)\*\*|`([^`]+)`)/g;
  let lastIndex = 0;
  let match: RegExpExecArray | null;

  while ((match = regex.exec(input)) !== null) {
    // Text before the match
    if (match.index > lastIndex) {
      parts.push(input.slice(lastIndex, match.index));
    }

    if (match[2] != null) {
      // **bold**
      parts.push(<BoldText key={match.index}>{match[2]}</BoldText>);
    } else if (match[3] != null) {
      // `code`
      parts.push(<CodeText key={match.index}>{match[3]}</CodeText>);
    }

    lastIndex = match.index + match[0].length;
  }

  // Trailing text
  if (lastIndex < input.length) {
    parts.push(input.slice(lastIndex));
  }

  return parts;
}

function BlinkingCursor() {
  const opacity = useRef(new Animated.Value(1)).current;

  useEffect(() => {
    const animation = Animated.loop(
      Animated.sequence([
        Animated.timing(opacity, {
          toValue: 0,
          duration: 500,
          easing: Easing.step0,
          useNativeDriver: true,
        }),
        Animated.timing(opacity, {
          toValue: 1,
          duration: 500,
          easing: Easing.step0,
          useNativeDriver: true,
        }),
      ]),
    );
    animation.start();
    return () => animation.stop();
  }, [opacity]);

  return (
    <Animated.Text
      style={{
        opacity,
        color: '#ffb000',
        fontFamily: 'RobotoMono-Regular',
      }}
    >
      ▊
    </Animated.Text>
  );
}

export default function MessageStream({ text, isStreaming }: MessageStreamProps) {
  const formatted = parseInlineFormatting(text);

  return (
    <Container>
      <MessageText>
        {formatted}
        {isStreaming && <BlinkingCursor />}
      </MessageText>
    </Container>
  );
}
