import React from 'react';
import { ThemeProvider } from 'styled-components/native';
import { Provider as ReduxProvider } from 'react-redux';
import { store } from './store';
import { theme } from './theme';
import RootNavigator from './navigation';

export default function App() {
  return (
    <ReduxProvider store={store}>
      <ThemeProvider theme={theme}>
        <RootNavigator />
      </ThemeProvider>
    </ReduxProvider>
  );
}
