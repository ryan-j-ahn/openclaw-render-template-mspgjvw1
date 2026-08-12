FROM caddy:2.11.4-alpine

# Render's sandbox rejects Caddy's cap_net_bind_service file capability.
# The edge listens on Render's unprivileged PORT, so the capability is unnecessary.
RUN setcap -r /usr/bin/caddy

COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 10000
