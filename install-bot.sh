#!/bin/bash

echo "==============================="
echo " Actualizando sistema "
echo "==============================="
sudo apt update && sudo apt upgrade -y

echo "==============================="
echo " Instalando Node.js y npm "
echo "==============================="
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs
node -v
npm -v

echo "==============================="
echo " Instalando dependencias del sistema para Puppeteer "
echo "==============================="
sudo apt install -y wget ca-certificates fonts-liberation libappindicator3-1 libasound2 libatk-bridge2.0-0 \
libatk1.0-0 libcups2 libdbus-1-3 libgdk-pixbuf2.0-0 libnspr4 libnss3 libx11-xcb1 libxcomposite1 \
libxdamage1 libxrandr2 xdg-utils libu2f-udev libvulkan1

echo "==============================="
echo " Creando estructura del proyecto bot-backend "
echo "==============================="
mkdir -p ~/bot-backend/public
mkdir -p ~/bot-backend/sessions

echo "==============================="
echo " Creando archivo public/qr.html "
echo "==============================="
cat > ~/bot-backend/public/qr.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
  <title>QR WhatsApp</title>
  <style>
    body {
      font-family: Arial;
      text-align: center;
      padding-top: 40px;
    }
    #qr {
      width: 300px;
      display: none;
      border: 1px solid #ccc;
      padding: 10px;
    }
  </style>
</head>
<body>
  <h2>Escanea el código QR:</h2>
  <p id="estado">Cargando QR...</p>
  <img id="qr">

  <script>
    const nombre = new URLSearchParams(window.location.search).get('nombre');
    const img = document.getElementById('qr');
    const estado = document.getElementById('estado');

    function verificarQR() {
      const url = `/qr-${nombre}.png?time=` + new Date().getTime();
      fetch(url).then(res => {
        if (res.ok) {
          img.src = url;
          img.style.display = 'block';
          estado.innerText = "Escanea el QR con WhatsApp";
        } else {
          setTimeout(verificarQR, 2000);
        }
      }).catch(() => setTimeout(verificarQR, 2000));
    }

    verificarQR();
  </script>
</body>
</html>
EOF

echo "==============================="
echo " Creando archivo package.json "
echo "==============================="
cat > ~/bot-backend/package.json <<'EOF'
{
  "name": "bot-backend",
  "version": "1.0.0",
  "main": "index.js",
  "scripts": {
    "test": "echo \"Error: no test specified\" && exit 1"
  },
  "keywords": [],
  "author": "",
  "license": "ISC",
  "description": "",
  "dependencies": {
    "cors": "^2.8.5",
    "express": "^5.1.0",
    "fs": "^0.0.1-security",
    "fs-extra": "^11.3.0",
    "puppeteer": "^24.10.0",
    "qrcode": "^1.5.4",
    "qrcode-terminal": "^0.12.0",
    "socket.io": "^4.8.1",
    "whatsapp-web.js": "^1.30.0"
  }
}
EOF

echo "==============================="
echo " Creando archivo server.js "
echo "==============================="
cat > ~/bot-backend/server.js <<'EOF'
process.env.PUPPETEER_EXECUTABLE_PATH = '/usr/bin/chromium-browser';

const { Client, LocalAuth } = require('whatsapp-web.js');
const express = require('express');
const fs = require('fs');
const fsExtra = require('fs-extra');
const cors = require('cors');
const qrcode = require('qrcode');
const path = require('path');
const http = require('http');
const socketIo = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = socketIo(server, {
    cors: {
        origin: "*"
    }
});

const PORT = 3000;
const sessions = {};

// ✅ Función para retrasos
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

// ✅ Función para obtener respuestas del JSON según la sesión
const obtenerRespuestas = (nombre) => {
    try {
        const filePath = path.join(__dirname, `respuestas-${nombre}.json`);
        const data = fs.readFileSync(filePath);
        return JSON.parse(data);
    } catch (error) {
        console.error(`Error leyendo respuestas para ${nombre}:`, error);
        return {};
    }
};

app.use(cors());
app.use(express.json());
app.use('/public', express.static(path.join(__dirname, 'public')));

io.on('connection', socket => {
    console.log('Cliente WebSocket conectado');
});

