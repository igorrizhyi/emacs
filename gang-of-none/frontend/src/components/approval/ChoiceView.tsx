import React from 'react';
import { TouchableOpacity } from 'react-native';
import styled from 'styled-components/native';
import type { ApprovalItem } from '../../store/types';

// ── Types ────────────────────────────────────────────────────────────

interface ChoiceViewProps {
  items: ApprovalItem[];
  highlightedIndex: number;
  onSelect: (itemId: string) => void;
}

// ── Styled components ───────────────────────────────────────────────

const Row = styled.View<{ highlighted: boolean }>`
  flex-direction: row;
  align-items: flex-start;
  padding: ${({ theme }) => theme.spacing.xs}px ${({ theme }) => theme.spacing.sm}px;
  background-color: ${({ highlighted, theme }) =>
    highlighted ? theme.colors.itemHighlight : 'transparent'};
`;

const Radio = styled.Text<{ selected: boolean }>`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ selected, theme }) =>
    selected ? theme.colors.checked : theme.colors.unchecked};
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

export default function ChoiceView({
  items,
  highlightedIndex,
  onSelect,
}: ChoiceViewProps) {
  return (
    <>
      {items.map((item, index) => (
        <TouchableOpacity
          key={item.id}
          onPress={() => onSelect(item.id)}
          activeOpacity={0.7}
        >
          <Row highlighted={index === highlightedIndex}>
            <Radio selected={item.selected}>
              {item.selected ? '\u25C9' : '\u25CB'}
            </Radio>
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
