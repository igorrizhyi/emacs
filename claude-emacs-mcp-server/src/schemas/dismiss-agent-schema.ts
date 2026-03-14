import { z } from 'zod';

// Input schema for dismissAgent tool
export const dismissAgentInputSchema = z.object({
  target: z.string().describe('Buffer name or worktree name of the agent to dismiss'),
  session_id: z.string().optional().describe('Team session ID for multi-session routing'),
  force: z.boolean().optional().describe('Force dismiss even if agent is busy or initializing'),
});

// Output schema for dismissAgent tool
export const dismissAgentOutputSchema = z.object({
  success: z.boolean(),
  message: z.string(),
});

// Inferred types from schemas
export type DismissAgentArgs = z.infer<typeof dismissAgentInputSchema>;
export type DismissAgentResult = z.infer<typeof dismissAgentOutputSchema>;
