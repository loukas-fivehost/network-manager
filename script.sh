#!/bin/bash
APP_DIR="/opt/debit-collector"
SERVICE_NAME="debit-collector"
PORT=3000
INTERFACE="eth0"

if ! command -v node > /dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
  apt-get install -y nodejs
fi

mkdir -p "$APP_DIR"

cat > "$APP_DIR/server.js" << EOF
const http = require('http');
const fs = require('fs');
const INTERFACE = '$INTERFACE';
const PORT = $PORT;

let dataPoints = [];
function readNetDev() {
  const content = fs.readFileSync('/proc/net/dev', 'utf8');
  const lines = content.split('\\n');
  for (const line of lines) {
    if (line.trim().startsWith(INTERFACE + ':')) {
      const parts = line.trim().split(/[:\\s]+/);
      const rx_bytes = parseInt(parts[1]);
      const tx_bytes = parseInt(parts[9]);
      return { rx_bytes, tx_bytes };
    }
  }
  throw new Error('Interface not found');
}
let lastStats = null;
function collect() {
  const now = Date.now();
  const stats = readNetDev();
  if (lastStats) {
    const interval = (now - lastStats.timestamp) / 1000;
    const rx_rate = (stats.rx_bytes - lastStats.rx_bytes) / interval;
    const tx_rate = (stats.tx_bytes - lastStats.tx_bytes) / interval;
    dataPoints.push({ timestamp: now, rx_rate, tx_rate });
    if (dataPoints.length > 1440) dataPoints.shift();
  }
  lastStats = { ...stats, timestamp: now };
}
setInterval(collect, 60000);
collect();
const server = http.createServer((req, res) => {
  if (req.url.startsWith('/api/debit')) {
    const match = req.url.match(/debit=(\\d+)/);
    let points = 60;
    if (match) points = Math.min(parseInt(match[1]), 1440);
    const now = Date.now();
    const filtered = dataPoints.filter(dp => dp.timestamp >= now - points * 60000);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(filtered));
  } else {
    res.writeHead(404);
    res.end('Not found');
  }
});
server.listen(PORT);
EOF

cat > /etc/systemd/system/$SERVICE_NAME.service << EOF
[Unit]
Description=Collecte debit reseau
After=network.target

[Service]
ExecStart=/usr/bin/node $APP_DIR/server.js
Restart=always
User=nobody
WorkingDirectory=$APP_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl start $SERVICE_NAME
