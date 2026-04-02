import React from 'react';
import { Pressable } from 'react-native';
import styled from 'styled-components/native';

interface PermissionPromptProps {
  toolCallId: string;
  title: string;
  description: string;
  onAllow: () => void;
  onDeny: () => void;
}

const Container = styled.View`
  margin: ${({ theme }) => theme.spacing.sm}px 0;
  background-color: ${({ theme }) => theme.colors.surface};
  border-radius: 4px;
  padding: ${({ theme }) => theme.spacing.md}px;
  border-width: 1px;
  border-color: ${({ theme }) => theme.colors.barWarn};
`;

const Header = styled.View`
  flex-direction: row;
  align-items: center;
  margin-bottom: ${({ theme }) => theme.spacing.sm}px;
`;

const WarningIcon = styled.Text`
  font-size: ${({ theme }) => theme.sizes.fontSizeLarge}px;
  margin-right: ${({ theme }) => theme.spacing.sm}px;
`;

const HeaderTitle = styled.Text`
  color: ${({ theme }) => theme.colors.foreground};
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeLarge}px;
`;

const TitleText = styled.Text`
  color: ${({ theme }) => theme.colors.foreground};
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  margin-bottom: ${({ theme }) => theme.spacing.xs}px;
`;

const DescriptionText = styled.Text`
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
  border-width: 1px;
  border-color: ${({ theme }) => theme.colors.idle};
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
  border-radius: 4px;
`;

const DenyButton = styled.View`
  border-width: 1px;
  border-color: ${({ theme }) => theme.colors.dead};
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
  border-radius: 4px;
`;

const AllowText = styled.Text`
  color: ${({ theme }) => theme.colors.idle};
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
`;

const DenyText = styled.Text`
  color: ${({ theme }) => theme.colors.dead};
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
`;

function PermissionPrompt({ title, description, onAllow, onDeny }: PermissionPromptProps) {
  return (
    <Container>
      <Header>
        <WarningIcon>{'\u26A0\uFE0F'}</WarningIcon>
        <HeaderTitle>Permission Required</HeaderTitle>
      </Header>
      <TitleText>{title}</TitleText>
      <DescriptionText>{description}</DescriptionText>
      <ButtonRow>
        <Pressable onPress={onAllow} style={({ pressed }) => ({ opacity: pressed ? 0.6 : 1 })}>
          <AllowButton>
            <AllowText>Allow</AllowText>
          </AllowButton>
        </Pressable>
        <Pressable onPress={onDeny} style={({ pressed }) => ({ opacity: pressed ? 0.6 : 1 })}>
          <DenyButton>
            <DenyText>Deny</DenyText>
          </DenyButton>
        </Pressable>
      </ButtonRow>
    </Container>
  );
}

export default React.memo(PermissionPrompt);
