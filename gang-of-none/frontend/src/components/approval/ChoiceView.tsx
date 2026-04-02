import React from 'react';
import type { ApprovalItem } from '../../store/types';
import ApprovalItemRow from './ApprovalItemRow';

// ── Types ────────────────────────────────────────────────────────────

interface ChoiceViewProps {
  items: ApprovalItem[];
  highlightedIndex: number;
  onSelect: (itemId: string) => void;
}

// ── Component ───────────────────────────────────────────────────────

export default function ChoiceView({
  items,
  highlightedIndex,
  onSelect,
}: ChoiceViewProps) {
  return (
    <>
      {items.map((item, index) => (
        <ApprovalItemRow
          key={item.id}
          item={item}
          mode="choice"
          highlighted={index === highlightedIndex}
          onPress={onSelect}
        />
      ))}
    </>
  );
}
