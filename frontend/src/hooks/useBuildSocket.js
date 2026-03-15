import { useEffect, useRef } from 'react';
import { io } from 'socket.io-client';

let _socket = null;

function getSocket() {
  if (!_socket) {
    _socket = io('/', { path: '/socket.io', transports: ['websocket'] });
  }
  return _socket;
}

/**
 * Subscribe to real-time events for a build.
 * @param {string|null} buildId
 * @param {{ onLog: (line:string)=>void, onStatus: (status:string)=>void }} callbacks
 */
export function useBuildSocket(buildId, { onLog, onStatus }) {
  useEffect(() => {
    if (!buildId) return;
    const socket = getSocket();
    socket.emit('subscribe:build', buildId);

    const handleLog    = (data) => { if (data.buildId === buildId) onLog?.(data.line); };
    const handleStatus = (data) => { if (data.buildId === buildId) onStatus?.(data.status); };

    socket.on('build:log',    handleLog);
    socket.on('build:status', handleStatus);

    return () => {
      socket.emit('unsubscribe:build', buildId);
      socket.off('build:log',    handleLog);
      socket.off('build:status', handleStatus);
    };
  }, [buildId]);
}