app.get('/api/iniciar', async (req, res) => {
    const nombre = req.query.nombre;
    if (!nombre) return res.status(400).send("Falta el nombre");

    if (sessions[nombre]) {
        return res.status(400).send("Sesión ya iniciada");
    }

    const client = new Client({
        authStrategy: new LocalAuth({ clientId: nombre }),
        puppeteer: {
            headless: true,
            executablePath: process.env.PUPPETEER_EXECUTABLE_PATH,
            args: ['--no-sandbox', '--disable-setuid-sandbox']
        }
    });

    sessions[nombre] = client;

    client.on('qr', async (qr) => {
        io.emit('estado', { nombre, estado: 'esperando' });

        console.log(`QR para ${nombre}: ${qr}`);
        const qrPath = path.join(__dirname, 'public', `qr-${nombre}.png`);
        try {
            await qrcode.toFile(qrPath, qr);

            io.emit(`qr-${nombre}`, qr);
            io.emit('qr', {
                nombre,
                qr: `http://51.222.150.96:3000/qr?nombre=${nombre}`
            });

        } catch (error) {
            console.error("Error guardando QR:", error);
        }
    });

    client.on('ready', () => {
        console.log(`Cliente ${nombre} listo`);
        const sessionFile = path.join(__dirname, 'sessions', `${nombre}.json`);
        fs.writeFileSync(sessionFile, JSON.stringify({ estado: "conectado" }, null, 2));
        
        const filePath = path.join(__dirname, `respuestas-${nombre}.json`);
        if (!fs.existsSync(filePath)) {
        fs.writeFileSync(filePath, JSON.stringify({}, null, 2));
        console.log(`Archivo respuestas-${nombre}.json creado vacío.`);
        }

        io.emit('estado', { nombre, estado: 'conectado' });
    });

    client.on('message', async message => {
        const respuestas = obtenerRespuestas(nombre);
        const msgTexto = message.body.toLowerCase();

        if (respuestas[msgTexto]) {
            const randomDelay = Math.floor(Math.random() * 2000) + 2000;
            console.log(`Esperando ${randomDelay} ms antes de responder a: ${msgTexto}`);
            await delay(randomDelay);
            await message.reply(respuestas[msgTexto]);
        }
    });

    client.on('disconnected', async (reason) => {
        console.log(`Cliente ${nombre} desconectado: ${reason}`);

        const sessionFile = path.join(__dirname, 'sessions', `${nombre}.json`);
        fs.writeFileSync(sessionFile, JSON.stringify({ estado: "desconectado" }, null, 2));

        const qrFile = path.join(__dirname, 'public', `qr-${nombre}.png`);
        if (fs.existsSync(qrFile)) {
            fs.unlinkSync(qrFile);
            console.log(`QR eliminado para ${nombre}`);
        }

        if (sessions[nombre]) {
            delete sessions[nombre];
            console.log(`Sesión ${nombre} eliminada de memoria`);
        }

        const sessionPath = path.join(__dirname, 'sessions', `whatsapp-${nombre}`);
        try {
            await fsExtra.remove(sessionPath);
            console.log(`Directorio de sesión eliminado para ${nombre}`);
        } catch (err) {
            console.error(`Error al eliminar directorio de sesión para ${nombre}:`, err);
        }

        io.emit('estado', { nombre, estado: 'desconectado' });
    });

    client.initialize();
    res.send(`Bot ${nombre} iniciado. Escanea el QR en /qr?nombre=${nombre}`);
});

app.get('/api/estado', (req, res) => {
    const nombre = req.query.nombre;
    if (!nombre) return res.status(400).send("Falta el nombre");

    const client = sessions[nombre];
    if (!client) return res.status(404).send("Sesión no encontrada");

    if (client.info && client.info.wid) {
        return res.send({ estado: "conectado", numero: client.info.wid.user });
    } else {
        return res.send({ estado: "esperando escaneo" });
    }
});

