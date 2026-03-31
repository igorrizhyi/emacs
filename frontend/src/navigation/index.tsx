import React from 'react';
import { NavigationContainer, DefaultTheme } from '@react-navigation/native';
import { createDrawerNavigator } from '@react-navigation/drawer';
import { theme } from '../theme';
import ChatScreen from '../screens/ChatScreen';
import ProjectSelectorScreen from '../screens/ProjectSelectorScreen';

const Drawer = createDrawerNavigator();

const navTheme = {
  ...DefaultTheme,
  dark: true,
  colors: {
    ...DefaultTheme.colors,
    background: theme.colors.background,
    card: theme.colors.surface,
    text: theme.colors.foreground,
    border: theme.colors.separator,
    primary: theme.colors.foreground,
  },
};

export default function RootNavigator() {
  return (
    <NavigationContainer theme={navTheme}>
      <Drawer.Navigator
        screenOptions={{
          drawerPosition: 'right',
          drawerStyle: {
            backgroundColor: theme.colors.background,
            width: theme.sizes.sidebarWidth,
          },
          headerStyle: {
            backgroundColor: theme.colors.surface,
          },
          headerTintColor: theme.colors.foreground,
        }}
      >
        <Drawer.Screen name="Chat" component={ChatScreen} />
        <Drawer.Screen name="ProjectSelector" component={ProjectSelectorScreen} />
      </Drawer.Navigator>
    </NavigationContainer>
  );
}
