import React from 'react';
import { NavigationContainer, DefaultTheme } from '@react-navigation/native';
import { createDrawerNavigator } from '@react-navigation/drawer';
import { theme } from '../theme';
import { TeamSidebar } from '../components/sidebar';
import ChatScreen from '../screens/ChatScreen';
import AgentChatScreen from '../screens/AgentChatScreen';
import ProjectSelectorScreen from '../screens/ProjectSelectorScreen';
import NotificationsScreen from '../screens/NotificationsScreen';
import SettingsScreen from '../screens/SettingsScreen';
import NotificationBanner from '../components/NotificationBanner';

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
      <NotificationBanner />
      <Drawer.Navigator
        drawerContent={(props) => <TeamSidebar {...props} />}
        screenOptions={{
          drawerPosition: 'left',
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
        <Drawer.Screen
          name="AgentChat"
          component={AgentChatScreen}
          options={{ drawerItemStyle: { display: 'none' } }}
        />
        <Drawer.Screen name="ProjectSelector" component={ProjectSelectorScreen} />
        <Drawer.Screen name="Notifications" component={NotificationsScreen} />
        <Drawer.Screen name="Settings" component={SettingsScreen} />
      </Drawer.Navigator>
    </NavigationContainer>
  );
}
