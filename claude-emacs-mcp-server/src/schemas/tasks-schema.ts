import { z } from 'zod';

// Input schema for tasksPut tool
export const tasksPutInputSchema = z.object({
  tasks: z.array(z.object({
    role: z.string().describe('Role for the task — "dev", "tester", "researcher"'),
    message: z.string().describe('Task description'),
    group_id: z.string().optional().describe('Batch group ID'),
    request_id: z.string().optional().describe('Custom request ID'),
    target: z.string().optional().describe('Buffer name or worktree name of a specific agent to assign this task to'),
    priority: z.enum(["normal", "interrupt"]).optional().describe('Priority level. "interrupt" delivers to busy agent immediately when they finish current turn'),
    model: z.string().optional().describe('Model override for the spawned agent (e.g. "gemini-2.5-flash-lite"). When set, a new agent is spawned with this model instead of the role default.'),
  })).describe('Array of tasks to assign'),
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
