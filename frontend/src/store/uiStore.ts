import { create } from 'zustand';

interface UIState {
  sidebarOpen: boolean;
  activeAgentId: string | null;
  activeSessionId: string | null;
  approvalVisible: boolean;
  toggleSidebar: () => void;
  setActiveAgent: (id: string | null) => void;
  setActiveSession: (id: string | null) => void;
  setApprovalVisible: (visible: boolean) => void;
}

export const useUIStore = create<UIState>((set) => ({
  sidebarOpen: false,
  activeAgentId: null,
  activeSessionId: null,
  approvalVisible: false,
  toggleSidebar: () => set((s) => ({ sidebarOpen: !s.sidebarOpen })),
  setActiveAgent: (id) => set({ activeAgentId: id }),
  setActiveSession: (id) => set({ activeSessionId: id }),
  setApprovalVisible: (visible) => set({ approvalVisible: visible }),
}));
