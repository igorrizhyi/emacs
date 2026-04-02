import React, { useState, useCallback, useEffect } from 'react';
import { ScrollView, TouchableOpacity, Dimensions } from 'react-native';
import styled from 'styled-components/native';
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withTiming,
  Easing,
} from 'react-native-reanimated';
import { useSelector, useDispatch } from 'react-redux';
import type { RootState } from '../../store';
import {
  selectActiveRequest,
  selectPendingCount,
  setActiveRequest,
  toggleItem,
  updateNotes,
  updateRefine,
  removeApproval,
} from '../../store/slices/approvalSlice';
import { useUIStore } from '../../store/uiStore';
import { websocketService } from '../../services/websocket';
import ChecklistView from './ChecklistView';
import ChoiceView from './ChoiceView';

// ── Constants ────────────────────────────────────────────────────────

const SHEET_HEIGHT = 400;
const LEFT_PANEL_WIDTH = 160;
const ANIMATION_DURATION = 250;
const { width: SCREEN_WIDTH } = Dimensions.get('window');

// ── Styled components ───────────────────────────────────────────────

const Overlay = styled.Pressable`
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background-color: rgba(0, 0, 0, 0.4);
`;

const SheetContainer = styled(Animated.View)`
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  height: ${SHEET_HEIGHT}px;
  background-color: ${({ theme }) => theme.colors.background};
  border-top-width: 1px;
  border-top-color: ${({ theme }) => theme.colors.separator};
`;

const SheetHeader = styled.View`
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
  background-color: ${({ theme }) => theme.colors.surface};
  border-bottom-width: 1px;
  border-bottom-color: ${({ theme }) => theme.colors.separator};
`;

const HeaderTitle = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreground};
`;

const Badge = styled.View`
  background-color: ${({ theme }) => theme.colors.foreground};
  border-radius: 8px;
  padding: 1px 6px;
  margin-left: ${({ theme }) => theme.spacing.sm}px;
`;

const BadgeText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.background};
`;

const HeaderRow = styled.View`
  flex-direction: row;
  align-items: center;
`;

const Body = styled.View`
  flex: 1;
  flex-direction: row;
`;

const LeftPanel = styled.View`
  width: ${LEFT_PANEL_WIDTH}px;
  border-right-width: 1px;
  border-right-color: ${({ theme }) => theme.colors.separator};
`;

const RightPanel = styled.View`
  flex: 1;
`;

const RequestRow = styled.TouchableOpacity<{ active: boolean }>`
  padding: ${({ theme }) => theme.spacing.xs}px ${({ theme }) => theme.spacing.sm}px;
  background-color: ${({ active, theme }) =>
    active ? theme.colors.itemHighlight : 'transparent'};
`;

const RequestLabel = styled.Text<{ active: boolean }>`
  font-family: ${({ active, theme }) =>
    active ? theme.fonts.monoBold : theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.foreground};
`;

const RequestIndicator = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.foreground};
  margin-right: 4px;
`;

const RequestRowInner = styled.View`
  flex-direction: row;
  align-items: center;
`;

const SectionTitle = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.foreground};
  padding: ${({ theme }) => theme.spacing.sm}px;
`;

const DescriptionText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.monoItalic};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.description};
  padding: 0 ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.sm}px;
`;

const InputLabel = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.hint};
  padding: ${({ theme }) => theme.spacing.xs}px ${({ theme }) => theme.spacing.sm}px 2px;
`;

const StyledInput = styled.TextInput`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ theme }) => theme.colors.foreground};
  background-color: ${({ theme }) => theme.colors.background};
  border-width: 1px;
  border-color: ${({ theme }) => theme.colors.foreground};
  margin: 0 ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.sm}px;
  padding: ${({ theme }) => theme.spacing.xs}px ${({ theme }) => theme.spacing.sm}px;
`;

const Footer = styled.View`
  flex-direction: row;
  justify-content: flex-end;
  padding: ${({ theme }) => theme.spacing.sm}px ${({ theme }) => theme.spacing.md}px;
  background-color: ${({ theme }) => theme.colors.surface};
  border-top-width: 1px;
  border-top-color: ${({ theme }) => theme.colors.separator};
  gap: ${({ theme }) => theme.spacing.sm}px;
`;

const FooterButton = styled.TouchableOpacity<{ variant: 'submit' | 'dismiss' }>`
  padding: ${({ theme }) => theme.spacing.xs}px ${({ theme }) => theme.spacing.md}px;
  border-width: 1px;
  border-color: ${({ variant, theme }) =>
    variant === 'submit' ? theme.colors.checked : theme.colors.unchecked};
`;

const FooterButtonText = styled.Text<{ variant: 'submit' | 'dismiss' }>`
  font-family: ${({ theme }) => theme.fonts.monoBold};
  font-size: ${({ theme }) => theme.sizes.fontSizeSmall}px;
  color: ${({ variant, theme }) =>
    variant === 'submit' ? theme.colors.checked : theme.colors.unchecked};
`;

const EmptyText = styled.Text`
  font-family: ${({ theme }) => theme.fonts.mono};
  font-size: ${({ theme }) => theme.sizes.fontSize}px;
  color: ${({ theme }) => theme.colors.hint};
  padding: ${({ theme }) => theme.spacing.md}px;
  text-align: center;
`;

// ── Component ───────────────────────────────────────────────────────

