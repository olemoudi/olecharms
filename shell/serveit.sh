# serveit — start a static file server in the current directory
# Inspired by https://evanhahn.com/scripts-i-wrote-that-i-use-all-the-time/
serveit() {
    local port="${1:-8000}"
    if command -v python3 >/dev/null 2>&1; then
        echo "Serving on http://localhost:$port (python3)" >&2
        python3 -m http.server "$port"
    elif command -v python >/dev/null 2>&1; then
        echo "Serving on http://localhost:$port (python2)" >&2
        python -m SimpleHTTPServer "$port"
    elif command -v npx >/dev/null 2>&1; then
        echo "Serving on http://localhost:$port (npx serve)" >&2
        npx -y serve -l "$port"
    elif command -v ruby >/dev/null 2>&1; then
        echo "Serving on http://localhost:$port (ruby)" >&2
        ruby -run -e httpd . -p "$port"
    elif command -v php >/dev/null 2>&1; then
        echo "Serving on http://localhost:$port (php)" >&2
        php -S "localhost:$port"
    else
        echo "serveit: no suitable server found (tried python3, python, npx, ruby, php)" >&2
        return 1
    fi
}
