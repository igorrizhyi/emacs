export type RootDrawerParamList = {
  Chat: { agentId: string } | undefined;
  ProjectSelector: undefined;
};

export type ChatStackParamList = {
  AgentChat: { agentId: string };
  ApprovalDetail: { requestId: string };
};
