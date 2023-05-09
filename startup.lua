-- Elevator Contoller Program
local pretty = require "cc.pretty";

local MESSAGE_TYPE = {
    FLOOR_INIT = "floor_init",
    FLOOR_STATE = "floor_state",
    CTRL_INIT = "ctrl_init",
    CTRL_STATE = "ctrl_state"
};

-- Main Controller for elevator
local ctrl_floors = {};

local ctrl_state = {
    elevatorIsPassingFloorId = nil,
    elevatorIsStoppedOnFloorId = nil,
    elevatorIsMoving = false,
    allDoorsAreClosed = false,
    breakIsOn = true,
    direction = "up",
    isStopped = false,
    isHome = false,
    isResetting = false
};

local ctrl_sides = {
    breakCtrl = "back",
    directionCtrl = "left",
    diskDrive = "right",
    rednet = "top",
    detectorHome = "bottom",
    detectorMoving = "front"
};

function ctrl_initialize()
    print("Initializing elevator controller");
    -- Align output settings to be consistent with a restarted computer's state
    ctrl_setBreak(true);
    ctrl_setDirection("up");

    -- Open rednet
    rednet.open(ctrl_sides.rednet);

    -- Send init message to all floors and wait for responses
    local function sendInitMessage()
        util_sendRednetMessage({
            type = MESSAGE_TYPE.CTRL_INIT
        });
        sleep(1); -- time to wait for responses
    end

    -- Handle upate messages from floors
    local function handleModemInitMessage()
        while true do
            local msg = util_getRednetMessage();
            if (msg.type == MESSAGE_TYPE.FLOOR_INIT or msg.type == MESSAGE_TYPE.FLOOR_STATE) then
                ctrl_updateFloor(msg);
            else
                print("Unknown message received");
                print(pretty.pretty_print(msg));
            end
        end
    end

    -- trigger floor init and wait for either update messages or timeout
    print("Initializing floors");
    parallel.waitForAny(handleModemInitMessage, sendInitMessage);

    if (#ctrl_floors == 0) then
        print("No floors found");
        return false;
    elseif (#ctrl_floors == 1) then
        print("An elevator with only one floor is not an elevator");
        return false;
    end

    print("Floors initialized");
    if (ctrl_state.elevatorIsStoppedOnFloorId == nil) then
        print("Elevator is not stopped on any floor, raising to the nearest floor");
        return ctrl_resetElevator();
    end

    print("Elevator is stopped on floor " .. tostring(ctrl_indexOfFloorId(ctrl_state.elevatorIsStoppedOnFloorId)));
    ctrl_sendState();
    return true;
end

function ctrl_resetElevator()
    ctrl_setBreak(false);
    ctrl_setDirection("up");

    -- wait for elevator to start moving

    local function waitForElevatorToStartMoving()
        while not ctrl_isMoving() do
            os.pullEvent("redstone");
        end
        print("Elevator is moving");
    end

    parallel.waitForAny(waitForElevatorToStartMoving, function()
        sleep(2);
    end);

    if (not ctrl_isMoving()) then
        print("Elevator did not start moving.");
        print("Elevator may be disconneced. trying to move it down.")
        ctrl_setDirection("down");

        parallel.waitForAny(waitForElevatorToStartMoving, function()
            sleep(10);
        end);

        if (not ctrl_isMoving()) then
            print("Elevator did not start moving.");
            print("Elevator may be stuck or missing. Aborting reset.")
            return false;
        end
    end

    ctrl_state.isResetting = true;
    ctrl_sendState();

    local function waitForEleveatorToPassFloor()
        local done = false;
        while not done do
            local msg = util_getRednetMessage();
            if (msg.type == MESSAGE_TYPE.FLOOR_STATE) then
                print("Floor floor state message received");
                ctrl_updateFloor(msg);
                if (ctrl_state.elevatorIsPassingFloorId ~= nil) then
                    print("Elevator is passing floor " ..
                              tostring(ctrl_indexOfFloorId(ctrl_state.elevatorIsPassingFloorId)) .. ", stopping...");
                    ctrl_setBreak(true);
                elseif (ctrl_state.elevatorIsStoppedOnFloorId ~= nil) then
                    print("Elevator has stopped on floor " ..
                              tostring(ctrl_indexOfFloorId(ctrl_state.elevatorIsStoppedOnFloorId)));
                    done = true;
                end
            else
                print("Unknown message received");
                print(pretty.pretty_print(data));
            end
        end
    end

    local function waitForEleveatorHome()
        while not ctrl_isHome() do
            os.pullEvent("redstone");
        end
        print("Elevator is home, sending it down to the top floor");
        ctrl_setDirection("down");
        ctrl_setBreak(false);
        while true do
            sleep(60);
        end -- wait forever
    end

    local function timeout()
        sleep(60);
    end

    parallel.waitForAny(waitForEleveatorToPassFloor, waitForEleveatorHome, timeout);

    ctrl_state.isResetting = false;
    ctrl_sendState();

    if (ctrl_state.elevatorIsStoppedOnFloorId == nil) then
        print("Elevator could not be reset, exiting");
        return false;
    end

    print("Elevator reset to floor " .. tostring(ctrl_indexOfFloorId(ctrl_state.elevatorIsStoppedOnFloorId)));
    return true;
end

function ctrl_isHome()
    return rs.getInput(ctrl_sides.detectorHome);
end

function ctrl_isMoving()
    return not rs.getInput(ctrl_sides.detectorMoving);
end

function ctrl_handleModemMessages()
    while true do
        local msg = util_getRednetMessage();
        if (msg.type == MESSAGE_TYPE.FLOOR_STATE) then
            print("Floor state message received");
            ctrl_updateFloor(msg);
        elseif (msg.type == MESSAGE_TYPE.FLOOR_INIT) then
            print("Floor init message received");
            ctrl_updateFloor(msg);
            ctrl_sendState(msg.id);
        else
            print("Unknown message received");
            print(pretty.pretty_print(data));
        end
    end
end

function ctrl_updateFloor(msg)
    local floor = {
        id = msg.id,
        state = msg.payload.state,
        distance = msg.distance
    };

    local idx = ctrl_indexOfFloorId(floor.id);
    if (idx ~= nil) then
        ctrl_floors[idx] = floor;
    else
        table.insert(ctrl_floors, floor);
    end

    -- Sort floors by distance from controller with the bottom floor (furthest) at index 1
    table.sort(ctrl_floors, function(a, b)
        return a.distance > b.distance
    end);

    ctrl_updateState();
end

function ctrl_updateState()
    ctrl_state.elevatorIsStoppedOnFloorId = nil;
    ctrl_state.elevatorIsPassingFloorId = nil;
    ctrl_state.allDoorsAreClosed = true;

    for i, v in ipairs(ctrl_floors) do
        if (v.state.elevatorIsStoppedHere) then
            ctrl_state.elevatorIsStoppedOnFloorId = v.id;
        end
        if (v.state.elevatorIsPassingHere) then
            ctrl_state.elevatorIsPassingFloorId = v.id;
        end
        if (not v.state.doorIsClosed) then
            ctrl_state.allDoorsAreClosed = false;
        end
    end

    ctrl_state.breakIsOn = ctrl_getBreak();
    ctrl_state.direction = ctrl_getDirection();
    ctrl_state.isStopped = ctrl_state.elevatorIsStoppedOnFloorId ~= nil;
    ctrl_state.isHome = ctrl_isHome();
    ctrl_state.isMoving = ctrl_isMoving();
end

function ctrl_sendState(replyChannel)
    util_sendRednetMessage({
        type = MESSAGE_TYPE.CTRL_STATE,
        state = ctrl_state
    }, replyChannel);
end

function ctrl_setBreak(breakOn)
    redstone.setOutput(ctrl_sides.breakCtrl, not (breakOn or false));
end

function ctrl_getBreak()
    return not redstone.getOutput(ctrl_sides.breakCtrl);
end

function ctrl_setDirection(direction)
    if direction ~= "down" then
        redstone.setOutput(ctrl_sides.directionCtrl, false);
    else
        redstone.setOutput(ctrl_sides.directionCtrl, true);
    end
end

function ctrl_getDirection()
    if redstone.getOutput(ctrl_sides.directionCtrl) then
        return "down";
    else
        return "up";
    end
end

-- Controller utility functions

function ctrl_indexOfFloorId(id)
    for i, v in ipairs(ctrl_floors) do
        if (v.id == id) then
            return i;
        end
    end
    return nil;
end

-- Main loop for controller
function ctrl_main()
    while not ctrl_initialize() do
        print("Initialization failed, retrying in 5 seconds...");
        sleep(5);
    end
    parallel.waitForAll(ctrl_handleModemMessages);
end

-- Floor Controller for elevator

local floor_ctrl_state = {
    ctrlId = nil
};

local floor_state = {
    doorIsClosed = false,
    doorIsOpening = false,
    elevatorIsPassingHere = false,
    elevatorIsStoppedHere = false
};

local floor_sides = {
    rednet = "back",
    doorCtrl = "bottom",
    detectDoor = "right",
    detectStopped = "front",
    detectPassing = "top"
};

function floor_initialize()
    print("Initializing elevator floor controller");
    floor_setDoorOpen(false);
    rednet.open(floor_sides.rednet);
    floor_updateStateFromRedstone();
    floor_sendState();
end

function floor_updateStateFromRedstone()
    floor_state.doorIsClosed = floor_isDoorClosed();
    floor_state.doorIsOpening = floor_getDoorOpen();
    floor_state.elevatorIsStoppedHere = floor_isElevatorStoppedHere();
    floor_state.elevatorIsPassingHere = floor_isElevatorPassing();
end

function floor_sendState()
    local replyChannel = floor_ctrl_state.ctrlId;
    local msgType = MESSAGE_TYPE.FLOOR_STATE;
    if (replyChannel == nil) then
        msgType = MESSAGE_TYPE.FLOOR_INIT
    end
    util_sendRednetMessage({
        type = msgType,
        state = floor_state
    }, replyChannel);
end

function floor_handleModemMessages()
    while true do
        print("Waiting for message...");
        local msg = util_getRednetMessage();
        print("Message received");

        if (msg.type == MESSAGE_TYPE.CTRL_INIT) then
            print("ctrl init message received");
            floor_sendState(msg.id);
        elseif (msg.type == MESSAGE_TYPE.CTRL_STATE) then
            print("ctrl state message received");

            floor_ctrl_state = msg.payload.state;
            floor_ctrl_state.ctrlId = msg.id;

            print(pretty.pretty_print(floor_ctrl_state));

        else
            print("Unknown message received");
            print(pretty.pretty_print(data));
        end
    end
end

function floor_handleRedstoneEvent()
    while true do
        os.pullEvent("redstone");
        floor_updateStateFromRedstone();
        floor_sendState();
    end
end

function floor_setDoorOpen(open)
    redstone.setOutput(floor_sides.doorCtrl, open or false);
end

function floor_getDoorOpen()
    return redstone.getOutput(floor_sides.doorCtrl);
end

function floor_isDoorClosed()
    return redstone.getInput(floor_sides.detectDoor);
end

function floor_isElevatorPassing()
    return redstone.getInput(floor_sides.detectPassing);
end

function floor_isElevatorStoppedHere()
    return redstone.getInput(floor_sides.detectStopped);
end

-- Main loop for floor

function floor_main()
    floor_initialize();
    parallel.waitForAll(floor_handleRedstoneEvent, floor_handleModemMessages);
end

-- Common utility functions

function util_getRednetMessage()
    local _, _, _, replyChannel, data, distance = os.pullEvent("modem_message");
    print("Received message from " .. replyChannel .. " at distance " .. distance);
    local message = {
        id = replyChannel,
        distance = distance,
        type = data.message.type,
        payload = data.message
    };
    return message;
end

function util_sendRednetMessage(payload, channel)
    if (channel == nil) then
        channel = rednet.CHANNEL_BROADCAST;
    end
    rednet.send(channel, payload);
end

-- Main program startup for elevator

function main()
    term.clear();
    term.setCursorPos(1, 1);

    if peripheral.getType(ctrl_sides.diskDrive) == "drive" then
        ctrl_main();
    else
        floor_main();
    end
    print("Exiting...");
end

main();
