import { EmacsBridge } from '../emacs-bridge.js';

interface ListNamespacePeersToolResult {
  content: Array<{ type: 'text'; text: string }>;
  status: 'success' | 'error';
  message?: string;
  success?: boolean;
  peers?: Array<{ pid: number; hostname: string; project_root: string }>;
  count?: number;
  isError?: boolean;
}

export async function handleListNamespacePeers(bridge: EmacsBridge, _args: Record<string, unknown>): Promise<ListNamespacePeersToolResult> {
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
    const result = await bridge.request('listNamespacePeers', {});

    const data = result as {
      success: boolean;
      message?: string;
      peers?: Array<{ pid: number; hostname: string; project_root: string }>;
      count?: number;
    };

    if (!data.success) {
      return {
        content: [
          {
            type: 'text' as const,
            text: data.message || 'Failed to list namespace peers'
          }
        ],
        status: 'error',
        message: data.message || 'Failed to list namespace peers',
        isError: true
      };
    }

    const peers = data.peers || [];
    const count = data.count ?? peers.length;
    const text = count > 0
      ? `Found ${count} namespace peer(s):\n${peers.map(p => `- PID ${p.pid}: ${p.hostname} (${p.project_root})`).join('\n')}`
      : data.message || 'No namespace peers found';

    return {
      content: [
        {
          type: 'text' as const,
          text
        }
      ],
      status: 'success',
      success: true,
      message: data.message,
      peers,
      count,
    };
  } catch (error) {
    return {
      content: [
        {
          type: 'text' as const,
          text: `Error listing namespace peers: ${error instanceof Error ? error.message : 'Unknown error'}`
        }
      ],
      status: 'error',
      message: error instanceof Error ? error.message : 'Unknown error',
      isError: true
    };
  }
}
