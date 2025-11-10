#!/usr/bin/env sh
set -eu

: "${DOMAIN:=}"

mkdir -p /etc/caddy

routes='
encode gzip
log

@mist_noslash path /mist
redir @mist_noslash /mist/ 308

@ws_mist path /mist/ws*
reverse_proxy @ws_mist mist:4242 {
  header_up Host {host}
  header_up X-Real-IP {remote}
  header_up X-Forwarded-For {remote}
  header_up X-Forwarded-Proto {scheme}
  transport http {
    versions h2c 1.1
  }
}

handle_path /mist/* {
  reverse_proxy mist:4242
}

handle_path /view/* {
  reverse_proxy mist:8080 {
    header_up X-Mst-Path "{scheme}://{host}/view/"
  }
}

handle_path /hls/* {
  header {
    Access-Control-Allow-Origin *
    Access-Control-Allow-Methods "GET, POST, OPTIONS"
    Access-Control-Allow-Headers "DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range"
    Access-Control-Expose-Headers "Content-Length,Content-Range"
  }
  reverse_proxy mist:8080
}

handle_path /webrtc/* {
  reverse_proxy mist:8080
}

@grafana_noslash path /grafana
redir @grafana_noslash /grafana/ 308

@grafana path /grafana*
handle @grafana {
  reverse_proxy grafana:3000 {
    header_up Host {host}
    header_up X-Forwarded-Host {host}
    header_up X-Forwarded-Proto {scheme}
    header_up X-Forwarded-Prefix /grafana
  }
}

handle {
  respond "Not found" 404
}
'

if [ -n "$DOMAIN" ]; then
  cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
$routes
}
EOF
else
  cat > /etc/caddy/Caddyfile <<'EOF'
:80 {
encode gzip
log

@mist_noslash path /mist
redir @mist_noslash /mist/ 308

@ws_mist path /mist/ws*
reverse_proxy @ws_mist mist:4242 {
  header_up Host {host}
  header_up X-Real-IP {remote}
  header_up X-Forwarded-For {remote}
  header_up X-Forwarded-Proto {scheme}
  transport http {
    versions h2c 1.1
  }
}

handle_path /mist/* {
  reverse_proxy mist:4242
}

handle_path /view/* {
  reverse_proxy mist:8080 {
    header_up X-Mst-Path "{scheme}://{host}/view/"
  }
}

handle_path /hls/* {
  header {
    Access-Control-Allow-Origin *
    Access-Control-Allow-Methods "GET, POST, OPTIONS"
    Access-Control-Allow-Headers "DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range"
    Access-Control-Expose-Headers "Content-Length,Content-Range"
  }
  reverse_proxy mist:8080
}

handle_path /webrtc/* {
  reverse_proxy mist:8080
}

@grafana_noslash path /grafana
redir @grafana_noslash /grafana/ 308

@grafana path /grafana*
handle @grafana {
  reverse_proxy grafana:3000 {
    header_up Host {host}
    header_up X-Forwarded-Host {host}
    header_up X-Forwarded-Proto {scheme}
    header_up X-Forwarded-Prefix /grafana
  }
}

handle {
  respond "Not found" 404
}
}
EOF
fi

exit 0
