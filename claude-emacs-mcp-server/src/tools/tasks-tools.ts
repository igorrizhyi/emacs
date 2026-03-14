import { EmacsBridge } from '../emacs-bridge.js';
import { TasksPutArgs } from '../schemas/tasks-schema.js';

interface TasksPutToolResult {
  content: Array<{ type: 'text'; text: string }>;
  status: 'success' | 'error';
  message?: string;
  isError?: boolean;
}

export async function handleTasksPut(bridge: EmacsBridge, args: TasksPutArgs): Promise<TasksPutToolResult> {
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
    const result = await bridge.request('tasksPut', {
      tasks: args.tasks,
      session_id: args.session_id,
    });

    const success = (result as any).success === true;

    if (!success) {
      return {
        content: [
          {
            type: 'text' as const,
            text: 'Failed to put tasks'
          }
        ],
        status: 'error',
        message: 'Failed to put tasks',
        isError: true
      };
    }

    const count = (result as any).count;

    return {
      content: [
        {
          type: 'text' as const,
          text: `Tasks submitted: ${count ?? args.tasks.length} task(s)`
        }
      ],
      status: 'success',
      message: (result as any).message || 'Tasks submitted'
    };
  } catch (error) {
    return {
      content: [
        {
          type: 'text' as const,
          text: `Error submitting tasks: ${error instanceof Error ? error.message : 'Unknown error'}`
        }
      ],
      status: 'error',
      message: error instanceof Error ? error.message : 'Unknown error',
      isError: true
    };
  }
}
