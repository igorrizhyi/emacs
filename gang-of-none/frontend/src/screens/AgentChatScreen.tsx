import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { FlashList, ListRenderItem } from '@shopify/flash-list';
import { TextInput as RNTextInput, Keyboard } from 'react-native';
import styled from 'styled-components/native';
import { useRoute, RouteProp } from '@react-navigation/native';

import { useAppSelector } from '../store';
import {
  selectAgentMessages,
  selectAgentPlan,
  selectAgentPermission,
  resolvePermission,
} from '../store/slices/messagesSlice';
import type { StreamEntry } from '../store/slices/messagesSlice';
import { useAppDispatch } from '../store';
import { wsService } from '../services/ws';

import MessageStream from '../components/agent/MessageStream';
import ThinkingBlock from '../components/chat/blocks/ThinkingBlock';
import ToolCallCard from '../components/agent/ToolCallCard';
import PlanView from '../components/agent/PlanView';
import PermissionPrompt from '../components/agent/PermissionPrompt';

// ── Route params ──────────────────────────────────────────────────────

type AgentChatParams = {
  AgentChat: { agentId: string };
};

// ── Styled ────────────────────────────────────────────────────────────

const Container = styled.View`
  flex: 1;
  background-color: ${({ theme }) => theme.colors.background};
`;

const Header = styled.View`
  flex-direction: row;
  align-items: center;
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
  background-color: ${({ theme }) => theme.colors.surface};
  border-bottom-width: 1px;
  border-bottom-color: ${({ theme }) => theme.colors.separator};
`;

const RoleText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreground};
`;

const WorktreeText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.hint};
  margin-left: ${({ theme }) => theme.spacing.sm}px;
  flex-shrink: 1;
`;

const StatusBadge = styled.Text<{ statusColor: string }>`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ statusColor }) => statusColor};
  margin-left: auto;
  padding-left: ${({ theme }) => theme.spacing.sm}px;
`;

const PlanContainer = styled.View`
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
  border-bottom-width: 1px;
  border-bottom-color: ${({ theme }) => theme.colors.separator};
`;

const PlanLabel = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.hint};
  margin-bottom: ${({ theme }) => theme.spacing.xs}px;
`;

const EmptyContainer = styled.View`
  flex: 1;
  align-items: center;
  justify-content: center;
`;

const EmptyText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.hint};
`;

const PermissionOverlay = styled.View`
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  padding: ${({ theme }) => theme.spacing.md}px;
  background-color: ${({ theme }) => theme.colors.background}ee;
`;

const InputBar = styled.View`
  flex-direction: row;
  align-items: center;
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
  border-top-width: 1px;
  border-top-color: ${({ theme }) => theme.colors.separator};
  background-color: ${({ theme }) => theme.colors.surface};
`;

const StyledInput = styled.TextInput`
  flex: 1;
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreground};
  background-color: ${({ theme }) => theme.colors.background};
  border-width: 1px;
  border-color: ${({ theme }) => theme.colors.separator};
  border-radius: 4px;
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
  min-height: 36px;
`;

const SendButton = styled.Pressable`
  margin-left: ${({ theme }) => theme.spacing.sm}px;
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
  border-width: 1px;
  border-color: ${({ theme }) => theme.colors.foreground};
  border-radius: 4px;
`;

