import { z } from 'zod';

// Updated executeTerminalCommandInEmacs to support terminal IDs and instance ID
export const executeTerminalCommandInEmacsInputSchema = z.object({
  terminalId: z.string()
    .min(1, 'Terminal ID cannot be empty')
    .regex(/^term-\d+$/, 'Terminal ID must match pattern term-<number>')
    .optional(),
  command: z.string()
    .min(1, 'Command cannot be empty')
    .max(1000, 'Command too long (max 1000 characters)'),
  workingDirectory: z.string().optional(),
  projectRoot: z.string().optional(),
  timeout: z.number()
    .int()
    .min(1, 'Timeout must be at least 1 second')
    .max(300, 'Timeout cannot exceed 300 seconds')
    .default(30)
    .optional(),
  emacs_instance_id: z.number().int().positive().optional()
});

export const executeTerminalCommandInEmacsOutputSchema = z.object({
  success: z.boolean(),
  message: z.string().optional(),
  terminalId: z.string().optional(),
  command: z.string(),
  stdout: z.string(),
  stderr: z.string(),
  exitCode: z.number().int(),
  timeout: z.boolean(),
  workingDirectory: z.string(),
  error: z.string().optional()
});

// getTerminalContent
export const getTerminalContentInputSchema = z.object({
  terminalId: z.string()
    .min(1, 'Terminal ID cannot be empty')
    .regex(/^term-\d+$/, 'Terminal ID must match pattern term-<number>'),
  projectRoot: z.string().optional(),
  emacs_instance_id: z.number().int().positive().optional()
});

export const getTerminalContentOutputSchema = z.object({
  success: z.boolean(),
  content: z.string().optional(),
  terminalId: z.string(),
  error: z.string().optional()
});

// createTerminal
export const createTerminalInputSchema = z.object({
  directory: z.string().optional(),
  projectRoot: z.string().optional(),
  emacs_instance_id: z.number().int().positive().optional()
});

export const createTerminalOutputSchema = z.object({
  success: z.boolean(),
  terminalId: z.string().optional(),
  message: z.string().optional(),
  directory: z.string().optional(),
  error: z.string().optional()
});

// Type exports
export type TerminalCommandArgs = z.infer<typeof executeTerminalCommandInEmacsInputSchema>;
export type TerminalCommandResult = z.infer<typeof executeTerminalCommandInEmacsOutputSchema>;

export type GetTerminalContentArgs = z.infer<typeof getTerminalContentInputSchema>;
export type GetTerminalContentResult = z.infer<typeof getTerminalContentOutputSchema>;

export type CreateTerminalArgs = z.infer<typeof createTerminalInputSchema>;
export type CreateTerminalResult = z.infer<typeof createTerminalOutputSchema>;