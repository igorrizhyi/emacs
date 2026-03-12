import { EmacsBridge } from '../emacs-bridge.js';
import { TaskUpdateArgs } from '../schemas/task-update-schema.js';

interface TaskUpdateToolResult {
  content: Array<{ type: 'text'; text: string }>;
  status: 'success' | 'error';
  message?: string;
  isError?: boolean;
}

export async function handleTaskUpdate(bridge: EmacsBridge, args: TaskUpdateArgs): Promise<TaskUpdateToolResult> {
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
    const result = await bridge.request('taskUpdate', {
      request_id: args.request_id,
      status: args.status,
      content: args.content,
      commit: args.commit,
      report_path: args.report_path,
    });

    const success = (result as any).success === true;

    if (!success) {
      return {
        content: [
          {
            type: 'text' as const,
            text: 'Failed to submit task update'
          }
        ],
        status: 'error',
        message: 'Failed to submit task update',
        isError: true
      };
    }

    return {
      content: [
        {
          type: 'text' as const,
          text: `Task update received for ${args.request_id}`
        }
      ],
      status: 'success',
      message: (result as any).message || 'Task update received'
    };
  } catch (error) {
    return {
      content: [
        {
          type: 'text' as const,
          text: `Error submitting task update: ${error instanceof Error ? error.message : 'Unknown error'}`
        }
      ],
      status: 'error',
      message: error instanceof Error ? error.message : 'Unknown error',
      isError: true
    };
  }
}