const SendText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.foreground};
`;

// ── Status color map ──────────────────────────────────────────────────

const STATUS_COLORS: Record<string, string> = {
  idle: '#33ff33',
  busy: '#ffb000',
  initializing: '#cc8800',
  dead: '#ff3333',
};

// ── Component ─────────────────────────────────────────────────────────

export default function AgentChatScreen() {
  const route = useRoute<RouteProp<AgentChatParams, 'AgentChat'>>();
  const { agentId } = route.params;
  const dispatch = useAppDispatch();

  const agent = useAppSelector((s) => s.agents[agentId]);
  const messages = useAppSelector((s) => selectAgentMessages(s, agentId));
  const plan = useAppSelector((s) => selectAgentPlan(s, agentId));
  const permission = useAppSelector((s) => selectAgentPermission(s, agentId));

  const [inputText, setInputText] = useState('');
  const listRef = useRef<FlashList<StreamEntry>>(null);
  const inputRef = useRef<RNTextInput>(null);

  // Auto-scroll on new messages
  const prevCount = useRef(messages.length);
  useEffect(() => {
    if (messages.length > prevCount.current && messages.length > 0) {
      setTimeout(() => {
        listRef.current?.scrollToEnd({ animated: true });
      }, 100);
    }
    prevCount.current = messages.length;
  }, [messages.length]);

  const handleSend = useCallback(() => {
    const text = inputText.trim();
    if (!text) return;
    wsService.sendRequest('promptAgent', { agent_id: agentId, message: text });
    setInputText('');
    Keyboard.dismiss();
  }, [inputText, agentId]);

  const handleAllow = useCallback(() => {
    if (!permission) return;
    wsService.sendRequest('permissionResponse', {
      agent_id: agentId,
      tool_call_id: permission.toolCallId,
      allowed: true,
    });
    dispatch(resolvePermission({ agentId }));
  }, [permission, agentId, dispatch]);

  const handleDeny = useCallback(() => {
    if (!permission) return;
    wsService.sendRequest('permissionResponse', {
      agent_id: agentId,
      tool_call_id: permission.toolCallId,
      allowed: false,
    });
    dispatch(resolvePermission({ agentId }));
  }, [permission, agentId, dispatch]);

  const isBusy = agent?.status === 'busy';

  const renderItem: ListRenderItem<StreamEntry> = useCallback(
    ({ item, index }) => {
      const isLast = index === messages.length - 1;

      switch (item.type) {
        case 'message':
          return (
            <MessageStream
              text={item.text}
              isStreaming={isLast && isBusy}
            />
          );
        case 'thought':
          return (
            <ThinkingBlock
              text={item.text}
              isStreaming={isLast && isBusy}
            />
          );
        case 'toolCall':
          return (
            <ToolCallCard
              toolCallId={item.toolCallId}
              title={item.title}
              status={item.status}
              kind={item.kind}
              rawInput={item.rawInput}
              content={item.content}
            />
          );
        default:
          return null;
      }
    },
    [messages.length, isBusy],
  );

  const keyExtractor = useCallback(
    (item: StreamEntry, index: number) => {
      if (item.type === 'toolCall') return item.toolCallId;
      return `${item.type}-${index}`;
    },
    [],
  );

  const roleName = agent?.role ?? 'agent';
  const worktreeName = agent?.worktreeName ?? agent?.bufferName ?? agentId;
  const statusColor = STATUS_COLORS[agent?.status ?? 'dead'] ?? '#888888';

  return (
    <Container>
      <Header>
        <RoleText>{roleName}</RoleText>
        <WorktreeText numberOfLines={1}>{worktreeName}</WorktreeText>
        <StatusBadge statusColor={statusColor}>
          {agent?.status ?? 'unknown'}
        </StatusBadge>
      </Header>

      {plan && (
        <PlanContainer>
          <PlanLabel>PLAN</PlanLabel>
          <PlanView entries={plan} />
        </PlanContainer>
      )}

      {messages.length === 0 ? (
        <EmptyContainer>
          <EmptyText>No messages yet</EmptyText>
        </EmptyContainer>
      ) : (
        <FlashList
          ref={listRef}
          data={messages}
          renderItem={renderItem}
          keyExtractor={keyExtractor}
          estimatedItemSize={80}
          contentContainerStyle={{ paddingHorizontal: 8, paddingVertical: 4 }}
        />
      )}

      {permission && (
        <PermissionOverlay>
          <PermissionPrompt
            toolCallId={permission.toolCallId}
            title={permission.title}
            description={permission.description}
            onAllow={handleAllow}
            onDeny={handleDeny}
          />
        </PermissionOverlay>
      )}

      <InputBar>
        <StyledInput
          ref={inputRef}
          value={inputText}
          onChangeText={setInputText}
          placeholder="Send message..."
          placeholderTextColor="#665500"
          onSubmitEditing={handleSend}
          returnKeyType="send"
        />
        <SendButton onPress={handleSend}>
          <SendText>Send</SendText>
        </SendButton>
      </InputBar>
    </Container>
  );
}
