import React, { useEffect, useRef, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import api from '../utils/api';
import { useBuildSocket } from '../hooks/useBuildSocket';
import { ArrowLeftIcon } from '@heroicons/react/24/outline';

const STATUS_COLOR = {
  success: 'text-green-400',
  failure: 'text-red-400',
  running: 'text-blue-400',
  queued:  'text-gray-400',
};

export default function BuildDetail() {
  const { id, buildId } = useParams();
  const [build, setBuild] = useState(null);
  const [lines, setLines] = useState([]);
  const [loading, setLoading] = useState(true);
  const bottomRef = useRef(null);

  useEffect(() => {
    api.get(`/pipelines/projects/${id}/builds/${buildId}`).then(r => {
      setBuild(r.data);
      if (r.data.logs) setLines(r.data.logs.split('\n'));
    }).finally(() => setLoading(false));
  }, [buildId]);

  // Real-time log streaming via Socket.IO
  useBuildSocket(buildId, {
    onLog: (line) => setLines(prev => [...prev, line]),
    onStatus: (status) => setBuild(prev => prev ? { ...prev, status } : prev),
  });

  // Auto-scroll to bottom
  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [lines]);

  if (loading) return <div className="text-gray-500 text-sm">Loading…</div>;
  if (!build) return <div className="text-red-400">Build not found</div>;

  return (
    <div className="space-y-4 h-full flex flex-col">
      {/* Header */}
      <div className="flex items-center gap-3">
        <Link to={`/projects/${id}`} className="btn-secondary py-1.5 px-3 text-xs">
          <ArrowLeftIcon className="w-3.5 h-3.5" /> Back
        </Link>
        <div>
          <h1 className="text-lg font-semibold text-white">
            Build #{build.jenkinsBuildNumber || '–'}
            <span className={`ml-2 text-base font-normal ${STATUS_COLOR[build.status]}`}>{build.status}</span>
          </h1>
          <p className="text-xs text-gray-500">{build.commitMessage || 'Manual trigger'} · {build.commitSha?.slice(0, 7)}</p>
        </div>
        <div className="ml-auto flex gap-4 text-xs text-gray-500">
          {build.duration && <span>Duration: {build.duration}s</span>}
          {build.sonarStatus && <span>Sonar: <span className={build.sonarStatus === 'OK' ? 'text-green-400' : 'text-red-400'}>{build.sonarStatus}</span></span>}
          {build.trivyStatus && <span>Trivy: <span className={build.trivyStatus === 'PASS' ? 'text-green-400' : 'text-red-400'}>{build.trivyStatus}</span></span>}
        </div>
      </div>

      {/* Log terminal */}
      <div className="flex-1 bg-gray-950 border border-gray-800 rounded-xl overflow-hidden flex flex-col" style={{ minHeight: '500px' }}>
        <div className="flex items-center gap-2 px-4 py-2.5 border-b border-gray-800 bg-gray-900">
          <div className="flex gap-1.5">
            <div className="w-3 h-3 rounded-full bg-red-500/60" />
            <div className="w-3 h-3 rounded-full bg-yellow-500/60" />
            <div className="w-3 h-3 rounded-full bg-green-500/60" />
          </div>
          <span className="text-xs text-gray-500 ml-2">Console Output</span>
          {build.status === 'running' && (
            <span className="ml-auto flex items-center gap-1.5 text-xs text-blue-400">
              <span className="w-1.5 h-1.5 rounded-full bg-blue-400 animate-pulse" /> Live
            </span>
          )}
        </div>
        <div className="flex-1 overflow-y-auto p-4 font-mono text-xs text-gray-300 leading-relaxed">
          {lines.length === 0 ? (
            <span className="text-gray-600">Waiting for output…</span>
          ) : (
            lines.map((line, i) => {
              const isError = /error|failed|fatal/i.test(line);
              const isSuccess = /success|passed|deployed/i.test(line);
              const isStage = /^\[Pipeline\]/.test(line);
              return (
                <div key={i} className={
                  isError   ? 'text-red-400' :
                  isSuccess ? 'text-green-400' :
                  isStage   ? 'text-yellow-400 mt-2 font-medium' :
                  'text-gray-400'
                }>
                  {line}
                </div>
              );
            })
          )}
          <div ref={bottomRef} />
        </div>
      </div>
    </div>
  );
}
