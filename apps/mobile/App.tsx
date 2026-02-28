import { useState, useCallback } from 'react';
import { SafeAreaView, StyleSheet } from 'react-native';
import HomeScreen from './src/screens/HomeScreen';
import SessionScreen from './src/screens/SessionScreen';
import ErrorBoundary from './src/components/ErrorBoundary';

export default function App() {
  const [inSession, setInSession] = useState(false);

  const handleLeave = useCallback(() => {
    setInSession(false);
  }, []);

  return (
    <ErrorBoundary>
      <SafeAreaView style={styles.container}>
        {inSession ? (
          <SessionScreen onLeave={handleLeave} />
        ) : (
          <HomeScreen onSessionReady={() => setInSession(true)} />
        )}
      </SafeAreaView>
    </ErrorBoundary>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
  },
});
