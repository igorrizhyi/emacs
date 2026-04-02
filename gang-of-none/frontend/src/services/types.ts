/**
 * Re-export all types from the canonical store types.
 * This file exists for backwards compatibility — prefer importing from '@/store/types'.
 */
export type {
  AgentRole,
  AgentStatus,
  TaskStatus,
  TaskPriority,
  ApprovalType,
  Session,
  Agent,
  Task,
  TaskCreate,
  TaskUpdate,
  TaskGroup,
  ApprovalItem,
  ApprovalRequest,
  ApprovalSubmitRequest,
  Peer,
  PeerMessageRequest,
  Report,
  SuccessResponse,
  SessionCreateRequest,
  SessionListResponse,
  AgentListResponse,
  TaskListResponse,
  ApprovalListResponse,
  PeerListResponse,
  DismissAgentParams,
  SendNotificationParams,
  PresentOptionsParams,
  MessagePeerParams,
} from '@/store/types';