export default function ApprovalSheet() {
  const dispatch = useDispatch();
  const visible = useUIStore((s) => s.approvalVisible);
  const setVisible = useUIStore((s) => s.setApprovalVisible);

  const requests = useSelector((state: RootState) => Object.values(state.approval.byId));
  const activeRequest = useSelector(selectActiveRequest);
  const pendingCount = useSelector(selectPendingCount);

  const [highlightedIndex, setHighlightedIndex] = useState(0);

  // Reset highlighted index when active request changes
  useEffect(() => {
    setHighlightedIndex(0);
  }, [activeRequest?.requestId]);

  // ── Animation ────────────────────────────────────────────────────

  const translateY = useSharedValue(SHEET_HEIGHT);

  useEffect(() => {
    translateY.value = withTiming(visible ? 0 : SHEET_HEIGHT, {
      duration: ANIMATION_DURATION,
      easing: Easing.bezier(0.25, 0.1, 0.25, 1),
    });
  }, [visible, translateY]);

  const animatedStyle = useAnimatedStyle(() => ({
    transform: [{ translateY: translateY.value }],
  }));

  // ── Handlers ─────────────────────────────────────────────────────

  const handleToggleItem = useCallback(
    (itemId: string) => {
      if (!activeRequest) return;
      dispatch(toggleItem({ requestId: activeRequest.requestId, itemId }));
    },
    [dispatch, activeRequest],
  );

  const handleSubmit = useCallback(() => {
    if (!activeRequest) return;

    const selectedItems = activeRequest.items.filter((i) => i.selected);
    const response = {
      requestId: activeRequest.requestId,
      type: activeRequest.type,
      selected: selectedItems.map((i) => ({ id: i.id, label: i.label })),
      notes: activeRequest.notes,
      refine: activeRequest.refine,
    };

    websocketService.sendRequest('approval/respond', response).catch(() => {
      // Error handling done at WS level
    });

    dispatch(removeApproval(activeRequest.requestId));

    // Hide sheet if no more requests
    if (requests.length <= 1) {
      setVisible(false);
    }
  }, [activeRequest, dispatch, requests.length, setVisible]);

  const handleDismiss = useCallback(() => {
    if (!activeRequest) return;
    dispatch(removeApproval(activeRequest.requestId));
    if (requests.length <= 1) {
      setVisible(false);
    }
  }, [activeRequest, dispatch, requests.length, setVisible]);

  const handleNotesChange = useCallback(
    (text: string) => {
      if (!activeRequest) return;
      dispatch(updateNotes({ requestId: activeRequest.requestId, notes: text }));
    },
    [dispatch, activeRequest],
  );

  const handleRefineChange = useCallback(
    (text: string) => {
      if (!activeRequest) return;
      dispatch(updateRefine({ requestId: activeRequest.requestId, refine: text }));
    },
    [dispatch, activeRequest],
  );

  // ── Render ───────────────────────────────────────────────────────

  if (!visible) return null;

  return (
    <>
      <Overlay onPress={() => setVisible(false)} />
      <SheetContainer style={animatedStyle}>
        <SheetHeader>
          <HeaderRow>
            <HeaderTitle>Approvals</HeaderTitle>
            {pendingCount > 0 && (
              <Badge>
                <BadgeText>{pendingCount}</BadgeText>
              </Badge>
            )}
          </HeaderRow>
        </SheetHeader>

        <Body>
          {/* Left panel: request list */}
          <LeftPanel>
            <ScrollView>
              {requests.map((req) => {
                const isActive = req.requestId === activeRequest?.requestId;
                return (
                  <RequestRow
                    key={req.requestId}
                    active={isActive}
                    onPress={() => dispatch(setActiveRequest(req.requestId))}
                  >
                    <RequestRowInner>
                      <RequestIndicator>
                        {isActive ? '\u25B8' : ' '}
                      </RequestIndicator>
                      <RequestLabel active={isActive} numberOfLines={1}>
                        {req.title}
                      </RequestLabel>
                    </RequestRowInner>
                  </RequestRow>
                );
              })}
            </ScrollView>
          </LeftPanel>

          {/* Right panel: active request details */}
          <RightPanel>
            {activeRequest ? (
              <ScrollView>
                <SectionTitle>{activeRequest.title}</SectionTitle>
                {activeRequest.description ? (
                  <DescriptionText>{activeRequest.description}</DescriptionText>
                ) : null}

                {activeRequest.type === 'checklist' ? (
                  <ChecklistView
                    items={activeRequest.items}
                    highlightedIndex={highlightedIndex}
                    onToggle={handleToggleItem}
                  />
                ) : (
                  <ChoiceView
                    items={activeRequest.items}
                    highlightedIndex={highlightedIndex}
                    onSelect={handleToggleItem}
                  />
                )}

                <InputLabel>Notes</InputLabel>
                <StyledInput
                  value={activeRequest.notes ?? ''}
                  onChangeText={handleNotesChange}
                  placeholder="Add notes..."
                  placeholderTextColor="#555555"
                  multiline
                />

                <InputLabel>Refine</InputLabel>
                <StyledInput
                  value={activeRequest.refine ?? ''}
                  onChangeText={handleRefineChange}
                  placeholder="Refine response..."
                  placeholderTextColor="#555555"
                  multiline
                />
              </ScrollView>
            ) : (
              <EmptyText>No pending approvals</EmptyText>
            )}
          </RightPanel>
        </Body>

        <Footer>
          <FooterButton variant="dismiss" onPress={handleDismiss}>
            <FooterButtonText variant="dismiss">Dismiss</FooterButtonText>
          </FooterButton>
          <FooterButton variant="submit" onPress={handleSubmit}>
            <FooterButtonText variant="submit">Submit</FooterButtonText>
          </FooterButton>
        </Footer>
      </SheetContainer>
    </>
  );
}
