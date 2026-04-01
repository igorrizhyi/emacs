export const colors = {
  // Base
  background: '#1a1400',
  surface: '#221c00',
  foreground: '#ffb000',

  // Status
  idle: '#33ff33',
  busy: '#ffb000',
  pending: '#88aaff',
  initializing: '#cc8800',
  dead: '#ff3333',
  reserved: '#aa88ff',

  // UI elements
  barFilled: '#33ff33',      // progress bar OK
  barWarn: '#ffb000',        // progress bar warning
  barCritical: '#ff3333',    // progress bar critical
  barEmpty: '#555555',       // progress bar empty
  separator: '#555555',
  hint: '#666666',

  // Approval
  checked: '#33ff33',
  unchecked: '#888888',
  itemHighlight: '#2a2a00',
  description: '#777777',
  notes: '#aaaaaa',

  // History
  historyHeader: '#806000',
  historySession: '#705500',
  foreignAgent: '#8888bb',

  // Misc
  collapsed: '#2e1e13',
  quotaReset: '#806000',
} as const;
