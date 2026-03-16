const WebSocket = require("ws")

const wss = new WebSocket.Server({ port: 3000 })

let clients = []

wss.on("connection", ws => {

  clients.push(ws)
  console.log("Client connected")

  ws.on("message", message => {

    const data = JSON.parse(message)

    // broadcast to all dashboards
    clients.forEach(client => {
      if (client.readyState === WebSocket.OPEN) {
        client.send(JSON.stringify(data))
      }
    })
  })

  ws.on("close", () => {
    clients = clients.filter(c => c !== ws)
  })
})

console.log("WebSocket server running on port 3000")
console.log("Incoming posture data:", data)