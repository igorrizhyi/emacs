import React from 'react';
import { TouchableOpacity } from 'react-native';
import styled from 'styled-components/native';

interface PermissionBlockProps {
  toolName: string;
  description?: string;
  onAllow: () => void;
  onDeny: () => void;
}

const Container = styled.View`
  margin: ${({ theme }) => theme.spacing.xs}px 0;
  background-color: ${({ theme }) => theme.colors.surface};
  border-radius: 4px;
  padding: ${({ theme }) => theme.spacing.md}px;
  border-left-width: 3px;
  border-left-color: ${({ theme }) => theme.colors.barWarn};
`;

const Title = styled.Text`
  color: ${({ theme }) => theme.colors.foreground};
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  margin-bottom: ${({ theme }) => theme.spacing.sm}px;
`;

const Description = styled.Text`
  color: ${({ theme }) => theme.colors.description};
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  margin-bottom: ${({ theme }) => theme.spacing.md}px;
`;

const ButtonRow = styled.View`
  flex-direction: row;
  gap: ${({ theme }) => theme.spacing.sm}px;
`;

const AllowButton = styled.View`
  background-color: ${({ theme }) => theme.colors.idle};
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
  border-radius: 4px;
`;

const DenyButton = styled.View`
  background-color: ${({ theme }) => theme.colors.dead};
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
  border-radius: 4px;
`;

const ButtonText = styled.Text`
  color: ${({ theme }) => theme.colors.background};
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
`;

function PermissionBlock({ toolName, description, onAllow, onDeny }: PermissionBlockProps) {
  return (
    <Container>
      <Title>Permission: {toolName}</Title>
      {description ? <Description>{description}</Description> : null}
      <ButtonRow>
        <TouchableOpacity onPress={onAllow} activeOpacity={0.7}>
          <AllowButton>
            <ButtonText>Allow</ButtonText>
          </AllowButton>
        </TouchableOpacity>
        <TouchableOpacity onPress={onDeny} activeOpacity={0.7}>
          <DenyButton>
            <ButtonText>Deny</ButtonText>
          </DenyButton>
        </TouchableOpacity>
      </ButtonRow>
    </Container>
  );
}

export default React.memo(PermissionBlock);
