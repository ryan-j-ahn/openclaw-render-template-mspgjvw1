FROM node:22.22.3-slim

RUN apt-get update && apt-get install -y \
    git \
    curl \
    procps \
    python3 \
    make \
    g++ \
    cron \
    tini \
    && rm -rf /var/lib/apt/lists/*

# Pin GBrain to the exact release currently proven in production.
RUN curl -fsSL \
      https://github.com/garrytan/gbrain/releases/download/v0.45.8.0/gbrain-linux-x64 \
      -o /usr/local/bin/gbrain \
    && echo '5d54e9b77f8e00c674ec1069b6f3a73dddf89a7fe5def0ffe95edcae677cf506  /usr/local/bin/gbrain' \
      | sha256sum -c - \
    && chmod 0755 /usr/local/bin/gbrain

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --prefer-online && npm cache clean --force

COPY runtime/ ./runtime/
RUN chmod 0755 /app/runtime/*.sh

ENV PATH="/app/node_modules/.bin:$PATH"
ENV ALPHACLAW_ROOT_DIR=/data

RUN mkdir -p /data

EXPOSE 3000

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/runtime/render-start.sh"]
