import * as fs from 'fs';
import * as path from 'path';

interface ReviewEntry {
  slug: string;
  title: string;
  type: string;
  item_count: number;
  file_path: string;
}

interface ListPendingReviewsResult {
  content: Array<{ type: 'text'; text: string }>;
  reviews: ReviewEntry[];
  count: number;
  isError?: boolean;
}

export function handleListPendingReviews(projectRoot: string): ListPendingReviewsResult {
  const reviewsDir = path.join(projectRoot, '.agent-shell', 'reviews');

  if (!fs.existsSync(reviewsDir)) {
    return {
      content: [{ type: 'text' as const, text: 'No pending reviews.' }],
      reviews: [],
      count: 0,
    };
  }

  const files = fs.readdirSync(reviewsDir).filter(f => f.endsWith('.md'));
  const reviews: ReviewEntry[] = files.map(f => {
    const filePath = path.join(reviewsDir, f);
    const content = fs.readFileSync(filePath, 'utf-8');
    const titleMatch = content.match(/^# (.+)$/m);
    const typeMatch = content.match(/<!-- type: (choice|checklist) -->/);
    const items = content.match(/^- \[[ x]\]/gm) || [];
    return {
      slug: f.replace('.md', ''),
      title: titleMatch?.[1] || 'Untitled',
      type: typeMatch?.[1] || 'checklist',
      item_count: items.length,
      file_path: filePath,
    };
  });

  const summary = reviews.length > 0
    ? `Found ${reviews.length} pending review(s): ${reviews.map(r => r.slug).join(', ')}`
    : 'No pending reviews.';

  return {
    content: [{ type: 'text' as const, text: summary }],
    reviews,
    count: reviews.length,
  };
}
