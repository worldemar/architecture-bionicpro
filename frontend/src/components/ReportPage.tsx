import React, { useState } from 'react';

interface ReportPageProps {
  auth: {
    authenticated: boolean;
    user: any;
  };
}

const ReportPage: React.FC<ReportPageProps> = ({ auth }) => {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [reportData, setReportData] = useState<any[]>([]);

  const login = () => {
    window.location.href = `${process.env.REACT_APP_API_URL}/auth/login`;
  };

  const logout = () => {
    window.location.href = `${process.env.REACT_APP_API_URL}/auth/logout`;
  };

  const downloadReport = async () => {
    try {
      setLoading(true);
      setError(null);

      const response = await fetch(`${process.env.REACT_APP_API_URL}/reports`, {
        // Куки сессии будут отправлены автоматически
        credentials: 'include',
      });

      if (response.status === 401) {
        setError('Session expired or not authenticated');
        return;
      }

      if (!response.ok) {
        throw new Error('Failed to generate report');
      }

      const result = await response.json();
      setReportData(result.data || []);
      
    } catch (err) {
      setError(err instanceof Error ? err.message : 'An error occurred');
    } finally {
      setLoading(false);
    }
  };

  if (!auth.authenticated) {
    return (
      <div className="flex flex-col items-center justify-center min-h-screen bg-gray-100 px-4">
        <div className="max-w-md w-full bg-white rounded-xl shadow-lg p-10 text-center">
          <h1 className="text-3xl font-extrabold text-gray-900 mb-2">BionicPRO</h1>
          <p className="text-gray-500 mb-8">Service Portal Access</p>
          <button
            onClick={login}
            className="w-full px-6 py-3 bg-indigo-600 text-white font-semibold rounded-lg shadow-md hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2 transition-all"
          >
            Login via SSO
          </button>
          <p className="mt-6 text-xs text-gray-400">
            Для доступа используйте учетные данные Keycloak или LDAP
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col items-center justify-center min-h-screen bg-gray-50 py-12 px-4 sm:px-6 lg:px-8">
      <div className="max-w-4xl w-full bg-white rounded-xl shadow-lg p-8">
        <div className="flex justify-between items-center mb-8 pb-4 border-b">
          <div>
            <h1 className="text-3xl font-extrabold text-gray-900">BionicPRO</h1>
            <p className="text-gray-500">Бионические протезы будущего</p>
          </div>
          <div className="text-right">
            <p className="font-medium text-gray-700">{auth.user?.preferred_username}</p>
            <button onClick={logout} className="text-sm text-red-600 hover:text-red-800 transition-colors">
              Выйти из системы
            </button>
          </div>
        </div>
        
        <div className="mb-10">
          <h2 className="text-xl font-semibold mb-4 text-gray-800">Отчеты по эксплуатации</h2>
          <button
            onClick={downloadReport}
            disabled={loading}
            className={`px-6 py-3 bg-indigo-600 text-white font-semibold rounded-lg shadow-md hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2 transition-all ${
              loading ? 'opacity-50 cursor-not-allowed' : ''
            }`}
          >
            {loading ? 'Загрузка...' : 'Получить актуальные данные'}
          </button>
        </div>

        {error && (
          <div className="mb-6 p-4 bg-red-50 border-l-4 border-red-400 text-red-700 rounded shadow-sm">
            <div className="flex">
              <div className="flex-shrink-0">
                <svg className="h-5 w-5 text-red-400" viewBox="0 0 20 20" fill="currentColor">
                  <path fillRule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clipRule="evenodd" />
                </svg>
              </div>
              <div className="ml-3">
                <p className="text-sm">{error}</p>
              </div>
            </div>
          </div>
        )}

        {reportData.length > 0 ? (
          <div className="overflow-x-auto rounded-lg border border-gray-200 shadow-sm">
            <table className="min-w-full divide-y divide-gray-200">
              <thead className="bg-gray-50">
                <tr>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Дата</th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Протез</th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Жесты</th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Отклик (avg)</th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Батарея (расход)</th>
                </tr>
              </thead>
              <tbody className="bg-white divide-y divide-gray-200">
                {reportData.map((row, i) => (
                  <tr key={i} className="hover:bg-gray-50 transition-colors">
                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900">{row.report_date}</td>
                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500 font-mono">{row.prosthesis_id}</td>
                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900">{row.total_gestures}</td>
                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900">{row.avg_response_time_ms?.toFixed(1) || 0} мс</td>
                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900">{row.battery_usage_pct?.toFixed(1) || 0}%</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : !loading && (
          <div className="text-center py-12 bg-gray-50 rounded-lg border-2 border-dashed border-gray-300">
            <svg className="mx-auto h-12 w-12 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 17v-2m3 2v-4m3 4v-6m2 10H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
            </svg>
            <h3 className="mt-2 text-sm font-medium text-gray-900">Нет данных</h3>
            <p className="mt-1 text-sm text-gray-500">Отчеты за выбранный период еще не сформированы.</p>
          </div>
        )}
      </div>
    </div>
  );
};

export default ReportPage;
