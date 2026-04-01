import React from 'react';
import styled from 'styled-components/native';

interface UsageBlockProps {
  contextPercent: number;
  tokens?: number;
  cost?: number;
}

const Container = styled.View`
  margin: ${({ theme }) => theme.spacing.xs}px 0;
  padding: ${({ theme }) => theme.spacing.xs}px ${({ theme }) => theme.spacing.md}px;
  flex-direction: row;
  align-items: center;
  gap: ${({ theme }) => theme.spacing.md}px;
`;

const Label = styled.Text`
  color: ${({ theme }) => theme.colors.hint};
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
`;

const BarContainer = styled.View`
  flex-direction: row;
  align-items: center;
  gap: ${({ theme }) => theme.spacing.xs}px;
`;

const BarTrack = styled.View`
  width: 80px;
  height: 4px;
  background-color: ${({ theme }) => theme.colors.barEmpty};
  border-radius: 2px;
  overflow: hidden;
`;

function barColor(percent: number): string {
  if (percent >= 90) return '#ff3333';
  if (percent >= 70) return '#ffb000';
  return '#33ff33';
}

const BarFill = styled.View<{ percent: number }>`
  width: ${({ percent }) => Math.min(percent, 100)}%;
  height: 100%;
  background-color: ${({ percent }) => barColor(percent)};
`;

function UsageBlock({ contextPercent, tokens, cost }: UsageBlockProps) {
  return (
    <Container>
      <BarContainer>
        <Label>ctx</Label>
        <BarTrack>
          <BarFill percent={contextPercent} />
        </BarTrack>
        <Label>{contextPercent}%</Label>
      </BarContainer>
      {tokens != null && <Label>{tokens.toLocaleString()} tok</Label>}
      {cost != null && <Label>${cost.toFixed(4)}</Label>}
    </Container>
  );
}

export default React.memo(UsageBlock);
