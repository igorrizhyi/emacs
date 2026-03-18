import { z } from 'zod';

// Input schema for listNamespacePeers tool
export const listNamespacePeersInputSchema = z.object({});

// Output schema for listNamespacePeers tool
export const listNamespacePeersOutputSchema = z.object({
  success: z.boolean(),
  message: z.string().optional(),
  peers: z.array(z.object({
    pid: z.number(),
    hostname: z.string(),
    project_root: z.string(),
  })).optional(),
  count: z.number().optional(),
});

// Inferred types from schemas
export type ListNamespacePeersArgs = z.infer<typeof listNamespacePeersInputSchema>;
export type ListNamespacePeersResult = z.infer<typeof listNamespacePeersOutputSchema>;
