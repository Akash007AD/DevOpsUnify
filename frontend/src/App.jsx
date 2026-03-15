import React, { useEffect } from 'react';
import { Routes, Route, Navigate } from 'react-router-dom';
import useAuthStore from './context/authStore';

import LoginPage       from './pages/LoginPage';
import AuthCallback    from './pages/AuthCallback';
import DashboardPage   from './pages/DashboardPage';
import ProjectsPage    from './pages/ProjectsPage';
import NewProjectPage  from './pages/NewProjectPage';
import ProjectDetail   from './pages/ProjectDetail';
import BuildDetail     from './pages/BuildDetail';
import InfraPage       from './pages/InfraPage';
import MonitoringPage  from './pages/MonitoringPage';
import Layout          from './components/common/Layout';

function RequireAuth({ children }) {
  const { token, user, loading } = useAuthStore();
  if (loading) return <div className="flex items-center justify-center h-screen text-gray-400">Loading…</div>;
  if (!token || !user) return <Navigate to="/login" replace />;
  return children;
}

export default function App() {
  const { fetchMe, token } = useAuthStore();

  useEffect(() => { if (token) fetchMe(); else useAuthStore.setState({ loading: false }); }, [token]);

  return (
    <Routes>
      <Route path="/login"         element={<LoginPage />} />
      <Route path="/auth/callback" element={<AuthCallback />} />

      <Route path="/" element={<RequireAuth><Layout /></RequireAuth>}>
        <Route index                         element={<DashboardPage />} />
        <Route path="projects"               element={<ProjectsPage />} />
        <Route path="projects/new"           element={<NewProjectPage />} />
        <Route path="projects/:id"           element={<ProjectDetail />} />
        <Route path="projects/:id/builds/:buildId" element={<BuildDetail />} />
        <Route path="infra"                  element={<InfraPage />} />
        <Route path="monitoring"             element={<MonitoringPage />} />
      </Route>

      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
