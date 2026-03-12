import { z } from 'zod';

// Input schema for taskUpdate tool
export const taskUpdateInputSchema = z.object({
  request_id: z.string().describe('Request ID from the original tasksPut assignment'),
  status: z.enum(['finished', 'updated', 'blocked']).describe('Task status'),
  content: z.string().describe('What was done, problems encountered, results'),
  commit: z.string().optional().describe('Commit hash if code was committed'),
  report_path: z.string().optional().describe('Path to detailed report file'),
  session_id: z.string().optional().describe('Team session ID for multi-session routing'),
});

// Output schema for taskUpdate tool
export const taskUpdateOutputSchema = z.object({
  success: z.boolean(),
  message: z.string(),
});

// Inferred types from schemas
export type TaskUpdateArgs = z.infer<typeof taskUpdateInputSchema>;
export type TaskUpdateResult = z.infer<typeof taskUpdateOutputSchema>;
