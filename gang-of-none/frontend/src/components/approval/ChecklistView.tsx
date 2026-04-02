import React from 'react';
import type { ApprovalItem } from '../../store/types';
import ApprovalItemRow from './ApprovalItemRow';

// ── Types ────────────────────────────────────────────────────────────

interface ChecklistViewProps {
  items: ApprovalItem[];
  highlightedIndex: number;
  onToggle: (itemId: string) => void;
}

// ── Component ───────────────────────────────────────────────────────

export default function ChecklistView({
  items,
  highlightedIndex,
  onToggle,
}: ChecklistViewProps) {
  return (
    <>
      {items.map((item, index) => (
        <ApprovalItemRow
          key={item.id}
          item={item}
          mode="checklist"
          highlighted={index === highlightedIndex}
          onPress={onToggle}
        />
      ))}
    </>
  );
}
