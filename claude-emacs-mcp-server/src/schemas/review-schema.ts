import { z } from 'zod';

export const listPendingReviewsInputSchema = z.object({});

export const listPendingReviewsOutputSchema = z.object({
  reviews: z.array(z.object({
    slug: z.string(),
    title: z.string(),
    type: z.string(),
    item_count: z.number(),
    file_path: z.string(),
  })),
  count: z.number(),
});

export type ListPendingReviewsArgs = z.infer<typeof listPendingReviewsInputSchema>;
