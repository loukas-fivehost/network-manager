#!/bin/bash

apt update -y
apt install -y python3 python3-pip net-tools

mkdir -p /opt/traffic-api
cat > /opt/traffic-api/traffic_api.py << 'EOF'
from flask import Flask, request, jsonify
import psutil
import time
import sqlite3
import threading

app = Flask(__name__)
DB = '/opt/traffic-api/traffic.db'

def init_db():
    conn = sqlite3.connect(DB)
    c = conn.cursor()
    c.execute('CREATE TABLE IF NOT EXISTS traffic (timestamp INTEGER, bytes_sent INTEGER, bytes_recv INTEGER)')
    conn.commit()
    conn.close()

def collect():
    prev = psutil.net_io_counters()
    while True:
        time.sleep(60)
        curr = psutil.net_io_counters()
        sent = curr.bytes_sent - prev.bytes_sent
        recv = curr.bytes_recv - prev.bytes_recv
        ts = int(time.time())
        conn = sqlite3.connect(DB)
        c = conn.cursor()
        c.execute('INSERT INTO traffic VALUES (?, ?, ?)', (ts, sent, recv))
        conn.commit()
        conn.close()
        prev = curr

@app.route('/api/debit')
def api():
    minutes = int(request.args.get('minutes', 60))
    now = int(time.time())
    start = now - (minutes * 60)
    conn = sqlite3.connect(DB)
    c = conn.cursor()
    c.execute('SELECT timestamp, bytes_sent, bytes_recv FROM traffic WHERE timestamp >= ?', (start,))
    data = c.fetchall()
    conn.close()
    return jsonify([
        {'timestamp': row[0], 'bytes_sent': row[1], 'bytes_recv': row[2]} for row in data
    ])

if __name__ == '__main__':
    init_db()
    threading.Thread(target=collect, daemon=True).start()
    app.run(host='0.0.0.0', port=5000)
EOF

pip3 install flask psutil

cat > /etc/systemd/system/traffic-api.service << EOF
[Unit]
Description=Traffic API Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/traffic-api/traffic_api.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable traffic-api
systemctl start traffic-api
