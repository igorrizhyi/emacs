import { EmacsBridge } from '../emacs-bridge.js';
import { MessagePeerArgs } from '../schemas/message-peer-schema.js';

interface MessagePeerToolResult {
  content: Array<{ type: 'text'; text: string }>;
  status: 'success' | 'error';
  message?: string;
  isError?: boolean;
}

export async function handleMessagePeer(bridge: EmacsBridge, args: MessagePeerArgs): Promise<MessagePeerToolResult> {
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
    const result = await bridge.request('messageNamespacePeer', {
      target_pid: args.target_pid,
      message: args.message,
    });

    const data = result as { success: boolean; message: string };

    if (!data.success) {
      return {
        content: [
          {
            type: 'text' as const,
            text: data.message || 'Failed to send message to peer'
          }
        ],
        status: 'error',
        message: data.message || 'Failed to send message to peer',
        isError: true
      };
    }

    return {
      content: [
        {
          type: 'text' as const,
          text: data.message
        }
      ],
      status: 'success',
      message: data.message
    };
  } catch (error) {
    return {
      content: [
        {
          type: 'text' as const,
          text: `Error sending message to peer: ${error instanceof Error ? error.message : 'Unknown error'}`
        }
      ],
      status: 'error',
      message: error instanceof Error ? error.message : 'Unknown error',
      isError: true
    };
  }
}
