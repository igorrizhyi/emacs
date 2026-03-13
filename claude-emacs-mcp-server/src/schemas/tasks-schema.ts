import { z } from 'zod';

// Input schema for tasksPut tool
export const tasksPutInputSchema = z.object({
  tasks: z.array(z.object({
    role: z.string().describe('Role for the task — "dev", "tester", "researcher"'),
    message: z.string().describe('Task description'),
    group_id: z.string().optional().describe('Batch group ID'),
    request_id: z.string().optional().describe('Custom request ID'),
    target: z.string().optional().describe('Buffer name or worktree name of a specific agent to assign this task to'),
  })).describe('Array of tasks to assign'),
  session_id: z.string().optional().describe('Team session ID for multi-session routing'),
});

// Output schema for tasksPut tool
export const tasksPutOutputSchema = z.object({
  success: z.boolean(),
  message: z.string(),
  count: z.number().optional(),
});

// Inferred types from schemas
export type TasksPutArgs = z.infer<typeof tasksPutInputSchema>;
export type TasksPutResult = z.infer<typeof tasksPutOutputSchema>;
