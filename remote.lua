local server = libs.server;
local fs = libs.fs;
local script = libs.script;
local timer = libs.timer;
local log = libs.log;
local mouse = libs.mouse;

local run_dir = "/tmp/kde-screen-remote";
local state_file = run_dir .. "/state.txt";
local zoom_file = run_dir .. "/zoom.txt";
local pid_file = run_dir .. "/stream.pid";
local python_bin = "/usr/local/libexec/kde-screen-remote-python";

local helper_path = nil;
local cursor_script_path = nil;
local poll_timer = -1;
local polling = false;
local last_seq = -1;

local zoom = 2;
local dragging = false;

local touches = {};
local touch_count = 0;

local multitouch_active = false;
local multitouch_scrolled = false;
local multitouch_start_time = 0;
local multitouch_start_centroid_y = nil;
local multitouch_last_centroid_y = nil;
local multitouch_total_distance = 0;

local suppress_tap = false;
local suppress_timer = -1;

local scroll_accum = 0;

-- Touchscreen-coordinate pixels per wheel step.
local SCROLL_PIXELS_PER_STEP = 18;

-- If centroid moves less than this in total, treat it as a right-click tap.
local RIGHT_CLICK_MOVE_THRESHOLD = 14;

-- A very long two-finger hold should not accidentally right-click.
local RIGHT_CLICK_MAX_MS = 650;

