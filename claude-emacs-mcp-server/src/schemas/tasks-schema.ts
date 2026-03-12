import { z } from 'zod';

// Input schema for tasksPut tool
export const tasksPutInputSchema = z.object({
  tasks: z.array(z.object({
    role: z.string().describe('Role for the task — "dev", "tester", "researcher"'),
    message: z.string().describe('Task description'),
    group_id: z.string().optional().describe('Batch group ID'),
    request_id: z.string().optional().describe('Custom request ID'),
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
