#!/usr/bin/env node
/**
 * Kilo SDK Delegate Stub
 *
 * Minimal fallback for delegation when agent_manager CLI and Kilo SDK are unavailable.
 * Creates a pending manifest for manual invocation and returns structured JSON.
 *
 * Usage:
 *   node kilo-sdk-delegate.js --payload-file <path>
 *   node kilo-sdk-delegate.js <path>
 *
 * Reads the first argument as payload file path (JSON).
 * Writes manifest to .kilocode/memory/delegation/pending/.
 * Outputs JSON to stdout:
 *   { "ok": false, "invoked": false, "backend": "kilo-sdk-delegate", "reason": "manual_invoke_required", "manifestPath": "..." }
 */

const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
    const args = argv.slice(2);
    let payloadPath = null;

    for (let i = 0; i < args.length; i++) {
        if ((args[i] === '--payload-file' || args[i] === '-f') && args[i + 1]) {
            payloadPath = args[++i];
        } else if (!args[i].startsWith('-') && !payloadPath) {
            payloadPath = args[i];
        }
    }

    return { payloadPath };
}

function readPayload(payloadPath) {
    if (!payloadPath || !fs.existsSync(payloadPath)) {
        throw new Error('Payload file not found: ' + (payloadPath || '(none)'));
    }
    const content = fs.readFileSync(payloadPath, 'utf8');
    return JSON.parse(content);
}

function extractObjective(payload) {
    if (!payload || typeof payload !== 'object') return '';
    if (typeof payload.objective === 'string') return payload.objective;
    if (typeof payload.tasks === 'string') return payload.tasks;
    return '';
}

function extractAgent(payload) {
    if (!payload || typeof payload !== 'object') return '';
    if (typeof payload.assigned_agent === 'string') return payload.assigned_agent;
    if (typeof payload.agent === 'string') return payload.agent;
    if (Array.isArray(payload.agentManagerTasks) && payload.agentManagerTasks[0] && typeof payload.agentManagerTasks[0].agent === 'string') {
        return payload.agentManagerTasks[0].agent;
    }
    return '';
}

function extractTaskId(payload) {
    if (!payload || typeof payload !== 'object') return '';
    if (typeof payload.taskId === 'string') return payload.taskId;
    if (typeof payload.task_id === 'string') return payload.task_id;
    if (Array.isArray(payload.agentManagerTasks) && payload.agentManagerTasks[0] && typeof payload.agentManagerTasks[0].taskId === 'string') {
        return payload.agentManagerTasks[0].taskId;
    }
    return '';
}

function extractFileScope(payload) {
    if (!payload || typeof payload !== 'object') return [];
    if (Array.isArray(payload.fileScope)) return payload.fileScope;
    if (Array.isArray(payload.file_scope)) return payload.file_scope;
    if (typeof payload.fileScope === 'string') return [payload.fileScope];
    if (typeof payload.file_scope === 'string') return [payload.file_scope];
    return [];
}

function main() {
    let payloadPath;
    try {
        ({ payloadPath } = parseArgs(process.argv));
        const payload = readPayload(payloadPath);
        const taskId = extractTaskId(payload) || path.basename(payloadPath || 'unknown');
        const objective = extractObjective(payload) || '';
        const agent = extractAgent(payload) || '';
        const fileScope = extractFileScope(payload);

        const pendingDir = path.join(__dirname, '..', 'memory', 'delegation', 'pending');
        if (!fs.existsSync(pendingDir)) {
            fs.mkdirSync(pendingDir, { recursive: true });
        }

        const manifestPath = path.join(pendingDir, taskId + '-delegation.json');
        const manifest = {
            task_id: taskId,
            agent: agent,
            objective: objective,
            file_scope: fileScope,
            original_payload: payload,
            status: 'pending_manual_invoke',
            reason: 'manual_invoke_required',
            backend: 'kilo-sdk-delegate',
            timestamp: new Date().toISOString()
        };

        fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2), 'utf8');

        const result = {
            ok: false,
            invoked: false,
            backend: 'kilo-sdk-delegate',
            reason: 'manual_invoke_required',
            manifestPath: manifestPath
        };

        console.log(JSON.stringify(result, null, 2));
        process.exit(0);
    } catch (err) {
        const result = {
            ok: false,
            invoked: false,
            backend: 'kilo-sdk-delegate',
            reason: 'payload_parse_failed',
            error: err.message,
            manifestPath: ''
        };
        console.error('[kilo-sdk-delegate] ' + err.message);
        console.log(JSON.stringify(result, null, 2));
        process.exit(1);
    }
}

if (require.main === module) {
    main();
}
