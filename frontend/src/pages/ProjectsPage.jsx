import React, { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import api from '../utils/api';
import { PlusIcon } from '@heroicons/react/24/outline';
import { formatDistanceToNow } from 'date-fns';

const STATUS_BADGE = {
  active:       'badge-success',
  pending:      'badge-queued',
  provisioning: 'badge-running',
  failed:       'badge-failure',
};

export default function ProjectsPage() {
  const [projects, setProjects] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    api.get('/pipelines/projects').then(r => setProjects(r.data)).finally(() => setLoading(false));
  }, []);

  return (
    <div className="space-y-5">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-white">Projects</h1>
          <p className="text-sm text-gray-500 mt-0.5">{projects.length} project{projects.length !== 1 ? 's' : ''}</p>
        </div>
        <Link to="/projects/new" className="btn-primary">
          <PlusIcon className="w-4 h-4" /> New Project
        </Link>
      </div>

      {loading ? (
        <div className="card text-gray-500 text-sm">Loading…</div>
      ) : projects.length === 0 ? (
        <div className="card text-center py-12">
          <p className="text-gray-400 mb-3">No projects yet</p>
          <Link to="/projects/new" className="btn-primary">
            <PlusIcon className="w-4 h-4" /> Create your first project
          </Link>
        </div>
      ) : (
        <div className="grid gap-4">
          {projects.map(p => {
            const lastBuild = p.Builds?.[0];
            return (
              <Link key={p.id} to={`/projects/${p.id}`} className="card hover:border-gray-700 transition-colors block">
                <div className="flex items-start gap-4">
                  <div className="w-10 h-10 rounded-xl bg-brand-600/20 flex items-center justify-center text-brand-400 font-bold uppercase shrink-0">
                    {p.name[0]}
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 flex-wrap">
                      <h2 className="text-sm font-semibold text-white">{p.name}</h2>
                      <span className={STATUS_BADGE[p.status] || 'badge-queued'}>{p.status}</span>
                      <span className="text-xs text-gray-500">{p.projectType}</span>
                    </div>
                    <p className="text-xs text-gray-500 mt-0.5 truncate">{p.repoFullName} · {p.branch}</p>
                    {lastBuild && (
                      <p className="text-xs text-gray-600 mt-1">
                        Last build #{lastBuild.jenkinsBuildNumber || '–'} ·{' '}
                        <span className={lastBuild.status === 'success' ? 'text-green-500' : lastBuild.status === 'failure' ? 'text-red-500' : 'text-gray-400'}>
                          {lastBuild.status}
                        </span>{' '}
                        · {formatDistanceToNow(new Date(lastBuild.createdAt), { addSuffix: true })}
                      </p>
                    )}
                  </div>
                  <div className="text-xs text-gray-600 shrink-0">port {p.port}</div>
                </div>
              </Link>
            );
          })}
        </div>
      )}
    </div>
  );
}
