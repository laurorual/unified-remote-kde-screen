// KDE Screen Remote - temporary KWin cursor bridge.
// Loaded only while the Unified Remote custom remote is active.

function reportCursor() {
    var pos = workspace.cursorPos;
    var screens = [];
    var outputs = workspace.screens;
    for (var i = 0; i < outputs.length; ++i) {
        var output = outputs[i];
        var geometry = output.geometry;
        screens.push({
            name: output.name,
            x: geometry.x,
            y: geometry.y,
            width: geometry.width,
            height: geometry.height
        });
    }

    // Send strings deliberately. This avoids QJS Number/QVariant numeric
    // type ambiguity across KWin / Qt / dbus-python.
    callDBus(
        "org.kdescreenremote.CursorTracker",
        "/CursorTracker",
        "org.kdescreenremote.CursorTracker",
        "ReportState",
        JSON.stringify({x: pos.x, y: pos.y, screens: screens}),
        function() {}
    );
}

// Plasma 6 exposes this signal directly in the KWin scripting API.
// Event-driven tracking is both lighter and more accurate than polling.
workspace.cursorPosChanged.connect(reportCursor);
workspace.screensChanged.connect(reportCursor);

// Seed the helper immediately.
reportCursor();
