import 'styled-components/native';
import { AppTheme } from '.';

declare module 'styled-components/native' {
  export interface DefaultTheme extends AppTheme {}
}
