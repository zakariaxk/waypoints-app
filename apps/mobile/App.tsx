import { useState, useCallback, useEffect } from 'react';
import { StyleSheet, Platform } from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import HomeScreen from './src/screens/HomeScreen';
import SessionScreen from './src/screens/SessionScreen';
import ErrorBoundary from './src/components/ErrorBoundary';
import { getInitialJoinCode, onDeepLink } from './src/utils/deeplink';
import { ThemeProvider, useTheme } from './src/contexts/ThemeContext';

function AppContent() {
  const { isDark, colors } = useTheme();
  const [inSession, setInSession] = useState(false);
  const [pendingJoinCode, setPendingJoinCode] = useState<string | null>(null);

  const handleLeave = useCallback(() => {
    setInSession(false);
  }, []);

  // Handle deep links (cold start + warm start)
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

  return (
    <>
      <StatusBar style={isDark ? 'light' : 'dark'} />
      <SafeAreaView style={[styles.container, { backgroundColor: colors.background }]}>
        {inSession ? (
          <SessionScreen onLeave={handleLeave} />
        ) : (
          <HomeScreen
            onSessionReady={handleSessionReady}
            initialJoinCode={pendingJoinCode}
          />
        )}
      </SafeAreaView>
    </>
  );
}

export default function App() {
  return (
    <SafeAreaProvider>
      <ThemeProvider>
        <ErrorBoundary>
          <AppContent />
        </ErrorBoundary>
      </ThemeProvider>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    paddingTop: Platform.OS === 'android' ? 25 : 0,
  },
});
