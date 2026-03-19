import * as fs from 'fs';
import * as path from 'path';
import { EmacsBridge } from '../emacs-bridge.js';
import { PresentOptionsArgs } from '../schemas/approval-schema.js';

interface PresentOptionsToolResult {
  content: Array<{ type: 'text'; text: string }>;
  status: 'success' | 'error';
  message?: string;
  isError?: boolean;
}

function writeReviewMarkdown(projectRoot: string, args: PresentOptionsArgs): void {
  const reviewsDir = path.join(projectRoot, '.agent-shell', 'reviews');
  fs.mkdirSync(reviewsDir, { recursive: true });

  const lines: string[] = [];
  lines.push(`# ${args.title}`);
  lines.push(`<!-- type: ${args.type} -->`);
  if (args.description) {
    lines.push(`> ${args.description}`);
  }
  lines.push('');
  for (const item of args.items) {
    const checked = item.default_selected ? 'x' : ' ';
    lines.push(`- [${checked}] ${item.label} <!-- id: ${item.id} -->`);
    if (item.description) {
      lines.push(`  ${item.description}`);
    }
  }
  lines.push('');

  const filePath = path.join(reviewsDir, `${args.request_id}.md`);
  fs.writeFileSync(filePath, lines.join('\n'), 'utf-8');
}

export async function handlePresentOptions(bridge: EmacsBridge, args: PresentOptionsArgs, projectRoot?: string): Promise<PresentOptionsToolResult> {
  // Write markdown review file before forwarding to Emacs
  if (projectRoot) {
    try {
      writeReviewMarkdown(projectRoot, args);
    } catch (_err) {
      // Non-fatal: continue with bridge call even if file write fails
    }
  }

  if (!bridge.isConnected()) {
    return {
      content: [
        {
          type: 'text' as const,
          text: 'Error: Emacs is not connected'
        }
      ],
      status: 'error',
      message: 'Emacs is not connected',
      isError: true
    };
  }

  try {
    const result = await bridge.request('presentOptions', args);

    const success = (result as any).success === true;

    if (!success) {
      return {
        content: [
          {
            type: 'text' as const,
            text: 'Failed to present options'
          }
        ],
        status: 'error',
        message: 'Failed to present options',
        isError: true
      };
    }

    return {
      content: [
        {
          type: 'text' as const,
          text: (result as any).message || 'Options presented successfully'
        }
      ],
      status: 'success',
      message: (result as any).message || 'Options presented successfully'
    };
  } catch (error) {
    return {
      content: [
        {
          type: 'text' as const,
          text: `Error presenting options: ${error instanceof Error ? error.message : 'Unknown error'}`
        }
      ],
      status: 'error',
      message: error instanceof Error ? error.message : 'Unknown error',
      isError: true
    };
  }
}
