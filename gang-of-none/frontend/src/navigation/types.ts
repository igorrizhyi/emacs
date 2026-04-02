export type RootDrawerParamList = {
  Chat: { agentId: string } | undefined;
  ProjectSelector: undefined;
  Notifications: undefined;
  Settings: undefined;
};

export type ChatStackParamList = {
  AgentChat: { agentId: string };
  ApprovalDetail: { requestId: string };
};
