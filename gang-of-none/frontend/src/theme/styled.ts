import 'styled-components/native';
import { AppTheme } from '.';

declare module 'styled-components/native' {
  export interface DefaultTheme {
    colors: AppTheme['colors'];
    fonts: AppTheme['fonts'];
    spacing: AppTheme['spacing'];
    sizes: AppTheme['sizes'];
  }
}
