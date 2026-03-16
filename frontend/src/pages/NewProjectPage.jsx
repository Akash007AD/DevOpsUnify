import React, { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import api from '../utils/api';
import { MagnifyingGlassIcon, ArrowPathIcon, CheckIcon } from '@heroicons/react/24/outline';

function AnalysisResult({ result }) {
  if (!result) return null;
  const { projectType, buildTool, port, hasDockerfile } = result;
  return (
    <div className="mt-4 p-4 bg-green-900/20 border border-green-800 rounded-lg space-y-1">
      <p className="text-sm font-medium text-green-400 flex items-center gap-2"><CheckIcon className="w-4 h-4" /> Repository analysed successfully</p>
      <div className="grid grid-cols-2 gap-2 mt-2 text-xs text-gray-400">
        <span>Type: <strong className="text-gray-200">{projectType}</strong></span>
        <span>Build tool: <strong className="text-gray-200">{buildTool}</strong></span>
        <span>Port: <strong className="text-gray-200">{port}</strong></span>
        <span>Has Dockerfile: <strong className="text-gray-200">{hasDockerfile ? 'Yes' : 'No (will generate)'}</strong></span>
      </div>
    </div>
  );
}

export default function NewProjectPage() {
  const [repos, setRepos] = useState([]);
  const [search, setSearch] = useState('');
  const [selectedRepo, setSelectedRepo] = useState(null);
  const [branch, setBranch] = useState('main');
  const [branches, setBranches] = useState([]);
  const [analysis, setAnalysis] = useState(null);
  const [analysing, setAnalysing] = useState(false);
  const [creating, setCreating] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const navigate = useNavigate();

  useEffect(() => {
    api.get('/repos').then(r => setRepos(r.data)).finally(() => setLoading(false));
  }, []);

  async function handleSelectRepo(repo) {
    setSelectedRepo(repo);
    setAnalysis(null);
    setError('');
    const [owner, repoName] = repo.fullName.split('/');
    const br = await api.get(`/repos/${owner}/${repoName}/branches`).then(r => r.data).catch(() => ['main']);
    setBranches(br);
    setBranch(repo.defaultBranch || 'main');
  }

  async function handleAnalyse() {
    if (!selectedRepo) return;
    setAnalysing(true);
    setError('');
    try {
      const { data } = await api.post('/repos/analyse', { repoUrl: selectedRepo.cloneUrl, branch });
      setAnalysis(data);
    } catch (e) {
      setError(e.response?.data?.error || 'Analysis failed');
    } finally {
      setAnalysing(false);
    }
  }

  async function handleCreate() {
    if (!selectedRepo || !analysis) return;
    setCreating(true);
    setError('');
    try {
      const { data } = await api.post('/pipelines/projects', {
        repoUrl: selectedRepo.cloneUrl,
        branch,
        name: selectedRepo.name,
      });
      navigate(`/projects/${data.project.id}`);
    } catch (e) {
      if (e.response?.status === 409) {
        // Already exists — navigate to the existing project
        const existingId = e.response.data?.projectId;
        if (existingId) {
          navigate(`/projects/${existingId}`);
        } else {
          setError('A project for this repository and branch already exists.');
        }
      } else {
        setError(e.response?.data?.error || 'Project creation failed');
      }
      setCreating(false);
    }
  }

  const filtered = repos.filter(r =>
    r.fullName.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div className="max-w-2xl mx-auto space-y-6">
      <div>
        <h1 className="text-xl font-semibold text-white">New Project</h1>
        <p className="text-sm text-gray-500 mt-0.5">Select a GitHub repository to onboard</p>
      </div>

      {/* Step 1 — Pick repo */}
      <div className="card space-y-3">
        <h2 className="text-sm font-semibold text-gray-300">1. Select repository</h2>
        <div className="relative">
          <MagnifyingGlassIcon className="absolute left-3 top-2.5 w-4 h-4 text-gray-500" />
          <input
            className="w-full bg-gray-800 border border-gray-700 rounded-lg pl-9 pr-4 py-2 text-sm text-gray-200 placeholder-gray-500 focus:outline-none focus:border-brand-500"
            placeholder="Search repositories…"
            value={search}
            onChange={e => setSearch(e.target.value)}
          />
        </div>
        <div className="max-h-56 overflow-y-auto space-y-1 -mx-1 px-1">
          {loading ? (
            <p className="text-gray-500 text-sm py-2">Loading repos…</p>
          ) : filtered.map(r => (
            <button
              key={r.id}
              onClick={() => handleSelectRepo(r)}
              className={`w-full text-left px-3 py-2.5 rounded-lg text-sm transition-colors flex items-center gap-3
                ${selectedRepo?.id === r.id
                  ? 'bg-brand-600/20 text-brand-400 border border-brand-600/40'
                  : 'text-gray-300 hover:bg-gray-800'}`}
            >
              <span className="flex-1 truncate">{r.fullName}</span>
              <span className="text-xs text-gray-600 shrink-0">{r.language || 'unknown'}</span>
              {r.private && <span className="text-xs text-gray-600">private</span>}
            </button>
          ))}
        </div>
      </div>

      {/* Step 2 — Branch + analyse */}
      {selectedRepo && (
        <div className="card space-y-3">
          <h2 className="text-sm font-semibold text-gray-300">2. Select branch &amp; analyse</h2>
          <div className="flex gap-3">
            <select
              value={branch}
              onChange={e => setBranch(e.target.value)}
              className="flex-1 bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-gray-200 focus:outline-none focus:border-brand-500"
            >
              {branches.map(b => <option key={b} value={b}>{b}</option>)}
            </select>
            <button className="btn-secondary" onClick={handleAnalyse} disabled={analysing}>
              {analysing ? <ArrowPathIcon className="w-4 h-4 animate-spin" /> : null}
              {analysing ? 'Analysing…' : 'Analyse Repo'}
            </button>
          </div>
          <AnalysisResult result={analysis} />
        </div>
      )}

      {/* Step 3 — Create */}
      {analysis && (
        <div className="card space-y-3">
          <h2 className="text-sm font-semibold text-gray-300">3. Create project</h2>
          <p className="text-xs text-gray-500">
            This will: register a GitHub webhook, generate a Jenkinsfile, create an ECR config, and provision a Grafana dashboard.
          </p>
          {error && <p className="text-sm text-red-400">{error}</p>}
          <button className="btn-primary w-full justify-center" onClick={handleCreate} disabled={creating}>
            {creating ? <ArrowPathIcon className="w-4 h-4 animate-spin" /> : <CheckIcon className="w-4 h-4" />}
            {creating ? 'Creating project…' : 'Create Project'}
          </button>
        </div>
      )}

      {error && !analysis && <p className="text-sm text-red-400">{error}</p>}
    </div>
  );
}
