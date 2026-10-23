'use strict';

// Internal IPC-only worker. The parent uses fork({detached:true}), so this live
// process is the leader of its own session/group. Never launch a command without
// the parent's ready/start handshake. Direct invocation cannot signal any group.
const fs = require('node:fs');
const { spawn } = require('node:child_process');
if (process.platform !== 'darwin' || typeof process.send !== 'function') {
    process.stderr.write('Migration supervisor requires a macOS detached IPC parent.\n');
    process.exit(2);
}

let started = false;
let closing = false;
let specification;
let deadline;
const startupDeadline = setTimeout(() => finish({ exit: 124, reason: 'start-handshake-timeout' }), 10_000);

function finish(outcome) {
    if (closing) return;
    closing = true;
    clearTimeout(startupDeadline);
    clearTimeout(deadline);
    // The anchor itself stays alive throughout TERM grace. Both signals resolve
    // kernel PID 0 to THIS sender's current group, never to a saved/reaped PGID.
    // Even after the command exits, this anchor still owns that group. Final KILL
    // terminates the anchor too; there is no later process that can signal its ID.
    setTimeout(() => process.kill(0, 'SIGKILL'), 2_000);
    try {
        if (specification) fs.writeFileSync(specification.result,
            JSON.stringify({ nonce: specification.nonce, ...outcome }) + '\n', { flag: 'wx' });
    } finally {
        process.kill(0, 'SIGTERM');
    }
}

// Installed before readiness or command creation. A parent's death/disconnect
// cancels the group even if it happened between fork and assigning the handle.
process.on('SIGINT', () => finish({ exit: 130, reason: 'interrupted' }));
process.on('SIGTERM', () => finish({ exit: 143, reason: 'terminated' }));
process.on('disconnect', () => finish({ exit: 143, reason: 'parent-disconnected' }));
process.on('uncaughtException', () => finish({ exit: 1, reason: 'supervisor-error' }));
process.on('unhandledRejection', () => finish({ exit: 1, reason: 'supervisor-rejection' }));
process.on('message', message => {
    if (closing) return;
    if (message?.type === 'cancel') {
        finish({ exit: message.exit === 130 ? 130 : 143, reason: 'parent-cancelled' });
        return;
    }
    if (started || message?.type !== 'start') {
        finish({ exit: 2, reason: 'invalid-handshake' });
        return;
    }
    const value = message.specification;
    if (!value || typeof value.nonce !== 'string' || typeof value.result !== 'string'
        || typeof value.log !== 'string' || typeof value.cwd !== 'string'
        || !Array.isArray(value.command) || !value.command.length
        || !value.command.every(item => typeof item === 'string')
        || !Number.isInteger(value.timeout) || value.timeout < 1 || value.timeout > 600_000) {
        finish({ exit: 2, reason: 'invalid-specification' });
        return;
    }
    started = true;
    specification = value;
    clearTimeout(startupDeadline);
    deadline = setTimeout(() => finish({ exit: 124, reason: 'command-timeout' }), value.timeout);
    const log = fs.openSync(value.log, 'a');
    try {
        // Non-detached descendants inherit the anchor's isolated group. No shell,
        // ChildProcess.kill(), numeric-PID timer, or parent-side group signal.
        const command = spawn(value.command[0], value.command.slice(1), {
            cwd: value.cwd, detached: false, shell: false, stdio: ['ignore', log, log]
        });
        command.once('error', () => finish({ exit: 1, reason: 'command-spawn-error' }));
        command.once('exit', (code, signal) => finish({
            exit: Number.isInteger(code) ? code : 1, reason: signal ? `command-signal-${signal}` : 'command-exit'
        }));
    } finally {
        fs.closeSync(log);
    }
});
if (!process.connected) finish({ exit: 143, reason: 'parent-already-disconnected' });
else process.send({ type: 'ready' }, error => {
    if (error) finish({ exit: 143, reason: 'ready-send-failed' });
});
