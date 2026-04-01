import React from 'react';
import styled from 'styled-components/native';

interface ContextBarProps {
  used: number;
  total: number;
}

const Row = styled.View`
  flex-direction: row;
  align-items: center;
  padding: ${({ theme }) => theme.spacing.xs}px ${({ theme }) => theme.spacing.sm}px;
`;

const Label = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreground};
`;

const EmptyText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.barEmpty};
`;

const FilledBar = styled.Text<{ pct: number }>`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme, pct }) =>
    pct > 85 ? theme.colors.barCritical :
    pct > 60 ? theme.colors.barWarn :
    theme.colors.barFilled};
`;

const StatText = styled.Text<{ pct: number }>`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme, pct }) =>
    pct > 85 ? theme.colors.barCritical :
    pct > 60 ? theme.colors.barWarn :
    theme.colors.barFilled};
`;

function formatK(n: number): string {
  return n >= 1000 ? `${Math.round(n / 1000)}k` : String(n);
}

const BAR_WIDTH = 20;

export default function ContextBar({ used, total }: ContextBarProps) {
  const pct = total > 0 ? Math.round((used / total) * 100) : 0;
  const filled = Math.round((pct / 100) * BAR_WIDTH);
  const empty = BAR_WIDTH - filled;

  return (
    <Row>
      <Label>ctx [</Label>
      <FilledBar pct={pct}>{'█'.repeat(filled)}</FilledBar>
      <EmptyText>{'░'.repeat(empty)}</EmptyText>
      <Label>] </Label>
      <StatText pct={pct}>{pct}% {formatK(used)}/{formatK(total)}</StatText>
    </Row>
  );
}
