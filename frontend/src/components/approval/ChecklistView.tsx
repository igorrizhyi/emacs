import React from 'react';
import { TouchableOpacity } from 'react-native';
import styled from 'styled-components/native';
import type { ApprovalItem } from '../../store/slices/approvalSlice';

// ── Types ────────────────────────────────────────────────────────────

interface ChecklistViewProps {
  items: ApprovalItem[];
  highlightedIndex: number;
  onToggle: (itemId: string) => void;
}

// ── Styled components ───────────────────────────────────────────────

const Row = styled.View<{ highlighted: boolean }>`
  flex-direction: row;
  align-items: flex-start;
  padding: ${({ theme }) => theme.spacing.xs}px ${({ theme }) => theme.spacing.sm}px;
  background-color: ${({ highlighted, theme }) =>
    highlighted ? theme.colors.itemHighlight : 'transparent'};
`;

const Checkbox = styled.Text<{ checked: boolean }>`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ checked, theme }) =>
    checked ? theme.colors.checked : theme.colors.unchecked};
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

// ── Component ───────────────────────────────────────────────────────

export default function ChecklistView({
  items,
  highlightedIndex,
  onToggle,
}: ChecklistViewProps) {
  return (
    <>
      {items.map((item, index) => (
        <TouchableOpacity
          key={item.id}
          onPress={() => onToggle(item.id)}
          activeOpacity={0.7}
        >
          <Row highlighted={index === highlightedIndex}>
            <Checkbox checked={item.selected}>
              {item.selected ? '\u2611' : '\u2610'}
            </Checkbox>
            <LabelContainer>
              <Label>{item.label}</Label>
              {item.description ? (
                <Description>{item.description}</Description>
              ) : null}
            </LabelContainer>
          </Row>
        </TouchableOpacity>
      ))}
    </>
  );
}
