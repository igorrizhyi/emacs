import type { Middleware } from '@reduxjs/toolkit';
import { wsService } from '../../services/ws';
import { setConnectionStatus, setUrl } from '../slices/connectionSlice';
import { updateTaskStatus, updateGroupProgress } from '../slices/tasksSlice';
import { updateAgent, removeAgent } from '../slices/agentsSlice';
import { addApproval, removeApproval } from '../slices/approvalSlice';
import { addNotification } from '../slices/notificationsSlice';
import {
  appendMessageChunk,
  appendThoughtChunk,
  addToolCall,
  updateToolCall,
  setPlan,
  addPermissionRequest,
} from '../slices/messagesSlice';
import type { ApprovalRequest, ApprovalItem } from '../types';

// ── Action types the middleware listens for ─────────────────────────

export const WS_CONNECT = 'ws/connect' as const;
export const WS_DISCONNECT = 'ws/disconnect' as const;

export interface WsConnectAction {
  type: typeof WS_CONNECT;
  payload: { host: string; sessionId: string };
  [key: string]: unknown;
}

export interface WsDisconnectAction {
  type: typeof WS_DISCONNECT;
  [key: string]: unknown;
}

// Action creators
export const wsConnect = (host: string, sessionId: string): WsConnectAction => ({
  type: WS_CONNECT,
  payload: { host, sessionId },
});

export const wsDisconnect = (): WsDisconnectAction => ({
  type: WS_DISCONNECT,
});

// ── Helpers ──────────────────────────────────────────────────────────

function mapApprovalItem(raw: Record<string, unknown>): ApprovalItem {
  return {
    id: raw['id'] as string,
    label: raw['label'] as string,
    description: raw['description'] as string | undefined,
    defaultSelected: (raw['default_selected'] as boolean) ?? false,
    selected: (raw['default_selected'] as boolean) ?? false,
  };
}

let notificationIdCounter = 0;

// ── Middleware ───────────────────────────────────────────────────────

const unsubscribers: Array<() => void> = [];

function teardown() {
  for (const unsub of unsubscribers) {
    unsub();
  }
  unsubscribers.length = 0;
}

