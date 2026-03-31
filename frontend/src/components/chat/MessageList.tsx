import React, { useCallback } from 'react';
import { View } from 'react-native';
import { FlashList, ListRenderItem } from '@shopify/flash-list';
import styled from 'styled-components/native';
import {
  UserMessage,
  AssistantMessage,
  ThinkingBlock,
  ToolCallBlock,
  PermissionBlock,
  ErrorBlock,
  UsageBlock,
} from './blocks';

export type BlockType =
  | 'user_message'
  | 'assistant_message'
  | 'thinking'
  | 'tool_call'
  | 'permission'
  | 'error'
  | 'usage';

export interface ChatBlock {
  id: string;
  type: BlockType;
  content: string;
  metadata?: {
    toolName?: string;
    status?: 'pending' | 'running' | 'success' | 'failed';
    command?: string;
    output?: string;
    isComplete?: boolean;
    description?: string;
    contextPercent?: number;
    tokens?: number;
    cost?: number;
  };
}

interface MessageListProps {
  blocks: ChatBlock[];
  onPermissionAllow?: (blockId: string) => void;
  onPermissionDeny?: (blockId: string) => void;
}

const Container = styled.View`
  flex: 1;
  background-color: ${({ theme }) => theme.colors.background};
`;

const BlockItem = React.memo(function BlockItem({
  block,
  onPermissionAllow,
  onPermissionDeny,
}: {
  block: ChatBlock;
  onPermissionAllow?: (blockId: string) => void;
  onPermissionDeny?: (blockId: string) => void;
}) {
  switch (block.type) {
    case 'user_message':
      return <UserMessage content={block.content} />;
    case 'assistant_message':
      return <AssistantMessage content={block.content} />;
    case 'thinking':
      return (
        <ThinkingBlock
          content={block.content}
          isComplete={block.metadata?.isComplete}
        />
      );
    case 'tool_call':
      return (
        <ToolCallBlock
          toolName={block.metadata?.toolName ?? 'Unknown'}
          status={block.metadata?.status ?? 'pending'}
          command={block.metadata?.command}
          output={block.metadata?.output}
        />
      );
    case 'permission':
      return (
        <PermissionBlock
          toolName={block.metadata?.toolName ?? 'Unknown'}
          description={block.metadata?.description}
          onAllow={() => onPermissionAllow?.(block.id)}
          onDeny={() => onPermissionDeny?.(block.id)}
        />
      );
    case 'error':
      return <ErrorBlock message={block.content} />;
    case 'usage':
      return (
        <UsageBlock
          contextPercent={block.metadata?.contextPercent ?? 0}
          tokens={block.metadata?.tokens}
          cost={block.metadata?.cost}
        />
      );
    default:
      return null;
  }
});

function keyExtractor(item: ChatBlock) {
  return item.id;
}

export default function MessageList({
  blocks,
  onPermissionAllow,
  onPermissionDeny,
}: MessageListProps) {
  const renderItem: ListRenderItem<ChatBlock> = useCallback(
    ({ item }) => (
      <BlockItem
        block={item}
        onPermissionAllow={onPermissionAllow}
        onPermissionDeny={onPermissionDeny}
      />
    ),
    [onPermissionAllow, onPermissionDeny],
  );

  return (
    <Container>
      <FlashList
        data={blocks}
        renderItem={renderItem}
        estimatedItemSize={80}
        inverted
        keyExtractor={keyExtractor}
      />
    </Container>
  );
}