app.get('/api/eliminar', async (req, res) => {
    const nombre = req.query.nombre;
    if (!nombre) return res.status(400).send("Falta el nombre");

    const client = sessions[nombre];

    try {
        if (client) {
            await client.destroy();
            delete sessions[nombre];
            console.log(`Cliente ${nombre} destruido y eliminado de memoria`);
        }

        // Eliminar archivo de sesión
        const sessionFile = path.join(__dirname, 'sessions', `${nombre}.json`);
        if (fs.existsSync(sessionFile)) {
            fs.unlinkSync(sessionFile);
            console.log(`Archivo de sesión ${nombre}.json eliminado`);
        }

        // Eliminar QR
        const qrPath = path.join(__dirname, 'public', `qr-${nombre}.png`);
        if (fs.existsSync(qrPath)) {
            fs.unlinkSync(qrPath);
            console.log(`QR eliminado para ${nombre}`);
        }

        // Eliminar archivo de respuestas
        const respuestasPath = path.join(__dirname, `respuestas-${nombre}.json`);
        if (fs.existsSync(respuestasPath)) {
            fs.unlinkSync(respuestasPath);
            console.log(`Archivo respuestas-${nombre}.json eliminado`);
        }

        res.send(`Sesión ${nombre} eliminada completamente`);
    } catch (err) {
        console.error(`Error eliminando sesión ${nombre}:`, err);
        res.status(500).send("Error eliminando sesión");
    }
});

app.post('/api/enviar', async (req, res) => {
    const { nombre, numero, mensaje } = req.body;

    if (!sessions[nombre]) return res.status(404).send("Sesión no activa");

    try {
        const client = sessions[nombre];
        await client.sendMessage(`${numero}@c.us`, mensaje);
        res.send("Mensaje enviado");
    } catch (err) {
        console.error(err);
        res.status(500).send("Error al enviar mensaje");
    }
});

// ✅ API para guardar respuestas para un bot específico
app.post('/api/respuestas', (req, res) => {
    const nombre = req.query.nombre;
    if (!nombre) return res.status(400).send("Falta el nombre de la sesión");

    const nuevasRespuestas = req.body;

    if (typeof nuevasRespuestas !== 'object' || Array.isArray(nuevasRespuestas)) {
        return res.status(400).send("Formato inválido, se espera un objeto JSON");
    }

    const filePath = path.join(__dirname, `respuestas-${nombre}.json`);

    fs.writeFile(filePath, JSON.stringify(nuevasRespuestas, null, 2), (err) => {
        if (err) {
            console.error(`Error guardando respuestas-${nombre}.json:`, err);
            return res.status(500).send("Error guardando archivo");
        }

        console.log(`respuestas-${nombre}.json actualizado desde la API`);
        res.send("Respuestas actualizadas correctamente");
    });
});

// ✅ API para consultar respuestas de una sesión específica
app.get('/api/leer_respuestas', (req, res) => {
    const nombre = req.query.nombre;
    if (!nombre) return res.status(400).send("Falta el nombre de la sesión");

    const filePath = path.join(__dirname, `respuestas-${nombre}.json`);

    fs.readFile(filePath, 'utf8', (err, data) => {
        if (err) {
            console.error(`Error leyendo respuestas-${nombre}.json:`, err);
            return res.status(500).send('Error leyendo archivo de respuestas.');
        }

        res.setHeader('Content-Type', 'application/json');
        res.send(data);
    });
});

app.get('/qr', (req, res) => {
    const nombre = req.query.nombre;
    if (!nombre) return res.status(400).send("Falta el nombre");

    const qrFile = path.join(__dirname, 'public', `qr-${nombre}.png`);
    if (fs.existsSync(qrFile)) {
        res.setHeader("Access-Control-Allow-Origin", "*");
        res.sendFile(qrFile);
    } else {
        res.status(404).send("QR no generado aún, inténtalo en unos segundos");
    }
});

server.listen(PORT, () => {
    console.log(`Servidor con WebSocket corriendo en http://51.222.150.96:${PORT}`);
});
EOF

echo "==============================="
echo " Instalando dependencias npm del proyecto "
echo "==============================="
cd ~/bot-backend
npm install

echo "==============================="
echo " Instalando Google Chrome para Puppeteer "
echo "==============================="
wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
sudo apt install -y ./google-chrome-stable_current_amd64.deb

echo "==============================="
echo " Corrigiendo el enlace simbólico chromium-browser "
echo "==============================="
sudo rm -f /usr/bin/chromium-browser
sudo ln -sf /usr/bin/google-chrome /usr/bin/chromium-browser

echo "==============================="
echo " Instalando PM2 "
echo "==============================="
sudo npm install -g pm2
pm2 start server.js --name bot-whatsapp
pm2 save
pm2 startup

echo "==============================="
echo " Instalación completada ✅"
echo "==============================="
echo "Comandos útiles:"
echo " pm2 list"
echo " pm2 logs bot-whatsapp"
echo " pm2 stop bot-whatsapp"
echo " pm2 restart bot-whatsapp"