export const websocketMiddleware: Middleware = (storeApi) => {
  let connectedSessionId: string | null = null;

  return (next) => (action: unknown) => {
    const act = action as { type: string; payload?: unknown };

    // ── Auto-connect when activeSessionId is set ──────────────────
    if (act.type === 'sessions/setActiveSession') {
      const sessionId = act.payload as string | null;
      if (sessionId && sessionId !== connectedSessionId) {
        // Default host; callers can dispatch wsConnect() directly for custom hosts
        storeApi.dispatch(wsConnect('localhost:8000', sessionId));
      } else if (!sessionId && connectedSessionId) {
        storeApi.dispatch(wsDisconnect());
      }
    }

    // ── Manual connect ────────────────────────────────────────────
    if (act.type === WS_CONNECT) {
      const { host, sessionId } = (act as WsConnectAction).payload;

      // Tear down any prior connection
      teardown();
      wsService.disconnect();
      connectedSessionId = sessionId;

      const wsUrl = `ws://${host}/ws/${sessionId}`;
      storeApi.dispatch(setUrl(wsUrl));
      wsService.connect(host, sessionId);

      // Subscribe to connection state changes
      unsubscribers.push(
        wsService.onStatusChange((status) => {
          storeApi.dispatch(setConnectionStatus(status));
        }),
      );

      // Route ALL server notifications → Redux actions via single listener
      unsubscribers.push(
        wsService.onNotification((method: string, params: unknown) => {
          const p = (params ?? {}) as Record<string, unknown>;

          switch (method) {
            case 'task/statusChanged': {
              storeApi.dispatch(
                updateTaskStatus({
                  id: p['request_id'] as string,
                  status: p['status'] as string as import('../types').TaskStatus,
                }),
              );
              break;
            }

            case 'task/groupComplete': {
              storeApi.dispatch(
                updateGroupProgress({
                  groupId: p['group_id'] as string,
                  completed: p['completed'] as string[] | undefined,
                }),
              );
              break;
            }

            case 'approval/request': {
              const rawItems =
                (p['items'] as Array<Record<string, unknown>>) ?? [];
              const request: ApprovalRequest = {
                requestId: p['request_id'] as string,
                title: (p['title'] as string) ?? 'Approval',
                type:
                  (p['type'] as 'checklist' | 'choice') ?? 'checklist',
                items: rawItems.map(mapApprovalItem),
                description: p['description'] as string | undefined,
                timestamp: Date.now(),
              };
              storeApi.dispatch(addApproval(request));

              // Toggle approval sheet via Zustand
              try {
                // eslint-disable-next-line @typescript-eslint/no-require-imports
                const { useUIStore } = require('../uiStore') as {
                  useUIStore: {
                    getState: () => {
                      setApprovalVisible: (v: boolean) => void;
                    };
                  };
                };
                useUIStore.getState().setApprovalVisible(true);
              } catch {
                // Zustand store not available — silently ignore
              }
              break;
            }

            case 'approval/cancelled': {
              const requestId = p['request_id'] as string;
              storeApi.dispatch(removeApproval(requestId));
              break;
            }

            case 'notification': {
              const id = `notif-${Date.now()}-${++notificationIdCounter}`;
              storeApi.dispatch(
                addNotification({
                  id,
                  title: (p['title'] as string) ?? '',
                  message: (p['message'] as string) ?? '',
                  type: 'system',
                  timestamp: Date.now(),
                  read: false,
                }),
              );
              break;
            }

            case 'agent/statusChanged': {
              storeApi.dispatch(
                updateAgent({
                  id: p['id'] as string,
                  ...(p['status'] != null && {
                    status: p['status'] as import('../types').AgentStatus,
                  }),
                  ...(p['current_task_id'] !== undefined && {
                    currentTaskId: p['current_task_id'] as string | null,
                  }),
                }),
              );
              break;
            }

            case 'agent/dismissed': {
              storeApi.dispatch(removeAgent(p['id'] as string));
              break;
            }

            case 'agent/session/update': {
              const agentId = p['agent_id'] as string;
              const update = p['update'] as Record<string, unknown> | undefined;
              if (!agentId || !update) break;

              const sessionUpdate = update['sessionUpdate'] as string;
              switch (sessionUpdate) {
                case 'agent_message_chunk': {
                  const content = update['content'] as Record<string, unknown> | undefined;
                  const text = content?.['text'] as string ?? '';
                  storeApi.dispatch(appendMessageChunk({ agentId, text }));
                  break;
                }
                case 'agent_thought_chunk': {
                  const content = update['content'] as Record<string, unknown> | undefined;
                  const text = content?.['text'] as string ?? '';
                  storeApi.dispatch(appendThoughtChunk({ agentId, text }));
                  break;
                }
                case 'tool_call': {
                  const tc = update as Record<string, unknown>;
                  storeApi.dispatch(
                    addToolCall({
                      agentId,
                      toolCall: {
                        toolCallId: tc['toolCallId'] as string,
                        title: tc['title'] as string,
                        status: tc['status'] as string,
                        kind: tc['kind'] as string,
                        rawInput: tc['rawInput'],
                      },
                    }),
                  );
                  break;
                }
                case 'tool_call_update': {
                  const tcu = update as Record<string, unknown>;
                  storeApi.dispatch(
                    updateToolCall({
                      agentId,
                      toolCallId: tcu['toolCallId'] as string,
                      update: {
                        ...(tcu['status'] != null && { status: tcu['status'] as string }),
                        ...(tcu['content'] !== undefined && { content: tcu['content'] }),
                        ...(tcu['title'] != null && { title: tcu['title'] as string }),
                      },
                    }),
                  );
                  break;
                }
                case 'plan': {
                  const entries = update['entries'] as Array<{ status: string; content: string }> ?? [];
                  storeApi.dispatch(setPlan({ agentId, entries }));
                  break;
                }
                default:
                  break;
              }
              break;
            }

            case 'agent/session/request_permission': {
              const agentId = p['agent_id'] as string;
              if (!agentId) break;
              storeApi.dispatch(
                addPermissionRequest({
                  agentId,
                  request: {
                    toolCallId: p['toolCallId'] as string,
                    title: p['title'] as string,
                    description: p['description'] as string,
                  },
                }),
              );
              break;
            }

            default:
              break;
          }
        }),
      );
    }

    // ── Manual disconnect ─────────────────────────────────────────
    if (act.type === WS_DISCONNECT) {
      teardown();
      wsService.disconnect();
      connectedSessionId = null;
      storeApi.dispatch(setUrl(null));
    }

    return next(action);
  };
};
