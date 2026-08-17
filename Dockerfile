# AionUi WebUI — imagem própria, multi-stage.
#
# O Dockerfile oficial do repo (iOfficeAI/AionUi) está abandonado: referencia
# `bun run build:renderer:web` e `scripts/build-server.mjs`, que não existem mais.
# Este arquivo reconstrói o caminho vivo: `scripts/webui.ts` (que embrulha o
# pacote @aionui/web-host) + o backend Rust `aioncore`, baixado do repo AionCore.
#
# As duas versões andam juntas — o commit que sobe o AionUi para 2.1.57 sobe o
# aioncore para v0.1.68. Manter os dois ARGs em sincronia ao atualizar.

# ---------------------------------------------------------------- builder ----
FROM node:20-slim AS builder

ARG AIONUI_REF=v2.1.57
# Heap do V8 para o bundle do renderer. Ver a nota de calibragem no RUN abaixo.
ARG NODE_HEAP_MB=6144

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         git curl ca-certificates python3 build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g bun

WORKDIR /app

# Clone completo do tag: o repo é um workspace bun (`workspaces: packages/*`),
# então packages/ precisa existir ANTES do install — foi exatamente por copiar
# só package.json que o Dockerfile oficial quebrava em @aionui/web-host.
RUN git clone --depth 1 --branch ${AIONUI_REF} https://github.com/iOfficeAI/AionUi.git .

# HUSKY=0: o script `prepare` roda husky, que falha fora de um repo com hooks.
# --ignore-scripts: pula o postinstall, que tentaria baixar o aioncore de um
# artifact do GitHub Actions (precisa de GH_TOKEN). Buscamos do release no
# estágio de runtime.
#
# O install baixa ~3200 pacotes; um tarball grande falhando na rede derruba o
# build inteiro (aconteceu com @sentry/cli-linux-x64, binário opcional que só
# serve para upload de sourcemap). Daí o retry, e o fallback sem opcionais.
ENV HUSKY=0
RUN ok=0; \
    for i in 1 2 3 4 5; do \
      if bun install --ignore-scripts; then ok=1; break; fi; \
      echo ">> tentativa $i falhou, aguardando 15s"; sleep 15; \
    done; \
    if [ "$ok" != "1" ]; then \
      echo ">> retries esgotados, instalando sem dependencias opcionais"; \
      bun install --ignore-scripts --omit=optional; \
    fi

# Gera out/renderer (assets estáticos servidos pela WebUI).
#
# São ~10.300 módulos num bundle só: com o heap padrão do V8 (~2 GB) o build
# morre com "Reached heap limit".
#
# Calibragem: 2048 (padrão do V8) estoura. No servidor da N49, 4096 morria com
# SIGKILL (morte seca, sem stack trace) — e não por falta de RAM no host, que
# tem ~12 GB com ~8,5 GB livres; o teto vinha do container de build. No runner
# do Actions (16 GB) não há esse limite, daí 6144.
RUN NODE_OPTIONS=--max-old-space-size=${NODE_HEAP_MB} bun run package

# ---------------------------------------------------------------- runtime ----
# Estágio separado para não carregar as devDependencies (electron, playwright,
# electron-builder, vitest, jest) nem as toolchains de compilação: em single
# stage a imagem passava de 1,6 GB, e o pull de 956 MB numa camada só derrubava
# o deploy por reset de conexão no meio da transferência.
FROM node:20-slim AS runtime

ARG AIONCORE_VERSION=v0.1.68
ARG AIONCORE_TARGET=x86_64-unknown-linux-gnu

ENV DEBIAN_FRONTEND=noninteractive

# git/curl: os agentes trabalham com repositórios. gosu: drop de privilégio no
# entrypoint. libicu: o officecli (preview de Office, baixado em runtime pelo
# backend) é um binário .NET que aborta sem ICU. Preferimos o runtime libicu72
# ao libicu-dev, que arrastaria headers e libc6-dev de volta.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         ca-certificates git curl gosu \
    && (apt-get install -y --no-install-recommends libicu72 \
        || apt-get install -y --no-install-recommends libicu-dev) \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g bun tsx

