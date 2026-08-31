const express   = require("express");
const https     = require("https");
const WebSocket = require("ws");
const path      = require("path");
const os        = require("os");
const fs        = require("fs");

const fmt = (v) => (v != null ? String(v).padStart(8) : "     N/A");

let latestSensor = null;
let latestGPS    = null;
let latestCamera = null;

function printDashboard() {
  console.clear();
  console.log("📡 Galaxy Bridge — 실시간 로그");
  console.log("━".repeat(45));

  if (latestSensor) {
    const { acc, gyro, ori, time } = latestSensor;
    if (acc)  console.log(`🔵 가속도계  x:${fmt(acc.x)}  y:${fmt(acc.y)}  z:${fmt(acc.z)}  m/s²`);
    if (gyro) console.log(`🟢 자이로    α:${fmt(gyro.x)}  β:${fmt(gyro.y)}  γ:${fmt(gyro.z)}  rad/s`);
    if (ori)  console.log(`🟡 방향      α:${fmt(ori.alpha)}°  β:${fmt(ori.beta)}°  γ:${fmt(ori.gamma)}°`);
    console.log(`⏱  센서: ${time}`);
  } else {
    console.log("🔵 센서 대기 중...");
  }

  console.log("━".repeat(45));

  if (latestGPS) {
    const g = latestGPS;
    console.log(`📍 GPS  lat:${g.latitude}  lon:${g.longitude}`);
    console.log(`        acc:±${g.accuracy}m  spd:${g.speed ?? "-"}m/s  heading:${g.heading ?? "-"}°`);
    console.log(`⏱  GPS: ${g.time}`);
  } else {
    console.log("📍 GPS 대기 중...");
  }

  console.log("━".repeat(45));

  if (latestCamera) {
    console.log(`📷 카메라  ${latestCamera.width}x${latestCamera.height}  [${latestCamera.time}]`);
  } else {
    console.log("📷 카메라 대기 중...");
  }

  console.log("━".repeat(45));
  console.log(`💻 Xcode: ${xcodeClients.size}개  |  📱 Galaxy: ${galaxyClients.size}개`);
}

const sslOptions = {
  key:  fs.readFileSync(path.join(__dirname, "key.pem")),
  cert: fs.readFileSync(path.join(__dirname, "cert.pem")),
};

const app    = express();
const server = https.createServer(sslOptions, app);

const wssSensor = new WebSocket.Server({ noServer: true });
const wssXcode  = new WebSocket.Server({ noServer: true });

let xcodeClients  = new Set();
let galaxyClients = new Set();

server.on("upgrade", (req, socket, head) => {
  if (req.url === "/galaxy") {
    wssSensor.handleUpgrade(req, socket, head, (ws) => wssSensor.emit("connection", ws, req));
  } else if (req.url === "/xcode") {
    wssXcode.handleUpgrade(req, socket, head, (ws) => wssXcode.emit("connection", ws, req));
  } else {
    socket.destroy();
  }
});

wssSensor.on("connection", (ws) => {
  console.log("📱 Galaxy connected");
  galaxyClients.add(ws);

  ws.on("message", (data) => {
    try {
      const json = JSON.parse(data);
      const time = new Date(json.ts).toLocaleTimeString("ko-KR");

      if (json.type === "sensors") {
        latestSensor = { acc: json.accelerometer, gyro: json.gyroscope, ori: json.orientation, time };
        printDashboard();
      } else if (json.type === "gps") {
        latestGPS = { ...json, time };
        printDashboard();
      } else if (json.type === "camera") {
        latestCamera = { width: json.width, height: json.height, time };
        printDashboard();
      }
    } catch (e) {}

    xcodeClients.forEach((client) => {
      if (client.readyState === WebSocket.OPEN) client.send(data);
    });
  });

  ws.on("close", () => {
    console.log("📱 Galaxy disconnected");
    galaxyClients.delete(ws);
  });
});

wssXcode.on("connection", (ws) => {
  console.log("💻 Xcode client connected");
  xcodeClients.add(ws);
  ws.on("close", () => {
    console.log("💻 Xcode client disconnected");
    xcodeClients.delete(ws);
  });
});

app.use(express.static(path.join(__dirname, "public")));
app.get("/status", (req, res) => {
  res.json({ galaxy: galaxyClients.size, xcode: xcodeClients.size });
});

const PORT = 8080;
server.listen(PORT, "0.0.0.0", () => {
  const interfaces = os.networkInterfaces();
  let localIP = "localhost";
  Object.values(interfaces).forEach((iface) =>
    iface.forEach((addr) => {
      if (addr.family === "IPv4" && !addr.internal) localIP = addr.address;
    })
  );
  console.log("\n🚀 Galaxy Bridge Server 시작! (HTTPS)");
  console.log(`📱 갤럭시: https://${localIP}:${PORT}`);
  console.log(`💻 Xcode:  wss://${localIP}:${PORT}/xcode\n`);
});
