import React from 'react';
import styled from 'styled-components/native';

type StepStatus = 'pending' | 'in_progress' | 'completed';

interface PlanEntry {
  status: string;
  content: string;
}

interface PlanViewProps {
  entries: Array<PlanEntry>;
}

const statusConfig: Record<StepStatus, { icon: string; colorKey: string }> = {
  pending:     { icon: '○', colorKey: 'hint' },
  in_progress: { icon: '◉', colorKey: 'foreground' },
  completed:   { icon: '●', colorKey: 'idle' },
};

const Container = styled.View`
  padding: ${({ theme }) => theme.spacing.sm}px 0;
`;

const StepRow = styled.View`
  flex-direction: row;
  align-items: flex-start;
`;

const TimelineColumn = styled.View`
  width: 24px;
  align-items: center;
`;

const TimelineConnector = styled.View`
  width: 1px;
  flex: 1;
  min-height: 8px;
  background-color: ${({ theme }) => theme.colors.separator};
`;

const StepIcon = styled.Text<{ statusColor: string }>`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme, statusColor }) =>
    (theme.colors as Record<string, string>)[statusColor] ?? theme.colors.hint};
  line-height: 20px;
`;

const StepContent = styled.Text<{ dim: boolean }>`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme, dim }) => dim ? theme.colors.hint : theme.colors.foreground};
  flex: 1;
  line-height: 20px;
  padding-bottom: ${({ theme }) => theme.spacing.xs}px;
`;

function resolveStatus(raw: string): StepStatus {
  if (raw === 'completed') return 'completed';
  if (raw === 'in_progress') return 'in_progress';
  return 'pending';
}

function PlanView({ entries }: PlanViewProps) {
  return (
    <Container>
      {entries.map((entry, index) => {
        const status = resolveStatus(entry.status);
        const { icon, colorKey } = statusConfig[status];
        const isLast = index === entries.length - 1;

        return (
          <StepRow key={index}>
            <TimelineColumn>
              <StepIcon statusColor={colorKey}>{icon}</StepIcon>
              {!isLast && <TimelineConnector />}
            </TimelineColumn>
            <StepContent dim={status === 'pending'}>
              {entry.content}
            </StepContent>
          </StepRow>
        );
      })}
    </Container>
  );
}

export default React.memo(PlanView);
