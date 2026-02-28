import { useState } from 'react';
import { SafeAreaView, StyleSheet } from 'react-native';
import HomeScreen from './src/screens/HomeScreen';
import SessionScreen from './src/screens/SessionScreen';

export default function App() {
  const [inSession, setInSession] = useState(false);

  return (
    <SafeAreaView style={styles.container}>
      {inSession ? (
        <SessionScreen />
      ) : (
        <HomeScreen onSessionReady={() => setInSession(true)} />
      )}
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
  },
});
