import React, { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import api from '../utils/api';
import { ArrowPathIcon, PlayIcon, CodeBracketIcon, ChartBarIcon, ArrowUpTrayIcon } from '@heroicons/react/24/outline';
import { formatDistanceToNow } from 'date-fns';

const STATUS_BADGE = {
  success: 'badge-success',
  failure: 'badge-failure',
  running: 'badge-running',
  queued:  'badge-queued',
  aborted: 'badge-queued',
};

export default function ProjectDetail() {
  const { id } = useParams();
  const [project, setProject]         = useState(null);
  const [builds, setBuilds]           = useState([]);
  const [jenkinsfile, setJenkinsfile] = useState('');
  const [tab, setTab]                 = useState('builds');
  const [triggering, setTriggering]   = useState(false);
  const [syncing, setSyncing]         = useState(false);
  const [syncMsg, setSyncMsg]         = useState('');
  const [loading, setLoading]         = useState(true);

  useEffect(() => {
    Promise.all([
      api.get(`/pipelines/projects/${id}`),
      api.get(`/pipelines/projects/${id}/builds`),
    ]).then(([pr, br]) => {
      setProject(pr.data);
      setBuilds(br.data);
    }).finally(() => setLoading(false));
  }, [id]);

  async function loadJenkinsfile() {
    if (jenkinsfile) return;
    const { data } = await api.get(`/pipelines/projects/${id}/jenkinsfile`);
    setJenkinsfile(data.jenkinsfile);
  }

  async function triggerBuild() {
    setTriggering(true);
    try {
      const { data } = await api.post(`/pipelines/projects/${id}/builds`);
      setBuilds(prev => [data.build, ...prev]);
    } finally {
      setTriggering(false);
    }
  }

  async function syncJenkins() {
    setSyncing(true);
    setSyncMsg('');
    try {
      const { data } = await api.post(`/pipelines/projects/${id}/sync-jenkins`);
      setSyncMsg(data.message);
    } catch (e) {
      setSyncMsg(e.response?.data?.error || 'Sync failed');
    } finally {
      setSyncing(false);
    }
  }

  if (loading) return <div className="text-gray-500 text-sm">Loading…</div>;
  if (!project) return <div className="text-red-400">Project not found</div>;

  return (
    <div className="space-y-5">
      {/* Header */}
      <div className="flex items-start gap-4">
        <div className="w-12 h-12 rounded-xl bg-brand-600/20 flex items-center justify-center text-brand-400 font-bold text-lg uppercase shrink-0">
          {project.name[0]}
        </div>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <h1 className="text-xl font-semibold text-white">{project.name}</h1>
            <span className={STATUS_BADGE[project.status] || 'badge-queued'}>{project.status}</span>
          </div>
          <p className="text-sm text-gray-500 mt-0.5">{project.repoFullName} · {project.branch} · {project.projectType}</p>
        </div>
        <div className="flex items-center gap-2 flex-wrap justify-end">
          {project.grafanaDashboardUid && (
            <a href={`${import.meta.env.VITE_GRAFANA_URL || ''}/d/${project.grafanaDashboardUid}`}
              target="_blank" rel="noopener noreferrer" className="btn-secondary">
              <ChartBarIcon className="w-4 h-4" /> Grafana
            </a>
          )}
          <button className="btn-secondary" onClick={syncJenkins} disabled={syncing} title="Push Jenkinsfile to Jenkins">
            {syncing ? <ArrowPathIcon className="w-4 h-4 animate-spin" /> : <ArrowUpTrayIcon className="w-4 h-4" />}
            {syncing ? 'Syncing…' : 'Sync Jenkins'}
          </button>
          <button className="btn-primary" onClick={triggerBuild} disabled={triggering}>
            {triggering ? <ArrowPathIcon className="w-4 h-4 animate-spin" /> : <PlayIcon className="w-4 h-4" />}
            {triggering ? 'Triggering…' : 'Run Build'}
          </button>
        </div>
      </div>

      {/* Sync feedback */}
      {syncMsg && (
        <div className={`text-sm px-4 py-2 rounded-lg ${
          syncMsg.toLowerCase().includes('success') || syncMsg.includes('created') || syncMsg.includes('updated')
            ? 'bg-green-900/20 text-green-400 border border-green-800'
            : 'bg-red-900/20 text-red-400 border border-red-800'
        }`}>
          {syncMsg}
        </div>
      )}

      {/* Info cards */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
        {[
          { label: 'ECR Repo',     value: project.ecrRepo || '–' },
          { label: 'Namespace',    value: project.k8sNamespace },
          { label: 'Port',         value: project.port },
          { label: 'Helm Release', value: project.helmReleaseName || '–' },
        ].map(({ label, value }) => (
          <div key={label} className="card py-3">
            <p className="text-xs text-gray-500">{label}</p>
            <p className="text-sm font-medium text-gray-200 mt-0.5 truncate">{value}</p>
          </div>
        ))}
      </div>

      {/* Tabs */}
      <div className="flex gap-1 border-b border-gray-800 pb-0">
        {[
          { key: 'builds',      label: `Builds (${builds.length})` },
          { key: 'jenkinsfile', label: 'Jenkinsfile' },
        ].map(t => (
          <button
            key={t.key}
            onClick={() => { setTab(t.key); if (t.key === 'jenkinsfile') loadJenkinsfile(); }}
            className={`px-4 py-2 text-sm font-medium border-b-2 transition-colors -mb-px ${
              tab === t.key
                ? 'border-brand-500 text-brand-400'
                : 'border-transparent text-gray-500 hover:text-gray-300'
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {/* Tab content */}
      {tab === 'builds' && (
        <div className="space-y-2">
          {builds.length === 0 ? (
            <p className="text-gray-500 text-sm">No builds yet. Click "Sync Jenkins" first, then "Run Build" or push to your repo.</p>
          ) : builds.map(b => (
            <Link key={b.id} to={`/projects/${id}/builds/${b.id}`}
              className="card hover:border-gray-700 transition-colors flex items-center gap-4">
              <div className="font-mono text-xs text-gray-500 w-8">#{b.jenkinsBuildNumber || '–'}</div>
              <span className={STATUS_BADGE[b.status] || 'badge-queued'}>{b.status}</span>
              <div className="flex-1 min-w-0">
                <p className="text-sm text-gray-300 truncate">{b.commitMessage || 'Manual trigger'}</p>
                <p className="text-xs text-gray-600">{b.commitSha?.slice(0, 7)} · by {b.triggeredBy || 'unknown'}</p>
              </div>
              {b.duration && <span className="text-xs text-gray-600">{b.duration}s</span>}
              <span className="text-xs text-gray-600">{formatDistanceToNow(new Date(b.createdAt), { addSuffix: true })}</span>
            </Link>
          ))}
        </div>
      )}

      {tab === 'jenkinsfile' && (
        <div className="card">
          <div className="flex items-center gap-2 mb-3">
            <CodeBracketIcon className="w-4 h-4 text-gray-400" />
            <span className="text-sm font-medium text-gray-300">Generated Jenkinsfile</span>
          </div>
          <pre className="text-xs text-gray-300 bg-gray-950 p-4 rounded-lg overflow-x-auto leading-relaxed max-h-[600px] overflow-y-auto">
            {jenkinsfile || 'Loading…'}
          </pre>
        </div>
      )}
    </div>
  );
}
