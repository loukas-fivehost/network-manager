#!/bin/bash

set -euo pipefail

# Variables utiles
INSTALL_DIR="/opt/traffic-api"
SERVICE_NAME="traffic-api.service"

echo "=== [0] Vérification et arrêt du service $SERVICE_NAME (si existant) ==="
if systemctl is-active --quiet "$SERVICE_NAME"; then
  echo "Arrêt du service $SERVICE_NAME..."
  systemctl stop "$SERVICE_NAME"
else
  echo "Service $SERVICE_NAME non actif, pas besoin de l’arrêter."
fi

if systemctl is-enabled --quiet "$SERVICE_NAME"; then
  echo "Désactivation du service $SERVICE_NAME..."
  systemctl disable "$SERVICE_NAME"
else
  echo "Service $SERVICE_NAME non activé, pas besoin de désactiver."
fi

echo "=== [1] Suppression de l’ancien dossier $INSTALL_DIR (s’il existe) ==="
if [ -d "$INSTALL_DIR" ]; then
  echo "Suppression du dossier $INSTALL_DIR..."
  rm -rf "$INSTALL_DIR"
else
  echo "Dossier $INSTALL_DIR non existant, rien à supprimer."
fi

echo "=== [2] Mise à jour des paquets et installation des dépendances système ==="
apt update -y
apt install -y curl wget git python3 python3-pip python3-venv sqlite3 libnss3-tools || {
  echo "Erreur lors de l'installation des paquets système !" >&2
  exit 1
}

echo "=== [3] Téléchargement et installation de mkcert ==="
curl -L -o /usr/local/bin/mkcert https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-amd64
chmod +x /usr/local/bin/mkcert

echo "=== [4] Initialisation mkcert ==="
mkcert -install

echo "=== [5] Détection de l'adresse IP publique de la machine ==="
IP=$(hostname -I | awk '{print $1}')
if [[ -z "$IP" ]]; then
  echo "Impossible de récupérer l'adresse IP publique !" >&2
  exit 1
fi
echo "Adresse IP détectée : $IP"

echo "=== [6] Génération du certificat SSL auto-signé pour l'IP $IP ==="
mkdir -p "$INSTALL_DIR/certs"
cd "$INSTALL_DIR/certs"
mkcert "$IP" || {
  echo "Erreur lors de la génération du certificat mkcert !" >&2
  exit 1
}

CERT="$INSTALL_DIR/certs/$IP.pem"
KEY="$INSTALL_DIR/certs/$IP-key.pem"
echo "Certificat généré : $CERT"
echo "Clé générée : $KEY"

echo "=== [7] Création du code API Flask ==="
mkdir -p "$INSTALL_DIR"
cat > "$INSTALL_DIR/traffic_api.py" <<EOF
from flask import Flask, request, jsonify, render_template_string
from flask_cors import CORS
import psutil, time, sqlite3, threading, ssl

app = Flask(__name__)
CORS(app)
DB = '$INSTALL_DIR/traffic.db'

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

echo "=== [8] Création et activation de l'environnement virtuel Python ==="
cd "$INSTALL_DIR"
python3 -m venv venv
source venv/bin/activate
venv/bin/pip install --upgrade pip

echo "=== [9] Installation des dépendances Python dans l'environnement virtuel ==="
venv/bin/pip install flask flask-cors psutil

echo "=== [10] Création du service systemd ==="
cat > /etc/systemd/system/$SERVICE_NAME <<EOF
[Unit]
Description=API Flask Traffic Monitor
After=network.target

[Service]
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/traffic_api.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "=== [11] Rechargement systemd et activation du service ==="
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable $SERVICE_NAME

echo "=== [12] Démarrage du service ==="
systemctl restart $SERVICE_NAME

echo "=== Installation terminée ==="
echo "L'API Flask est accessible en HTTPS sur https://$IP:5000"
echo "Vérifiez le statut du service avec : systemctl status $SERVICE_NAME"
echo "Logs récents : journalctl -u $SERVICE_NAME -n 30"
