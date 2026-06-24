const { gzipSync, gunzipSync } = require('zlib');
const { stdin, stdout } = process;

// Read all input from stdin (expect base64)
let inputData = '';
stdin.on('data', chunk => {
  inputData += chunk;
});
stdin.on('end', () => {
  try {
    // Decode base64
    const buffer = Buffer.from(inputData.trim(), 'base64');
    // Decompress
    const decompressed = gunzipSync(buffer);
    // Output as UTF-8 string
    stdout.write(decompressed.toString('utf8'));
  } catch (err) {
    process.stderr.write(`Error: ${err.message}\n`);
    process.exit(1);
  }
});
