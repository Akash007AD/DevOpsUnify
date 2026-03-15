import React, { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import api from '../utils/api';
import { ChartBarIcon } from '@heroicons/react/24/outline';

function MetricCard({ label, value, unit = '' }) {
  return (
    <div className="card py-3">
      <p className="text-xs text-gray-500">{label}</p>
      <p className="text-xl font-bold text-white mt-0.5">
        {value !== null && value !== undefined ? `${parseFloat(value).toFixed(2)}${unit}` : '–'}
      </p>
    </div>
  );
}

function ProjectMonitor({ project }) {
  const [metrics, setMetrics] = useState(null);
  const [dashUrl, setDashUrl] = useState('');

  useEffect(() => {
    api.get(`/monitoring/projects/${project.id}/metrics`)
      .then(r => setMetrics(r.data))
      .catch(() => setMetrics(null));

    if (project.grafanaDashboardUid) {
      api.get(`/monitoring/projects/${project.id}/dashboard`)
        .then(r => setDashUrl(r.data.url))
        .catch(() => {});
    }
  }, [project.id]);

  return (
    <div className="card space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-sm font-semibold text-white">{project.name}</h2>
          <p className="text-xs text-gray-500">{project.projectType} · {project.k8sNamespace}</p>
        </div>
        {dashUrl && (
          <a href={dashUrl} target="_blank" rel="noopener noreferrer" className="btn-secondary py-1.5 px-3 text-xs">
            <ChartBarIcon className="w-3.5 h-3.5" /> Open Grafana
          </a>
        )}
      </div>

      <div className="grid grid-cols-3 gap-3">
        <MetricCard label="CPU Cores" value={metrics?.cpu} unit=" cores" />
        <MetricCard label="Memory" value={metrics?.memory ? (metrics.memory / 1024 / 1024).toFixed(0) : null} unit=" MB" />
        <MetricCard label="Pods Running" value={metrics?.pods} />
      </div>

      {dashUrl && (
        <div className="rounded-lg overflow-hidden border border-gray-800" style={{ height: 300 }}>
          <iframe
            src={`${dashUrl}?orgId=1&refresh=10s&theme=dark&kiosk=tv`}
            className="w-full h-full"
            frameBorder="0"
            title={`${project.name} dashboard`}
          />
        </div>
      )}
    </div>
  );
}

export default function MonitoringPage() {
  const [projects, setProjects] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    api.get('/pipelines/projects')
      .then(r => setProjects(r.data.filter(p => p.status === 'active')))
      .finally(() => setLoading(false));
  }, []);

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-xl font-semibold text-white">Monitoring</h1>
        <p className="text-sm text-gray-500 mt-0.5">Prometheus metrics and Grafana dashboards</p>
      </div>

      {loading ? (
        <p className="text-gray-500 text-sm">Loading…</p>
      ) : projects.length === 0 ? (
        <div className="card text-center py-12">
          <p className="text-gray-400 mb-2">No active projects to monitor</p>
          <Link to="/projects/new" className="text-brand-400 text-sm hover:underline">Create a project first</Link>
        </div>
      ) : (
        <div className="space-y-6">
          {projects.map(p => <ProjectMonitor key={p.id} project={p} />)}
        </div>
      )}
    </div>
  );
}
