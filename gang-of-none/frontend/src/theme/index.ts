import { colors } from './colors';

export const theme = {
  colors,
  fonts: {
    mono: 'RobotoMono-Regular',
    monoBold: 'RobotoMono-Bold',
    monoItalic: 'RobotoMono-Italic',
  },
  spacing: {
    xs: 4,
    sm: 8,
    md: 16,
    lg: 24,
  },
  sizes: {
    sidebarWidth: 300,
    approvalHeight: 400,
    fontSize: 14,
    fontSizeSmall: 12,
    fontSizeLarge: 16,
  },
} as const;

export type AppTheme = typeof theme;
