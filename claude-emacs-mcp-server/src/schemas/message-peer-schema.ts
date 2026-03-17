import { z } from 'zod';

// Input schema for messageNamespacePeer tool
export const messagePeerInputSchema = z.object({
  target_pid: z.number().describe('Target Emacs process ID'),
  message: z.string().describe('Message content for the target lead'),
});

// Output schema for messageNamespacePeer tool
export const messagePeerOutputSchema = z.object({
  success: z.boolean(),
  message: z.string(),
});

// Inferred types from schemas
export type MessagePeerArgs = z.infer<typeof messagePeerInputSchema>;
export type MessagePeerResult = z.infer<typeof messagePeerOutputSchema>;
