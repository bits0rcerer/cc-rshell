local URL = "localhost:8080/clients/socket"
local RECONNECT_ATTEMPTS = 10
local RECONNECT_TIMEOUT = 5

local mp = require("rshell-internal.MessagePack")
local msgFactory = require("rshell-internal.messages")
local utils = require("rshell-internal.utils")
local socketSend = require("rshell-internal.socketSend")
local runner = require("rshell-internal.runner")

local _msgTypeHandler = {
    event = function(localTerm, msg)
        if msg.event and msg.params then
            if msg.procID then
                --localTerm.print(string.format("[*] Event: %s for %d. [%s]", msg.event, msg.procID, utils.dump(msg.params)))
                if not runner.Focus(msg.procID) then
                    return
                end
            else
                --localTerm.print(string.format("[*] Event: %s. [%s]", msg.event, utils.dump(msg.params)))
            end

            os.queueEvent(msg.event, table.unpack(msg.params))
        else
            localTerm.print("[!] Received invalid event message.")
        end
    end,

    serverNotification = function(localTerm, msg)
        if msg.message then
            localTerm.print(string.format("[*] Server: %s", msg.message))
        else
            localTerm.print("[!] Received invalid serverNotification message.")
        end
    end,

    cmd = function(localTerm, msg)
        if msg.cmd and msg.procID then
            localTerm.print(string.format("[*] Run %s (%d).", msg.cmd, msg.procID))

            local w, h = -1, -1

            if msg.bufW then
                w = msg.bufW
            end

            if msg.bufH then
                h = msg.bufH
            end

            if msg.params and msg.params ~= nil then
                runner.Runner(msg.procID, w, h, msg.cmd, table.unpack(msg.params))
            else
                runner.Runner(msg.procID, w, h, msg.cmd)
            end
        else
            localTerm.print("[!] Received invalid cmd message.")
        end
    end
}

local function _activateConnection(ws, localTerm)
    local activateMessage = msgFactory.BuildActivateMessage(localTerm)
    local rawMP = mp.pack(activateMessage)
    ws.send(rawMP, true)
end

local function _connectWebSocket(localTerm)
    for _ = 0, RECONNECT_ATTEMPTS do
        local ws = http.websocket("ws://" .. URL)
        if ws then
            -- wrap web socket send method to support message chunking
            local baseSend = ws.send
            ws.send = function(data, isBinary)
                utils.ws_chunkedSend(baseSend, data, isBinary)
            end

            _activateConnection(ws, localTerm)

            localTerm.print("[*] Connected and activated.")
            return ws
        end

        localTerm.print(string.format("[!] Failed to connect to %s. Retrying in %d seconds...", URL, RECONNECT_TIMEOUT))
        sleep(RECONNECT_TIMEOUT)
    end

    error(string.format("unable to reach %s after %d trys.", URL, RECONNECT_ATTEMPTS))
end

local function _handleMessageJSON(rawMessage, localTerm)
    local msg, err = textutils.unserialiseJSON(rawMessage)
    if msg == nil then
        localTerm.print(string.format("[!] Received invalid JSON. Error: %s", err))
    end

    if msg.type then
        if _msgTypeHandler[msg.type] == nil then
            localTerm.print(string.format("[!] Received unsupported message type (%s).", msg.type))
        else
            _msgTypeHandler[msg.type](localTerm, msg)
        end
    end
end

local function _handleMessageMessagePack(rawMessage, localTerm)
    local success, msg = pcall(mp.unpack, rawMessage)
    if not success then
        localTerm.print(string.format("[!] Received invalid MessagePack. Error: %s", msg))
        return
    end

    if msg.type then
        if _msgTypeHandler[msg.type] == nil then
            localTerm.print(string.format("[!] Received unsupported message type (%s).", msg.type))
        else
            _msgTypeHandler[msg.type](localTerm, msg)
        end
    end
end

local function NewWebSocket(localTerm)
    if not http.checkURL("http://" .. URL) then
        error(string.format("not allowed to connect %s.", URL))
    end

    return _connectWebSocket(localTerm)
end

local function ManagerMainLoop(localTerm, ws)
    local function ws_rec()
        while true do
            local msg, isBinary = ws.receive()

            if msg == nil then
                localTerm.print("[!] Lost connection.")
                break
            end

            if isBinary then
                _handleMessageMessagePack(msg, localTerm)
            else
                _handleMessageJSON(msg, localTerm)
            end
        end
    end

    local function ws_send()
        while true do
            local _, msg, isBinary, src = os.pullEvent(socketSend.WS_DISPATCH_MESSAGE)
            if src ~= nil then
                --localTerm.print("[*] WebSocket Message dispatched by " .. src)
            end
            ws.send(msg, isBinary)
        end
    end

    local function proctable()
        while true do
            local _, operation, procID = os.pullEvent("PROC_TABLE")
            if operation == "close" then
                localTerm.print(string.format("[*] Process %d exited.", procID))
                runner.ProcTableRemove(procID)
            end
        end
    end

    parallel.waitForAny(ws_rec, ws_send, proctable)
end

return {
    NewWebSocket = NewWebSocket,
    WebSocketMainLoop = ManagerMainLoop,
}
