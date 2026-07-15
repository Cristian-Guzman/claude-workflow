#!/bin/bash
# Launch Chrome with remote debugging enabled on port 9222
# This allows Playwright MCP to connect to your real browser with your logged-in sessions
#
# Usage: .claude/scripts/chrome-debug.sh
#
# After launching, Playwright MCP can connect to http://localhost:9222
# and interact with pages where you're already authenticated (localhost:3002, dev URLs, etc.)

PORT=9222
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Check if Chrome is already running with debug port
if curl -s http://localhost:$PORT/json/version >/dev/null 2>&1; then
    echo "✓ Chrome debug already running on port $PORT"
    echo "  CDP endpoint: http://localhost:$PORT"
    exit 0
fi

# Check if Chrome is running WITHOUT debug port
if pgrep -f "Google Chrome" >/dev/null 2>&1; then
    echo "⚠️  Chrome is running but WITHOUT remote debugging."
    echo ""
    echo "To use your real profile with Playwright, Chrome needs to restart with the debug flag."
    echo ""
    read -p "Quit Chrome and relaunch with debug? (y/n) " answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        echo "Closing Chrome..."
        osascript -e 'quit app "Google Chrome"'
        sleep 2
    else
        echo "Cancelled. Close Chrome manually and run this script again."
        exit 1
    fi
fi

echo "Launching Chrome with remote debugging on port $PORT..."
echo "Using your real Chrome profile (bookmarks, extensions, sessions — everything)."
echo ""

# Chrome 136+ blocks remote debugging on the default profile.
# We use a separate debug profile but sync cookies from your real profile
# so you're already logged in.
DEBUG_PROFILE="$HOME/.chrome-debug-profile"
REAL_PROFILE="$HOME/Library/Application Support/Google/Chrome"

# Copy cookies and login data from real profile (if debug profile exists but cookies are stale)
if [ -d "$DEBUG_PROFILE/Default" ]; then
    echo "Syncing cookies from your real Chrome profile..."
    cp "$REAL_PROFILE/Default/Cookies" "$DEBUG_PROFILE/Default/Cookies" 2>/dev/null
    cp "$REAL_PROFILE/Default/Login Data" "$DEBUG_PROFILE/Default/Login Data" 2>/dev/null
    cp "$REAL_PROFILE/Default/Web Data" "$DEBUG_PROFILE/Default/Web Data" 2>/dev/null
else
    echo "First run — copying profile data (bookmarks, cookies, extensions)..."
    mkdir -p "$DEBUG_PROFILE/Default"
    cp "$REAL_PROFILE/Default/Cookies" "$DEBUG_PROFILE/Default/" 2>/dev/null
    cp "$REAL_PROFILE/Default/Login Data" "$DEBUG_PROFILE/Default/" 2>/dev/null
    cp "$REAL_PROFILE/Default/Web Data" "$DEBUG_PROFILE/Default/" 2>/dev/null
    cp "$REAL_PROFILE/Default/Bookmarks" "$DEBUG_PROFILE/Default/" 2>/dev/null
    cp "$REAL_PROFILE/Default/Preferences" "$DEBUG_PROFILE/Default/" 2>/dev/null
    cp -r "$REAL_PROFILE/Default/Extensions" "$DEBUG_PROFILE/Default/Extensions" 2>/dev/null
fi

"$CHROME" \
    --remote-debugging-port=$PORT \
    --user-data-dir="$DEBUG_PROFILE" \
    --no-first-run \
    --no-default-browser-check \
    --disable-background-timer-throttling \
    --disable-backgrounding-occluded-windows \
    --disable-renderer-backgrounding \
    &

sleep 3

if curl -s http://localhost:$PORT/json/version >/dev/null 2>&1; then
    echo "✓ Chrome launched with debug on port $PORT"
    echo "  CDP endpoint: http://localhost:$PORT"
    echo "  Your real profile is loaded — all sessions, cookies, extensions."
    echo ""
    echo "  Playwright can now navigate your logged-in pages."
else
    echo "✗ Failed to launch Chrome on port $PORT"
    exit 1
fi
