import React from 'react';
import { TouchableOpacity } from 'react-native';
import styled from 'styled-components/native';
import type { ApprovalItem } from '../../store/types';

// ── Types ────────────────────────────────────────────────────────────

export interface ApprovalItemRowProps {
  item: ApprovalItem;
  mode: 'checklist' | 'choice';
  highlighted: boolean;
  onPress: (itemId: string) => void;
}

// ── Styled components ───────────────────────────────────────────────

const Row = styled.View<{ highlighted: boolean }>`
  flex-direction: row;
  align-items: flex-start;
  padding: ${({ theme }) => theme.spacing.xs}px ${({ theme }) => theme.spacing.sm}px;
  background-color: ${({ highlighted, theme }) =>
    highlighted ? theme.colors.itemHighlight : 'transparent'};
`;

const Indicator = styled.Text<{ active: boolean }>`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ active, theme }) =>
    active ? theme.colors.checked : theme.colors.unchecked};
  margin-right: ${({ theme }) => theme.spacing.sm}px;
  line-height: ${({ theme }) => theme.sizes.fontSize + 4}px;
`;

const LabelContainer = styled.View`
  flex: 1;
`;

const Label = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreground};
`;

const Description = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoItalic};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.description};
  margin-top: 2px;
`;

// ── Glyph helpers ───────────────────────────────────────────────────

function getGlyph(mode: 'checklist' | 'choice', selected: boolean): string {
  if (mode === 'checklist') {
    return selected ? '\u2611' : '\u2610';
  }
  return selected ? '\u25C9' : '\u25CB';
}

// ── Component ───────────────────────────────────────────────────────

export default function ApprovalItemRow({
  item,
  mode,
  highlighted,
  onPress,
}: ApprovalItemRowProps) {
  return (
    <TouchableOpacity onPress={() => onPress(item.id)} activeOpacity={0.7}>
      <Row highlighted={highlighted}>
        <Indicator active={item.selected}>
          {getGlyph(mode, item.selected)}
        </Indicator>
        <LabelContainer>
          <Label>{item.label}</Label>
          {item.description ? (
            <Description>{item.description}</Description>
          ) : null}
        </LabelContainer>
      </Row>
    </TouchableOpacity>
  );
}
