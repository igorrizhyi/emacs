import React from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { theme } from '../theme';

export default function ProjectSelectorScreen() {
  return (
    <View style={styles.container}>
      <Text style={styles.text}>Project Selector</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: theme.colors.background,
    alignItems: 'center',
    justifyContent: 'center',
  },
  text: {
    color: theme.colors.foreground,
    fontFamily: theme.fonts.mono,
    fontSize: theme.sizes.fontSize,
  },
});
