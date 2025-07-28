#!/bin/bash

set -e

echo "[1/10] 🔧 Installation des paquets nécessaires..."
rm -rf /opt/traffic-api/
apt update -y && apt install -y curl wget git python3 python3-pip python3-venv sqlite3 libnss3-tools

echo "[2/10] 🛠 Téléchargement de mkcert..."
curl -L -o /usr/local/bin/mkcert https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-amd64
chmod +x /usr/local/bin/mkcert

echo "[3/10] 🧾 Initialisation de mkcert..."
mkcert -install

echo "[4/10] 🌐 Récupération de l'IP publique de la machine..."
IP=$(hostname -I | awk '{print $1}')
echo "Adresse IP détectée : $IP"

echo "[5/10] 🔐 Génération du certificat SSL auto-signé pour $IP..."
mkdir -p /opt/traffic-api/certs
cd /opt/traffic-api/certs
mkcert "$IP"

CERT="/opt/traffic-api/certs/$IP.pem"
KEY="/opt/traffic-api/certs/$IP-key.pem"

echo "[6/10] 🧱 Création du code API Flask..."
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

@app.route('/api/whitelist')
def whitelist():
    html_content = """
    <!DOCTYPE html>
    <html lang='fr'>
    <head>
        <meta charset='UTF-8' />
        <meta name='viewport' content='width=device-width, initial-scale=1' />
        <title>IP Whitelistée</title>
        <style>
            body {
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
                color: white;
                display: flex;
                flex-direction: column;
                justify-content: center;
                align-items: center;
                height: 100vh;
                margin: 0;
                text-align: center;
                padding: 20px;
            }
            h1 {
                font-size: 3rem;
                margin-bottom: 0.5rem;
            }
            p {
                font-size: 1.25rem;
                margin-bottom: 2rem;
            }
            a.button {
                background: #fff;
                color: #764ba2;
                padding: 0.75rem 2rem;
                border-radius: 30px;
                text-decoration: none;
                font-weight: 600;
                font-size: 1rem;
                transition: background-color 0.3s ease, color 0.3s ease;
            }
            a.button:hover {
                background: #5a3e85;
                color: #fff;
            }
            @media (max-width: 480px) {
                h1 {
                    font-size: 2rem;
                }
                p {
                    font-size: 1rem;
                }
            }
        </style>
    </head>
    <body>
        <h1>✅ Votre IP est bien whitelistée !</h1>
        <p>Vous pouvez fermer cette page et retourner sur le Network Manager.</p>
        <a href="https://shield.five-host.fr" class="button" target="_blank" rel="noopener noreferrer">Retour au Network Manager</a>
    </body>
    </html>
    """
    return render_template_string(html_content)

if __name__ == '__main__':
    init_db()
    threading.Thread(target=collect, daemon=True).start()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile="$CERT", keyfile="$KEY")
    app.run(host='0.0.0.0', port=5000, ssl_context=context)
EOF

echo "[7/10] 🐍 Création de l'environnement virtuel Python..."
cd /opt/traffic-api
python3 -m venv venv
source venv/bin/activate

echo "[8/10] 📦 Installation des dépendances Python dans l'env virtuel..."
venv/bin/pip install --upgrade pip
venv/bin/pip install flask flask-cors psutil

echo "[9/10] 🪪 Création du service systemd..."
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

echo "[10/10] 🚀 Activation et démarrage du service..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable traffic-api.service
systemctl start traffic-api.service

echo "✅ API démarrée sur https://$IP:5000"
