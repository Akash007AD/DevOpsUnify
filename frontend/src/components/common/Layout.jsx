import React, { useState } from 'react';
import { Outlet, NavLink, useNavigate } from 'react-router-dom';
import {
  HomeIcon, RocketLaunchIcon, ServerStackIcon,
  ChartBarIcon, Bars3Icon, XMarkIcon, ArrowRightOnRectangleIcon
} from '@heroicons/react/24/outline';
import useAuthStore from '../../context/authStore';
import clsx from 'clsx';

const nav = [
  { to: '/',          label: 'Dashboard',    icon: HomeIcon },
  { to: '/projects',  label: 'Projects',     icon: RocketLaunchIcon },
  { to: '/infra',     label: 'Infrastructure', icon: ServerStackIcon },
  { to: '/monitoring', label: 'Monitoring',  icon: ChartBarIcon },
];

export default function Layout() {
  const [open, setOpen] = useState(false);
  const { user, logout } = useAuthStore();
  const navigate = useNavigate();

  function handleLogout() { logout(); navigate('/login'); }

  return (
    <div className="flex h-screen bg-gray-950 overflow-hidden">
      {/* Sidebar */}
      <aside className={clsx(
        'fixed inset-y-0 left-0 z-50 w-60 bg-gray-900 border-r border-gray-800 flex flex-col',
        'transition-transform lg:translate-x-0',
        open ? 'translate-x-0' : '-translate-x-full lg:translate-x-0'
      )}>
        {/* Logo */}
        <div className="flex items-center gap-2 px-5 h-16 border-b border-gray-800">
          <div className="w-8 h-8 rounded-lg bg-brand-600 flex items-center justify-center text-white font-bold text-sm">D</div>
          <span className="font-semibold text-white">DevOpsUnify</span>
          <button className="ml-auto lg:hidden" onClick={() => setOpen(false)}>
            <XMarkIcon className="w-5 h-5 text-gray-400" />
          </button>
        </div>

        {/* Nav */}
        <nav className="flex-1 px-3 py-4 space-y-0.5">
          {nav.map(({ to, label, icon: Icon }) => (
            <NavLink
              key={to}
              to={to}
              end={to === '/'}
              className={({ isActive }) => clsx(
                'flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm transition-colors',
                isActive
                  ? 'bg-brand-600/20 text-brand-400 font-medium'
                  : 'text-gray-400 hover:text-gray-200 hover:bg-gray-800'
              )}
            >
              <Icon className="w-4 h-4 shrink-0" />
              {label}
            </NavLink>
          ))}
        </nav>

        {/* User */}
        <div className="px-4 py-4 border-t border-gray-800 flex items-center gap-3">
          {user?.avatarUrl && (
            <img src={user.avatarUrl} alt="" className="w-8 h-8 rounded-full" />
          )}
          <div className="flex-1 min-w-0">
            <p className="text-sm font-medium text-gray-200 truncate">{user?.name || user?.login}</p>
            <p className="text-xs text-gray-500 truncate">{user?.login}</p>
          </div>
          <button onClick={handleLogout} title="Logout">
            <ArrowRightOnRectangleIcon className="w-4 h-4 text-gray-500 hover:text-gray-300" />
          </button>
        </div>
      </aside>

      {/* Overlay (mobile) */}
      {open && <div className="fixed inset-0 z-40 bg-black/50 lg:hidden" onClick={() => setOpen(false)} />}

      {/* Main */}
      <div className="flex-1 flex flex-col lg:ml-60 overflow-hidden">
        {/* Topbar */}
        <header className="h-16 border-b border-gray-800 flex items-center px-4 bg-gray-950">
          <button className="lg:hidden mr-3" onClick={() => setOpen(true)}>
            <Bars3Icon className="w-5 h-5 text-gray-400" />
          </button>
          <div className="flex-1" />
          <div className="text-xs text-gray-500">
            {process.env.NODE_ENV === 'development' ? '● dev' : ''}
          </div>
        </header>

        {/* Page */}
        <main className="flex-1 overflow-y-auto p-6">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
