const { gzipSync, gunzipSync } = require('zlib');
const { stdout, stdin } = process;

// Read all input from stdin
let inputData = '';
stdin.on('data', chunk => {
  inputData += chunk;
});
stdin.on('end', () => {
  try {
    // Try to parse as JSON first
    let json = null;
    try {
      json = JSON.parse(inputData);
    } catch (e) {
      // If not JSON, treat as plain string
      json = inputData;
    }
    
    // Convert to string if object
    const stringData = typeof json === 'string' ? json : JSON.stringify(json);
    
    // Compress
    const compressed = gzipSync(Buffer.from(stringData, 'utf8'));
    // Output as base64 for easy transport
    stdout.write(compressed.toString('base64'));
  } catch (err) {
    process.stderr.write(`Error: ${err.message}\n`);
    process.exit(1);
  }
});
