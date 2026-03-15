import React, { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import api from '../utils/api';
import { formatDistanceToNow } from 'date-fns';
import { RocketLaunchIcon, CheckCircleIcon, XCircleIcon, ClockIcon } from '@heroicons/react/24/outline';

function StatCard({ label, value, sub, color = 'text-white' }) {
  return (
    <div className="card">
      <p className="text-xs text-gray-500 uppercase tracking-wider mb-1">{label}</p>
      <p className={`text-3xl font-bold ${color}`}>{value}</p>
      {sub && <p className="text-xs text-gray-500 mt-1">{sub}</p>}
    </div>
  );
}

function BuildRow({ build, projectName }) {
  const badgeClass = {
    success: 'badge-success',
    failure: 'badge-failure',
    running: 'badge-running',
    queued:  'badge-queued',
  }[build.status] || 'badge-queued';

  return (
    <div className="flex items-center gap-3 py-3 border-b border-gray-800 last:border-0">
      <div className="flex-1 min-w-0">
        <p className="text-sm font-medium text-gray-200 truncate">{projectName}</p>
        <p className="text-xs text-gray-500 truncate">{build.commitMessage || 'Manual trigger'}</p>
      </div>
      <span className={badgeClass}>{build.status}</span>
      <span className="text-xs text-gray-600">{formatDistanceToNow(new Date(build.createdAt), { addSuffix: true })}</span>
    </div>
  );
}

export default function DashboardPage() {
  const [projects, setProjects] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    api.get('/pipelines/projects').then(r => {
      setProjects(r.data);
    }).finally(() => setLoading(false));
  }, []);

  const allBuilds = projects
    .flatMap(p => (p.Builds || []).map(b => ({ ...b, projectName: p.name })))
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))
    .slice(0, 10);

  const stats = {
    total:   projects.length,
    active:  projects.filter(p => p.status === 'active').length,
    success: allBuilds.filter(b => b.status === 'success').length,
    failure: allBuilds.filter(b => b.status === 'failure').length,
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-white">Dashboard</h1>
          <p className="text-sm text-gray-500 mt-0.5">Overview of your DevOps platform</p>
        </div>
        <Link to="/projects/new" className="btn-primary">
          <RocketLaunchIcon className="w-4 h-4" /> New Project
        </Link>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard label="Total Projects" value={stats.total} />
        <StatCard label="Active" value={stats.active} color="text-green-400" />
        <StatCard label="Successful Builds" value={stats.success} color="text-green-400" />
        <StatCard label="Failed Builds" value={stats.failure} color="text-red-400" />
      </div>

      <div className="grid lg:grid-cols-2 gap-6">
        {/* Recent builds */}
        <div className="card">
          <h2 className="text-sm font-semibold text-gray-300 mb-4">Recent Builds</h2>
          {loading ? (
            <p className="text-gray-500 text-sm">Loading…</p>
          ) : allBuilds.length === 0 ? (
            <p className="text-gray-500 text-sm">No builds yet. <Link to="/projects/new" className="text-brand-400 hover:underline">Create a project</Link> to get started.</p>
          ) : (
            allBuilds.map(b => <BuildRow key={b.id} build={b} projectName={b.projectName} />)
          )}
        </div>

        {/* Projects list */}
        <div className="card">
          <h2 className="text-sm font-semibold text-gray-300 mb-4">Projects</h2>
          {loading ? (
            <p className="text-gray-500 text-sm">Loading…</p>
          ) : projects.length === 0 ? (
            <p className="text-gray-500 text-sm">No projects yet.</p>
          ) : (
            <div className="space-y-2">
              {projects.map(p => (
                <Link key={p.id} to={`/projects/${p.id}`}
                  className="flex items-center gap-3 p-3 rounded-lg hover:bg-gray-800 transition-colors">
                  <div className="w-8 h-8 rounded-lg bg-brand-600/20 flex items-center justify-center text-brand-400 text-xs font-bold uppercase">
                    {p.name[0]}
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="text-sm font-medium text-gray-200">{p.name}</p>
                    <p className="text-xs text-gray-500">{p.projectType} · {p.branch}</p>
                  </div>
                  <span className={p.status === 'active' ? 'badge-success' : 'badge-queued'}>{p.status}</span>
                </Link>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
