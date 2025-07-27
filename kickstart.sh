#!/bin/bash

set -e

echo "[1/9] 🔧 Installation des paquets nécessaires..."
apt update -y && apt install -y curl wget git python3 python3-pip python3-venv sqlite3 libnss3-tools

echo "[2/9] 🛠 Téléchargement de mkcert..."
curl -L -o /usr/local/bin/mkcert https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-amd64
chmod +x /usr/local/bin/mkcert

echo "[3/9] 🧾 Initialisation de mkcert..."
mkcert -install

echo "[4/9] 🌐 Récupération de l'IP publique de la machine..."
IP=$(hostname -I | awk '{print $1}')
echo "Adresse IP détectée : $IP"

echo "[5/9] 🔐 Génération du certificat SSL auto-signé pour $IP..."
mkdir -p /opt/traffic-api/certs
cd /opt/traffic-api/certs
mkcert "$IP"

CERT="/opt/traffic-api/certs/$IP.pem"
KEY="/opt/traffic-api/certs/$IP-key.pem"

echo "[6/9] 🧱 Création du code API Flask..."
mkdir -p /opt/traffic-api
cat <<EOF > /opt/traffic-api/traffic_api.py
from flask import Flask, request, jsonify
from flask_cors import CORS
import psutil, time, sqlite3, threading, ssl

app = Flask(__name__)
CORS(app)
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
        {'timestamp': row[0], 'bytes_sent': round(row[1] / 1024 / 1024, 2), 'bytes_recv': round(row[2] / 1024 / 1024, 2)} for row in data
    ])

if __name__ == '__main__':
    init_db()
    threading.Thread(target=collect, daemon=True).start()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile="$CERT", keyfile="$KEY")
    app.run(host='0.0.0.0', port=5000, ssl_context=context)
EOF

echo "[7/9] 🐍 Création de l'environnement virtuel Python..."
cd /opt/traffic-api
python3 -m venv venv
source venv/bin/activate

echo "[8/9] 📦 Installation des dépendances Python dans l'env virtuel..."
venv/bin/pip install --upgrade pip
venv/bin/pip install flask flask-cors psutil

echo "[9/9] 🚀 Lancement de l'API HTTPS sur https://$IP:5000 ..."
venv/bin/python /opt/traffic-api/traffic_api.py