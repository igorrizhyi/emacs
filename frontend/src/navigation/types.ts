export type RootDrawerParamList = {
  Chat: { agentId: string } | undefined;
  ProjectSelector: undefined;
  Notifications: undefined;
};

export type ChatStackParamList = {
  AgentChat: { agentId: string };
  ApprovalDetail: { requestId: string };
};