local function q(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'";
end

local function now_ms()
    return os.clock() * 1000;
end

local function dlog(text)
    pcall(function()
        log.info(
            "[KDE Screen Remote v1.0.2] " ..
            tostring(text)
        );
    end);
end

local function kill_helpers()
    local cmd = table.concat({
        "set +e",
        "pids=$(pgrep -f '[k]de_screen_remote_streamer.py')",
        "if [ -n \"$pids\" ]; then",
        "  kill -TERM $pids 2>/dev/null",
        "  for i in $(seq 1 30); do",
        "    sleep 0.05",
        "    alive=''",
        "    for p in $pids; do",
        "      if kill -0 \"$p\" 2>/dev/null; then",
        "        alive=\"$alive $p\"",
        "      fi",
        "    done",
        "    [ -z \"$alive\" ] && break",
        "  done",
        "  for p in $pids; do",
        "    if kill -0 \"$p\" 2>/dev/null; then",
        "      kill -KILL \"$p\" 2>/dev/null",
        "    fi",
        "  done",
        "fi",
        "rm -f " .. q(pid_file),
        "exit 0"
    }, "\n");

    pcall(script.shell, cmd);
end

local function write_zoom()
    pcall(function()
        fs.write(
            zoom_file,
            tostring(zoom) .. "\n"
        );
    end);

    local text = "Zoom: sem zoom";

    if zoom == 2 then
        text = "Zoom: 2×";
    elseif zoom == 3 then
        text = "Zoom: 3×";
    end

    pcall(function()
        server.update({
            id = "zoom",
            text = text
        });
    end);
end

local function start_helper()
    kill_helpers();

    last_seq = -1;

    pcall(function()
        if fs.exists(state_file) then
            fs.delete(state_file);
        end
    end);

    write_zoom();

    local cmd =
        "mkdir -p " .. q(run_dir) .. "; " ..
        "nohup " .. q(python_bin) .. " " ..
        q(helper_path) ..
        " --fps 10 --width 960 --quality 55" ..
        " --cursor-script " .. q(cursor_script_path) ..
        " >>" .. q(run_dir .. "/launcher.log") ..
        " 2>&1 </dev/null &";

    local ok, out = pcall(
        script.shell,
        cmd
    );

    if not ok then
        dlog(
            "helper start failed: " ..
            tostring(out)
        );
        return false;
    end

    return true;
end

local function read_seq_and_path()
    if not fs.exists(state_file) then
        return nil, nil;
    end

    local ok, text = pcall(
        fs.read,
        state_file
    );

    if not ok or text == nil then
        return nil, nil;
    end

    local lines = {};

    for line in string.gmatch(
        text,
        "([^\n]+)"
    ) do
        table.insert(lines, line);
    end

    if #lines < 2 then
        return nil, nil;
    end

    return tonumber(lines[1]), lines[2];
end

local function poll()
    if not polling then
        return;
    end

    local seq, path = read_seq_and_path();

    if (
        seq ~= nil and
        path ~= nil and
        seq ~= last_seq
    ) then
        last_seq = seq;

        local ok, err = pcall(function()
            server.update({
                id = "screen",
                image = path
            });
        end);

        if not ok then
            dlog(
                "frame update failed: " ..
                tostring(err)
            );
        end
    end

    if polling then
        poll_timer = timer.timeout(
            poll,
            40
        );
    end
end

local function start_polling()
    if polling then
        return;
    end

    polling = true;
    poll();
end

local function left_click()
    mouse.down("left");
    mouse.up("left");
end

local function right_click()
    mouse.down("right");
    mouse.up("right");
end

local function double_left_click()
    mouse.down("left");
    mouse.up("left");
    mouse.down("left");
    mouse.up("left");
end

local function arm_tap_suppression()
    suppress_tap = true;

    if (
        suppress_timer ~= nil and
        suppress_timer ~= -1
    ) then
        pcall(function()
            timer.cancel(suppress_timer);
        end);
    end

    suppress_timer = timer.timeout(
        function()
            suppress_tap = false;
            suppress_timer = -1;
        end,
        500
    );
end

local function reset_multitouch()
    multitouch_active = false;
    multitouch_scrolled = false;
    multitouch_start_time = 0;
    multitouch_start_centroid_y = nil;
    multitouch_last_centroid_y = nil;
    multitouch_total_distance = 0;
    scroll_accum = 0;
end

local function current_centroid_y()
    if touch_count < 2 then
        return nil;
    end

    local sum = 0;
    local count = 0;

    for _, touch in pairs(touches) do
        if touch ~= nil then
            sum = sum + touch.y;
            count = count + 1;
        end
    end

    if count < 2 then
        return nil;
    end

    return sum / count;
end

local function start_multitouch()
    local cy = current_centroid_y();

    if cy == nil then
        return;
    end

    multitouch_active = true;
    multitouch_scrolled = false;
    multitouch_start_time = now_ms();
    multitouch_start_centroid_y = cy;
    multitouch_last_centroid_y = cy;
    multitouch_total_distance = 0;
    scroll_accum = 0;

    -- Block the ordinary one-finger tap callbacks.
    suppress_tap = true;
end

local function apply_centroid_scroll()
    if not multitouch_active then
        return;
    end

    local cy = current_centroid_y();

    if cy == nil then
        return;
    end

    if multitouch_last_centroid_y == nil then
        multitouch_last_centroid_y = cy;
        return;
    end

    local dy = cy - multitouch_last_centroid_y;
    multitouch_last_centroid_y = cy;

    multitouch_total_distance =
        multitouch_total_distance + math.abs(dy);

    scroll_accum =
        scroll_accum + dy / SCROLL_PIXELS_PER_STEP;

    if math.abs(scroll_accum) >= 1 then
        local steps;

        if scroll_accum > 0 then
            steps = math.floor(scroll_accum);
        else
            steps = math.ceil(scroll_accum);
        end

        if steps ~= 0 then
            pcall(function()
                mouse.vscroll(steps);
            end);

            scroll_accum =
                scroll_accum - steps;

            multitouch_scrolled = true;
        end
    end
end

events.focus = function()
    local remote_dir = fs.remotedir();

    helper_path = fs.combine(
        remote_dir,
        "kde_screen_remote_streamer.py"
    );

    cursor_script_path = fs.combine(
        remote_dir,
        "cursor_tracker.js"
    );

    kill_helpers();

    dragging = false;
    zoom = 2;
    touches = {};
    touch_count = 0;
    reset_multitouch();

    if start_helper() then
        start_polling();
    end
end

events.blur = function()
    polling = false;

    if (
        poll_timer ~= nil and
        poll_timer ~= -1
    ) then
        pcall(function()
            timer.cancel(poll_timer);
        end);
    end

    poll_timer = -1;

    if dragging then
        pcall(function()
            mouse.dragend();
            mouse.up("left");
        end);

        dragging = false;
    end

    touches = {};
    touch_count = 0;
    reset_multitouch();

    kill_helpers();

    dlog("blur: stream stopped");
end

actions.cycle_zoom = function()
    if zoom == 1 then
        zoom = 2;
    elseif zoom == 2 then
        zoom = 3;
    else
        zoom = 1;
    end

    write_zoom();

    dlog(
        "zoom changed to " ..
        tostring(zoom) .. "x"
    );
end

actions.touch_start = function(id, x, y)
    if touches[id] == nil then
        touches[id] = {
            x = tonumber(x) or 0,
            y = tonumber(y) or 0
        };

        touch_count = touch_count + 1;
    else
        touches[id].x = tonumber(x) or touches[id].x;
        touches[id].y = tonumber(y) or touches[id].y;
    end

    if (
        touch_count >= 2 and
        not multitouch_active
    ) then
        start_multitouch();
    end
end

actions.touch_abs = function(id, x, y)
    local touch = touches[id];

    if touch == nil then
        touches[id] = {
            x = tonumber(x) or 0,
            y = tonumber(y) or 0
        };
        touch_count = touch_count + 1;
    else
        touch.x = tonumber(x) or touch.x;
        touch.y = tonumber(y) or touch.y;
    end

    if (
        touch_count >= 2 and
        not multitouch_active
    ) then
        start_multitouch();
    end

    if multitouch_active then
        apply_centroid_scroll();
    end
end

actions.touch_delta = function(id, dx, dy)
    -- For one finger, use the known-good official Basic Input MT path.
    if not multitouch_active and touch_count <= 1 then
        pcall(function()
            mouse.moveraw(
                tonumber(dx) or 0,
                tonumber(dy) or 0
            );
        end);
    end

    -- Two-finger scrolling deliberately ignores the independent delta events.
    -- It is driven by the centroid from ontouchabs instead.
end

actions.touch_end = function(id, x, y)
    if touches[id] ~= nil then
        touches[id] = nil;
        touch_count = math.max(
            0,
            touch_count - 1
        );
    end

    if (
        multitouch_active and
        touch_count == 0
    ) then
        local duration =
            now_ms() - multitouch_start_time;

        local should_right_click =
            not multitouch_scrolled
            and multitouch_total_distance
                < RIGHT_CLICK_MOVE_THRESHOLD
            and duration < RIGHT_CLICK_MAX_MS;

        if should_right_click then
            pcall(right_click);
            dlog(
                "two-finger tap: right click"
            );
        else
            dlog(
                "two-finger gesture: scroll " ..
                "distance=" ..
                tostring(
                    math.floor(
                        multitouch_total_distance
                    )
                )
            );
        end

        arm_tap_suppression();
        reset_multitouch();
    end
end

actions.tap = function()
    if suppress_tap then
        return;
    end

    if dragging then
        pcall(function()
            mouse.dragend();
            mouse.up("left");
        end);

        dragging = false;
    else
        pcall(left_click);
    end
end

actions.double = function()
    if (
        not suppress_tap and
        not dragging
    ) then
        pcall(double_left_click);
    end
end

actions.hold = function()
    if (
        touch_count <= 1 and
        not multitouch_active and
        not dragging
    ) then
        pcall(function()
            mouse.down("left");
            mouse.dragbegin();
        end);

        dragging = true;
    end
end
