import { z } from 'zod';

export const presentOptionsInputSchema = z.object({
  request_id: z.string().describe('Unique ID for this approval request'),
  title: z.string().describe('Short title for the task list panel'),
  description: z.string().optional().describe('Longer description shown above options'),
  type: z.enum(['checklist', 'choice']).describe('checklist = multi-select, choice = single-select'),
  items: z.array(z.object({
    id: z.string().describe('Unique item identifier'),
    label: z.string().describe('Display label'),
    description: z.string().optional().describe('Description shown below label'),
    default_selected: z.boolean().optional().describe('Pre-selected state'),
  })).min(1).describe('Options to present'),
});

export const presentOptionsOutputSchema = z.object({
  success: z.boolean(),
  message: z.string(),
});

export type PresentOptionsArgs = z.infer<typeof presentOptionsInputSchema>;
