# AionUi WebUI — imagem própria.
#
# O Dockerfile oficial do repo (iOfficeAI/AionUi) está abandonado: referencia
# `bun run build:renderer:web` e `scripts/build-server.mjs`, que não existem mais.
# Este arquivo reconstrói o caminho vivo: `scripts/webui.ts` (que embrulha o
# pacote @aionui/web-host) + o backend Rust `aioncore`, baixado do repo AionCore.
#
# As duas versões andam juntas — o commit que sobe o AionUi para 2.1.57 sobe o
# aioncore para v0.1.68. Manter os dois ARGs em sincronia ao atualizar.

FROM node:20-slim

ARG AIONUI_REF=v2.1.57
ARG AIONCORE_VERSION=v0.1.68
ARG AIONCORE_TARGET=x86_64-unknown-linux-gnu

# Heap do V8 para o bundle do renderer. Ver a nota de calibragem no RUN abaixo.
ARG NODE_HEAP_MB=6144

ENV DEBIAN_FRONTEND=noninteractive

# libicu: o officecli (preview de Office) é um binário .NET que aborta sem ICU.
# git/curl: clone do fonte e download do aioncore.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         git curl ca-certificates libicu-dev python3 build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g bun

WORKDIR /app

# Clone completo do tag: o repo é um workspace bun (`workspaces: packages/*`),
# então packages/ precisa existir ANTES do install — foi exatamente por copiar
# só package.json que o Dockerfile oficial quebrava em @aionui/web-host.
RUN git clone --depth 1 --branch ${AIONUI_REF} https://github.com/iOfficeAI/AionUi.git .

# HUSKY=0: o script `prepare` roda husky, que falha fora de um repo com hooks.
# --ignore-scripts: pula o postinstall, que tentaria baixar o aioncore de um
# artifact do GitHub Actions (precisa de GH_TOKEN). Buscamos do release abaixo.
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

# Diagnóstico: registra RAM/CPU no log, para calibrar o heap abaixo.
# (`free` não existe no node:20-slim — sem procps. /proc/meminfo sempre existe.)
RUN head -3 /proc/meminfo && echo "nproc=$(nproc)"

# Gera out/renderer (assets estáticos servidos pela WebUI).
#
# São ~10.300 módulos num bundle só: com o heap padrão do V8 (~2 GB) o build
# morre com "Reached heap limit". O NODE_OPTIONS fica escopado neste RUN de
# propósito — em runtime não queremos reservar heap à toa.
#
# Calibragem, medida no servidor da N49 (máquina pequena, compartilhada com
# produção): 2048 (padrão do V8) estoura com "Reached heap limit"; 4096 fez o
# kernel matar o processo com SIGKILL — morte seca, sem stack trace.
# No runner do GitHub Actions (16 GB) sobra folga, daí o default de 6144.
RUN NODE_OPTIONS=--max-old-space-size=${NODE_HEAP_MB} bun run package

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

# --no-build: os assets já foram gerados acima; sem isso o webui.ts recompila
# a cada boot do container.
CMD ["bunx", "tsx", "scripts/webui.ts", "--remote", "--no-build"]
