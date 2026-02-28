import { useState, useCallback, useEffect } from 'react';
import { SafeAreaView, StyleSheet, Platform } from 'react-native';
import { StatusBar } from 'expo-status-bar';
import HomeScreen from './src/screens/HomeScreen';
import SessionScreen from './src/screens/SessionScreen';
import ErrorBoundary from './src/components/ErrorBoundary';
import { getInitialJoinCode, onDeepLink } from './src/utils/deeplink';

export default function App() {
  const [inSession, setInSession] = useState(false);
  const [pendingJoinCode, setPendingJoinCode] = useState<string | null>(null);

  const handleLeave = useCallback(() => {
    setInSession(false);
  }, []);

  // Handle deep links (cold start + warm start)
  useEffect(() => {
    // Cold start: app opened via deep link
    getInitialJoinCode().then((code) => {
      if (code && !inSession) {
        setPendingJoinCode(code);
      }
    });

    // Warm start: app already open, link tapped
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
    <ErrorBoundary>
      <StatusBar style="dark" />
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
    </ErrorBoundary>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
    paddingTop: Platform.OS === 'android' ? 25 : 0,
  },
});
