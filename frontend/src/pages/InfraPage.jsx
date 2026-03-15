import React, { useEffect, useState } from 'react';
import api from '../utils/api';
import { ArrowPathIcon, ServerStackIcon, TrashIcon } from '@heroicons/react/24/outline';

export default function InfraPage() {
  const [projects, setProjects]   = useState([]);
  const [infraMap, setInfraMap]   = useState({});
  const [loading, setLoading]     = useState(true);
  const [provisioning, setProv]   = useState({});

  useEffect(() => {
    api.get('/pipelines/projects').then(async r => {
      setProjects(r.data);
      const map = {};
      await Promise.all(r.data.map(async p => {
        try {
          const ir = await api.get(`/infra/projects/${p.id}/infra`);
          map[p.id] = ir.data[0] || null;
        } catch (_) { map[p.id] = null; }
      }));
      setInfraMap(map);
    }).finally(() => setLoading(false));
  }, []);

  async function provision(projectId) {
    setProv(prev => ({ ...prev, [projectId]: 'provisioning' }));
    try {
      await api.post(`/infra/projects/${projectId}/provision`);
      setProv(prev => ({ ...prev, [projectId]: 'done' }));
    } catch (e) {
      setProv(prev => ({ ...prev, [projectId]: 'error' }));
    }
  }

  async function destroy(projectId) {
    if (!window.confirm('Destroy all AWS resources for this project? This cannot be undone.')) return;
    setProv(prev => ({ ...prev, [projectId]: 'destroying' }));
    try {
      await api.delete(`/infra/projects/${projectId}/infra`);
      setProv(prev => ({ ...prev, [projectId]: 'done' }));
    } catch (_) {
      setProv(prev => ({ ...prev, [projectId]: 'error' }));
    }
  }

  const STATUS_BADGE = {
    applied:    'badge-success',
    applying:   'badge-running',
    pending:    'badge-queued',
    failed:     'badge-failure',
    destroyed:  'badge-queued',
    destroying: 'badge-running',
  };

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-xl font-semibold text-white">Infrastructure</h1>
        <p className="text-sm text-gray-500 mt-0.5">Terraform-managed AWS resources per project</p>
      </div>

      <div className="card overflow-hidden p-0">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-gray-800 text-xs text-gray-500 uppercase tracking-wider">
              <th className="text-left px-5 py-3">Project</th>
              <th className="text-left px-5 py-3">Status</th>
              <th className="text-left px-5 py-3">Outputs</th>
              <th className="text-right px-5 py-3">Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr><td colSpan={4} className="px-5 py-6 text-gray-500">Loading…</td></tr>
            ) : projects.map(p => {
              const infra = infraMap[p.id];
              const busy  = ['provisioning', 'destroying'].includes(provisioning[p.id]);
              return (
                <tr key={p.id} className="border-b border-gray-800 last:border-0 hover:bg-gray-800/40">
                  <td className="px-5 py-3">
                    <p className="font-medium text-gray-200">{p.name}</p>
                    <p className="text-xs text-gray-500">{p.projectType}</p>
                  </td>
                  <td className="px-5 py-3">
                    {infra
                      ? <span className={STATUS_BADGE[infra.status] || 'badge-queued'}>{infra.status}</span>
                      : <span className="badge-queued">not provisioned</span>
                    }
                  </td>
                  <td className="px-5 py-3">
                    {infra?.outputs && Object.keys(infra.outputs).length > 0 ? (
                      <div className="text-xs text-gray-500 space-y-0.5">
                        {Object.entries(infra.outputs).slice(0, 3).map(([k, v]) => (
                          <div key={k}><span className="text-gray-400">{k}:</span> {String(v).slice(0, 40)}</div>
                        ))}
                      </div>
                    ) : <span className="text-gray-600 text-xs">–</span>}
                  </td>
                  <td className="px-5 py-3 text-right">
                    <div className="flex items-center justify-end gap-2">
                      {(!infra || infra.status === 'destroyed' || infra.status === 'failed') && (
                        <button className="btn-primary py-1.5 px-3 text-xs" onClick={() => provision(p.id)} disabled={busy}>
                          {busy ? <ArrowPathIcon className="w-3.5 h-3.5 animate-spin" /> : <ServerStackIcon className="w-3.5 h-3.5" />}
                          {provisioning[p.id] === 'provisioning' ? 'Provisioning…' : 'Provision'}
                        </button>
                      )}
                      {infra?.status === 'applied' && (
                        <button className="btn-secondary py-1.5 px-3 text-xs text-red-400" onClick={() => destroy(p.id)} disabled={busy}>
                          <TrashIcon className="w-3.5 h-3.5" />
                          {provisioning[p.id] === 'destroying' ? 'Destroying…' : 'Destroy'}
                        </button>
                      )}
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
