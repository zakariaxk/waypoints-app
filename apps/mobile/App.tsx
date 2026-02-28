import { useState, useCallback, useEffect } from 'react';
import { StyleSheet, Platform } from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import { LinearGradient } from 'expo-linear-gradient';
import { useFonts } from 'expo-font';
import {
  Rajdhani_400Regular,
  Rajdhani_500Medium,
  Rajdhani_600SemiBold,
  Rajdhani_700Bold,
} from '@expo-google-fonts/rajdhani';
import {
  Orbitron_500Medium,
  Orbitron_700Bold,
} from '@expo-google-fonts/orbitron';

import HomeScreen from './src/screens/HomeScreen';
import SessionScreen from './src/screens/SessionScreen';
import ErrorBoundary from './src/components/ErrorBoundary';
import { getInitialJoinCode, onDeepLink } from './src/utils/deeplink';
import { ThemeProvider, useTheme, gradients } from './src/ui/theme';

function AppContent() {
  const { isDark } = useTheme();
  const [inSession, setInSession] = useState(false);
  const [pendingJoinCode, setPendingJoinCode] = useState<string | null>(null);

  const handleLeave = useCallback(() => {
    setInSession(false);
  }, []);

  useEffect(() => {
    getInitialJoinCode().then((code) => {
      if (code && !inSession) {
        setPendingJoinCode(code);
      }
    });

    const unsub = onDeepLink((code) => {
      if (!inSession) {
        setPendingJoinCode(code);
      }
    });
    return unsub;
  }, [inSession]);

  const handleSessionReady = useCallback(() => {
    setPendingJoinCode(null);
    setInSession(true);
  }, []);

  const bgGradient = isDark ? gradients.background : gradients.backgroundLight;

  return (
    <>
      <StatusBar style={isDark ? 'light' : 'dark'} />
      <LinearGradient
        colors={[...bgGradient] as [string, string, ...string[]]}
        style={styles.gradient}
      >
        <SafeAreaView style={styles.container}>
          {inSession ? (
            <SessionScreen onLeave={handleLeave} />
          ) : (
            <HomeScreen
              onSessionReady={handleSessionReady}
              initialJoinCode={pendingJoinCode}
            />
          )}
        </SafeAreaView>
      </LinearGradient>
    </>
  );
}

export default function App() {
  const [fontsLoaded] = useFonts({
    Rajdhani_400Regular,
    Rajdhani_500Medium,
    Rajdhani_600SemiBold,
    Rajdhani_700Bold,
    Orbitron_500Medium,
    Orbitron_700Bold,
  });

  return (
    <SafeAreaProvider>
      <ThemeProvider fontsLoaded={fontsLoaded}>
        <ErrorBoundary>
          <AppContent />
        </ErrorBoundary>
      </ThemeProvider>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  gradient: {
    flex: 1,
  },
  container: {
    flex: 1,
    paddingTop: Platform.OS === 'android' ? 25 : 0,
  },
});
