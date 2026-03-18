import { EmacsBridge } from '../emacs-bridge.js';
import { PresentOptionsArgs } from '../schemas/approval-schema.js';

interface PresentOptionsToolResult {
  content: Array<{ type: 'text'; text: string }>;
  status: 'success' | 'error';
  message?: string;
  isError?: boolean;
}

export async function handlePresentOptions(bridge: EmacsBridge, args: PresentOptionsArgs): Promise<PresentOptionsToolResult> {
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
