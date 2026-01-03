import React, { useEffect, useState } from 'react';
import ReportPage from './components/ReportPage';

const App: React.FC = () => {
  const [authState, setAuthState] = useState<{
    initialized: boolean;
    authenticated: boolean;
    user: any;
  }>({
    initialized: false,
    authenticated: false,
    user: null,
  });

  useEffect(() => {
    // Проверяем статус аутентификации через BFF
    fetch(`${process.env.REACT_APP_API_URL}/auth/me`, {
      headers: { 'Accept': 'application/json' },
      credentials: 'include',
    })
      .then(res => res.json())
      .then(data => {
        setAuthState({
          initialized: true,
          authenticated: data.authenticated,
          user: data.user,
        });
      })
      .catch(() => {
        setAuthState(prev => ({ ...prev, initialized: true }));
      });
  }, []);

  if (!authState.initialized) {
    return <div className="flex items-center justify-center min-h-screen">Loading...</div>;
  }

  return (
    <div className="App">
      <ReportPage auth={authState} />
    </div>
  );
};

export default App;
