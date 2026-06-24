// Simple extension for Executive Orchestrator UI commands
const vscode = require('vscode');
const fs = require('fs');
const path = require('path');

function activate(context) {
    // Command: start workflow
    const start = vscode.commands.registerCommand('executiveOrchestrator.startWorkflow', () => {
        vscode.window.showInformationMessage('Executive Orchestrator: Workflow started');
        // TODO: trigger actual workflow via orchestrator
    });
    
    // Command: stop workflow
    const stop = vscode.commands.registerCommand('executiveOrchestrator.stopWorkflow', () => {
        vscode.window.showInformationMessage('Executive Orchestrator: Workflow stopped');
    });
    
    // Command: view dashboard (webview)
    const viewDashboard = vscode.commands.registerCommand('executiveOrchestrator.viewDashboard', () => {
        const panel = vscode.window.createWebviewPanel(
            'orchestratorDashboard',
            'Executive Orchestrator Dashboard',
            vscode.ViewColumn.One,
            { enableScripts: true }
        );
        panel.webview.html = getWebviewContent();
    });
    
    // Command: configure MCP servers (prompts for tokens)
    const configureMCP = vscode.commands.registerCommand('executiveOrchestrator.configureMCP', async () => {
        const configPath = path.join(context.extensionPath, 'mcp.json');
        let config = {};
        try {
            const data = fs.readFileSync(configPath, 'utf8');
            config = JSON.parse(data);
        } catch (e) {
            console.error('Could not read mcp.json', e);
        }
        
        // Ensure mcpServers exists
        if (!config.mcpServers) config.mcpServers = {};
        
        // Exa
        const exaToken = await vscode.window.showInputBox({
            prompt: 'Enter your Exa API key (sign up at https://exa.ai to get a key)',
            placeHolder: 'Exa API key',
            password: true
        });
        if (exaToken) {
            if (!config.mcpServers.exa) config.mcpServers.exa = {};
            config.mcpServers.exa = {
                command: 'exa-mcp-server',
                args: [],
                env: { EXA_API_KEY: exaToken }
            };
            vscode.window.showInformationMessage('Exa API key saved.');
        }
        
        // Tavily
        const tavilyToken = await vscode.window.showInputBox({
            prompt: 'Enter your Tavily API key (sign up at https://tavily.com)',
            placeHolder: 'Tavily API key',
            password: true
        });
        if (tavilyToken) {
            if (!config.mcpServers.tavily) config.mcpServers.tavily = {};
            config.mcpServers.tavily = {
                command: 'tavily-mcp-server',
                args: [],
                env: { TAVILY_API_KEY: tavilyToken }
            };
            vscode.window.showInformationMessage('Tavily API key saved.');
        }
        
        // Write back
        fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
        vscode.window.showInformationMessage('MCP configuration updated.');
    });
    
    context.subscriptions.push(start, stop, viewDashboard, configureMCP);
}

function getWebviewContent() {
    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <style>
        body { font-family: var(--vscode-font-family); color: var(--vscode-foreground); margin: 20px; }
        h2 { color: var(--vscode-button-background); }
        .status { margin: 10px 0; padding: 10px; background: var(--vscode-input-background); border-radius: 4px; }
        button { margin: 5px; padding: 8px 12px; }
    </style>
</head>
<body>
    <h2>Executive Orchestrator Dashboard</h2>
    <div class="status" id="status">Status: Idle</div>
    <button id="startBtn">Start Workflow</button>
    <button id="stopBtn">Stop Workflow</button>
    <button id="configureMcpBtn">Configure MCP Keys</button>
    <script>
        const vscode = acquireVsCodeApi();
        document.getElementById('startBtn').onclick = () => vscode.postMessage({command: 'start'});
        document.getElementById('stopBtn').onclick = () => vscode.postMessage({command: 'stop'});
        document.getElementById('configureMcpBtn').onclick = () => vscode.command.executeCommand('executiveOrchestrator.configureMCP');
        window.addEventListener('message', event => {
            const msg = event.data;
            if (msg.command === 'updateStatus') {
                document.getElementById('status').textContent = 'Status: ' + msg.status;
            }
        });
    </script>
</body>
</html>`;
}

function deactivate() {}

module.exports = {
    activate,
    deactivate
};