WORKDIR /app

# Fontes que o `tsx scripts/webui.ts` precisa em runtime, mais os manifests do
# workspace (sem packages/ o install de produção não resolve @aionui/web-host).
COPY --from=builder /app/package.json /app/bun.lock /app/tsconfig.json ./
COPY --from=builder /app/patches   ./patches
COPY --from=builder /app/packages  ./packages
COPY --from=builder /app/scripts   ./scripts
COPY --from=builder /app/out       ./out

RUN ok=0; \
    for i in 1 2 3; do \
      if bun install --production --ignore-scripts; then ok=1; break; fi; \
      echo ">> tentativa $i falhou"; sleep 10; \
    done; \
    [ "$ok" = "1" ]

# Backend Rust, do release público do AionCore.
RUN mkdir -p /opt/aioncore \
    && curl -fsSL -o /tmp/aioncore.tar.gz \
         "https://github.com/iOfficeAI/AionCore/releases/download/${AIONCORE_VERSION}/aioncore-${AIONCORE_VERSION}-${AIONCORE_TARGET}.tar.gz" \
    && tar -xzf /tmp/aioncore.tar.gz -C /opt/aioncore \
    && rm /tmp/aioncore.tar.gz \
    && BIN="$(find /opt/aioncore -type f -name aioncore | head -n1)" \
    && test -n "$BIN" \
    && chmod +x "$BIN" \
    && ln -sf "$BIN" /usr/local/bin/aioncore \
    && aioncore --version

# CLIs de agente disponíveis dentro do container.
RUN npm install -g @anthropic-ai/claude-code @openai/codex || true

# O AionUi invoca o Claude Code com --dangerously-skip-permissions, e o Claude
# recusa essa flag como root ("cannot be used with root/sudo privileges for
# security reasons") — o agente morria na hora com exit code 1 e a UI mostrava
# USER_AGENT_DISCONNECTED. Daí rodar não-root. Vale como boa prática de
# qualquer forma: é um agente com acesso a shell.
#
# Usamos o usuário `node`, que a imagem base já traz no uid 1000 (criar outro
# ali falha com exit code 4, uid em uso).

# HOME dentro do volume: o `claude` grava credencial em $HOME/.claude e o `codex`
# em $HOME/.codex. Com o HOME padrão (/root, dentro da camada do container) o
# login se perderia a cada redeploy — inclusive no build automático diário.
ENV HOME=/data/home

# O /data só existe de verdade em runtime (é volume), e nasce dono do root —
# por isso o ajuste de permissão e o drop de privilégio ficam no entrypoint,
# não num `USER` estático.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'set -e' \
      'mkdir -p /data/home /data/logs' \
      'chown -R node:node /data 2>/dev/null || true' \
      'exec gosu node "$@"' \
    > /usr/local/bin/entrypoint.sh \
    && chmod +x /usr/local/bin/entrypoint.sh

ENV AIONUI_BACKEND_BIN=/usr/local/bin/aioncore \
    NODE_ENV=production \
    AIONUI_PORT=3000 \
    PORT=3000 \
    AIONUI_HOST=0.0.0.0 \
    AIONUI_ALLOW_REMOTE=1 \
    AIONUI_DATA_DIR=/data \
    AIONUI_LOG_DIR=/data/logs \
    AIONUI_STATIC_DIR=/app/out/renderer \
    AIONUI_NO_BUILD=1 \
    AIONUI_OPEN_BROWSER=0

VOLUME ["/data"]
EXPOSE 3000

# --no-build: os assets já foram gerados no builder; sem isso o webui.ts
# tentaria recompilar a cada boot — e no runtime não há toolchain para isso.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bunx", "tsx", "scripts/webui.ts", "--remote", "--no-build"]
