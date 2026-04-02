import React, { useState, useCallback, useEffect } from 'react';
import { TouchableOpacity, ActivityIndicator } from 'react-native';
import styled from 'styled-components/native';

type ToolCallStatus = 'pending' | 'in_progress' | 'completed' | 'failed';

export interface ToolCallCardProps {
  toolCallId: string;
  title: string;
  status: string;
  kind: string;
  rawInput?: any;
  content?: any;
}

// --- Styled components ---

const Card = styled.View`
  margin: ${({ theme }) => theme.spacing.xs}px 0;
  background-color: #1a1800;
  border-width: 1px;
  border-color: ${({ theme }) => theme.colors.separator};
  border-radius: 4px;
  overflow: hidden;
`;

const Header = styled.View`
  flex-direction: row;
  align-items: center;
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
`;

const StatusIcon = styled.Text`
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  margin-right: ${({ theme }) => theme.spacing.sm}px;
`;

const TitleText = styled.Text`
  color: ${({ theme }) => theme.colors.foreground};
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  flex: 1;
`;

const KindTag = styled.Text`
  color: ${({ theme }) => theme.colors.hint};
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  margin-left: ${({ theme }) => theme.spacing.sm}px;
`;

const Chevron = styled.Text`
  color: ${({ theme }) => theme.colors.hint};
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  margin-left: ${({ theme }) => theme.spacing.xs}px;
`;

const Body = styled.View`
  padding: 0 ${({ theme }) => theme.spacing.md}px ${({ theme }) => theme.spacing.sm}px;
  border-top-width: 1px;
  border-top-color: ${({ theme }) => theme.colors.separator};
`;

const CommandText = styled.Text`
  color: ${({ theme }) => theme.colors.foreground};
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  margin-top: ${({ theme }) => theme.spacing.sm}px;
`;

const OutputText = styled.Text`
  color: ${({ theme }) => theme.colors.unchecked};
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  margin-top: ${({ theme }) => theme.spacing.xs}px;
`;

const DiffLine = styled.Text<{ lineType: 'add' | 'remove' | 'context' }>`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ lineType }) =>
    lineType === 'add' ? '#33ff33' : lineType === 'remove' ? '#ff3333' : '#888888'};
`;

// --- Status helpers ---

const STATUS_ICONS: Record<ToolCallStatus, string> = {
  pending: '⏳',
  in_progress: '',
  completed: '✓',
  failed: '✗',
};

const STATUS_COLORS: Record<ToolCallStatus, string> = {
  pending: '#88aaff',
  in_progress: '#ffb000',
  completed: '#33ff33',
  failed: '#ff3333',
};

function normalizeStatus(status: string): ToolCallStatus {
  if (status === 'pending' || status === 'in_progress' || status === 'completed' || status === 'failed') {
    return status;
  }
  // Map common aliases
  if (status === 'running') return 'in_progress';
  if (status === 'success') return 'completed';
  if (status === 'error') return 'failed';
  return 'pending';
}

function StatusDisplay({ status }: { status: ToolCallStatus }) {
  if (status === 'in_progress') {
    return (
      <ActivityIndicator
        size="small"
        color={STATUS_COLORS.in_progress}
        style={{ marginRight: 8 }}
      />
    );
  }
  return (
    <StatusIcon style={{ color: STATUS_COLORS[status] }}>
      {STATUS_ICONS[status]}
    </StatusIcon>
  );
}

// --- Content extraction helpers ---

function extractCommandText(rawInput?: any): string | null {
  if (!rawInput) return null;
  if (typeof rawInput === 'string') return rawInput;
  if (rawInput.command) return rawInput.command;
  if (rawInput.description) return rawInput.description;
  return null;
}

function extractOutputText(content?: any): string | null {
  if (!content) return null;
  if (typeof content === 'string') return content;
  // Array of {type: 'text', content: {text}} blocks
  if (Array.isArray(content)) {
    const parts = content
      .filter((block: any) => block.type === 'text')
      .map((block: any) => {
        if (typeof block.content === 'string') return block.content;
        if (block.content?.text) return block.content.text;
        return '';
      })
      .filter(Boolean);
    return parts.length > 0 ? parts.join('\n') : null;
  }
  // Single text object
  if (content.type === 'text') {
    if (typeof content.content === 'string') return content.content;
    if (content.content?.text) return content.content.text;
  }
  return null;
}

interface DiffData {
  old: string;
  new: string;
}

function extractDiff(content?: any): DiffData | null {
  if (!content) return null;
  if (content.type === 'diff' && content.old != null && content.new != null) {
    return { old: String(content.old), new: String(content.new) };
  }
  // Check array for diff blocks
  if (Array.isArray(content)) {
    const diffBlock = content.find((block: any) => block.type === 'diff');
    if (diffBlock?.old != null && diffBlock?.new != null) {
      return { old: String(diffBlock.old), new: String(diffBlock.new) };
    }
  }
  return null;
}

function DiffView({ diff }: { diff: DiffData }) {
  const oldLines = diff.old.split('\n');
  const newLines = diff.new.split('\n');
  return (
    <>
      {oldLines.map((line, i) => (
        <DiffLine key={`old-${i}`} lineType="remove">
          {`- ${line}`}
        </DiffLine>
      ))}
      {newLines.map((line, i) => (
        <DiffLine key={`new-${i}`} lineType="add">
          {`+ ${line}`}
        </DiffLine>
      ))}
    </>
  );
}

// --- Main component ---

function ToolCallCard({ toolCallId, title, status, kind, rawInput, content }: ToolCallCardProps) {
  const normalizedStatus = normalizeStatus(status);
  const [expanded, setExpanded] = useState(normalizedStatus === 'in_progress');

  // Auto-expand when status changes to in_progress
  useEffect(() => {
    if (normalizedStatus === 'in_progress') {
      setExpanded(true);
    }
  }, [normalizedStatus]);

  const toggle = useCallback(() => setExpanded(prev => !prev), []);

  const commandText = extractCommandText(rawInput);
  const outputText = extractOutputText(content);
  const diff = extractDiff(content);
  const hasBody = Boolean(commandText || outputText || diff);

  return (
    <Card>
      <TouchableOpacity onPress={toggle} activeOpacity={0.7} disabled={!hasBody}>
        <Header>
          <StatusDisplay status={normalizedStatus} />
          <TitleText numberOfLines={1}>{title}</TitleText>
          <KindTag>{kind}</KindTag>
          {hasBody && <Chevron>{expanded ? '▼' : '▶'}</Chevron>}
        </Header>
      </TouchableOpacity>
      {expanded && hasBody && (
        <Body>
          {commandText ? <CommandText>{`$ ${commandText}`}</CommandText> : null}
          {diff ? <DiffView diff={diff} /> : null}
          {outputText ? <OutputText>{outputText}</OutputText> : null}
        </Body>
      )}
    </Card>
  );
}

export default React.memo(ToolCallCard);
