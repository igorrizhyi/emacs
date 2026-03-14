import { EmacsBridge } from '../emacs-bridge.js';
import { DismissAgentArgs } from '../schemas/dismiss-agent-schema.js';

interface DismissAgentToolResult {
  content: Array<{ type: 'text'; text: string }>;
  status: 'success' | 'error';
  message?: string;
  isError?: boolean;
}

export async function handleDismissAgent(bridge: EmacsBridge, args: DismissAgentArgs): Promise<DismissAgentToolResult> {
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
    const result = await bridge.request('dismissAgent', {
      target: args.target,
      session_id: args.session_id,
      force: args.force,
    });

    const success = (result as any).success === true;

    if (!success) {
      return {
        content: [
          {
            type: 'text' as const,
            text: (result as any).message || 'Failed to dismiss agent'
          }
        ],
        status: 'error',
        message: (result as any).message || 'Failed to dismiss agent',
        isError: true
      };
    }

    return {
      content: [
        {
          type: 'text' as const,
          text: (result as any).message || `Agent dismissed: ${args.target}`
        }
      ],
      status: 'success',
      message: (result as any).message || 'Agent dismissed'
    };
  } catch (error) {
    return {
      content: [
        {
          type: 'text' as const,
          text: `Error dismissing agent: ${error instanceof Error ? error.message : 'Unknown error'}`
        }
      ],
      status: 'error',
      message: error instanceof Error ? error.message : 'Unknown error',
      isError: true
    };
  }
}
