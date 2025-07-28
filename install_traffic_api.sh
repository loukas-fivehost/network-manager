#!/bin/bash

set -e

echo "[0/12] 🛑 Arrêt et suppression de l'ancien service traffic-api (si présent)..."
if systemctl is-active --quiet traffic-api.service; then
  systemctl stop traffic-api.service
fi
if systemctl is-enabled --quiet traffic-api.service; then
  systemctl disable traffic-api.service
fi

echo "[1/12] 🧹 Suppression de l'ancien dossier /opt/traffic-api/ (s'il existe)..."
if [ -d "/opt/traffic-api" ]; then
  rm -rf /opt/traffic-api/
fi

echo "[2/12] 🔧 Installation des paquets nécessaires..."
apt update -y && apt install -y curl wget git python3 python3-pip python3-venv sqlite3 libnss3-tools

echo "[3/12] 🛠 Téléchargement de mkcert..."
curl -L -o /usr/local/bin/mkcert https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-amd64
chmod +x /usr/local/bin/mkcert

echo "[4/12] 🧾 Initialisation de mkcert..."
mkcert -install

echo "[5/12] 🌐 Récupération de l'IP publique de la machine..."
IP=$(hostname -I | awk '{print $1}')
echo "Adresse IP détectée : $IP"

echo "[6/12] 🔐 Génération du certificat SSL auto-signé pour $IP..."
mkdir -p /opt/traffic-api/certs
cd /opt/traffic-api/certs
mkcert "$IP"

CERT="/opt/traffic-api/certs/$IP.pem"
KEY="/opt/traffic-api/certs/$IP-key.pem"

echo "[7/12] 🧱 Création du code API Flask..."
mkdir -p /opt/traffic-api
cat <<EOF > /opt/traffic-api/traffic_api.py
from flask import Flask, request, jsonify, render_template_string
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

# Nouvelle route whitelist avec page esthétique
@app.route('/api/whitelist')
def whitelist():
    html = """
    <!DOCTYPE html>
    <html lang="fr">
    <head>
      <meta charset="UTF-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>IP Whitelistée</title>
      <style>
        body {
          background: #0a0a1a;
          color: #cfd8dc;
          font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
          display: flex;
          flex-direction: column;
          justify-content: center;
          align-items: center;
          height: 100vh;
          margin: 0;
          text-align: center;
        }
        h1 {
          color: #4caf50;
          font-size: 2.5rem;
          margin-bottom: 1rem;
        }
        p {
          font-size: 1.2rem;
          max-width: 400px;
          line-height: 1.5;
        }
        button {
          margin-top: 2rem;
          background-color: #2196f3;
          border: none;
          color: white;
          padding: 0.8rem 1.5rem;
          font-size: 1rem;
          border-radius: 8px;
          cursor: pointer;
          transition: background-color 0.3s ease;
        }
        button:hover {
          background-color: #1976d2;
        }
      </style>
    </head>
    <body>
      <h1>✅ Votre IP est bien Whitelistée</h1>
      <p>Vous pouvez fermer cette page et retourner sur le Network Manager.</p>
      <button onclick="window.close()">Fermer la page</button>
    </body>
    </html>
    """
    return render_template_string(html)

if __name__ == '__main__':
    init_db()
    threading.Thread(target=collect, daemon=True).start()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile="$CERT", keyfile="$KEY")
    app.run(host='0.0.0.0', port=5000, ssl_context=context)
EOF

echo "[8/12] 🐍 Création de l'environnement virtuel Python..."
cd /opt/traffic-api
python3 -m venv venv
source venv/bin/activate

echo "[9/12] 📦 Installation des dépendances Python dans l'env virtuel..."
venv/bin/pip install --upgrade pip
venv/bin/pip install flask flask-cors psutil

echo "[10/12] 🪪 Création du service systemd..."
cat <<EOF > /etc/systemd/system/traffic-api.service
[Unit]
Description=API Flask Traffic Monitor
After=network.target

[Service]
User=root
WorkingDirectory=/opt/traffic-api
ExecStart=/opt/traffic-api/venv/bin/python /opt/traffic-api/traffic_api.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "[11/12] 🚀 Activation et démarrage du service..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable traffic-api.service
systemctl start traffic-api.service

echo "[12/12] ✅ API démarrée sur https://$IP:5000"
