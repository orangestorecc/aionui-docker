# aionui-docker

Imagem Docker do **AionUi WebUI** (modo servidor, sem Electron), publicada no GHCR
e consumida pelo Coolify da N49 em `aionui.n49.com.br`.

```
ghcr.io/orangestorecc/aionui-docker:latest
```

## Por que este repositório existe

O [Dockerfile oficial do AionUi](https://github.com/iOfficeAI/AionUi) está
abandonado: referencia `bun run build:renderer:web` e `scripts/build-server.mjs`,
que não existem mais no repositório — e ainda copia apenas `package.json` antes do
`bun install`, o que quebra a resolução do workspace `@aionui/web-host`. Não há
imagem oficial publicada.

Este Dockerfile reconstrói o caminho que de fato funciona hoje:

1. clona o AionUi na tag alvo (repo completo — é um workspace bun);
2. `bun run package` gera os assets estáticos em `out/renderer`;
3. baixa o **aioncore**, o backend em Rust, do release público do
   [AionCore](https://github.com/iOfficeAI/AionCore);
4. sobe `scripts/webui.ts`, que embrulha o `@aionui/web-host`.

## Build

O GitHub Actions publica automaticamente: a cada push no `Dockerfile`, todo dia às
06:00 UTC (pegando bump de versão do AionUi), ou sob demanda via *workflow_dispatch*
— onde dá para fixar `aionui_ref` e `aioncore_version`.

O build **não roda no servidor da N49** de propósito: são ~3200 pacotes e um bundle
de ~10.300 módulos, com pico acima de 3 GB de heap. Naquela máquina, que também
serve produção, o kernel matava o processo por falta de memória.

As duas versões andam em par — o commit que sobe o AionUi para 2.1.57 sobe o
aioncore para v0.1.68 — e o workflow resolve as duas juntas para não dessincronizar.

## Runtime

| Variável | Default | Função |
|---|---|---|
| `AIONUI_PORT` / `PORT` | `3000` | porta HTTP |
| `AIONUI_HOST` | `0.0.0.0` | interface de escuta |
| `AIONUI_ALLOW_REMOTE` | `1` | libera acesso remoto |
| `AIONUI_DATA_DIR` | `/data` | SQLite, conversas, skills |
| `AIONUI_BACKEND_BIN` | `/usr/local/bin/aioncore` | binário do backend |

Monte um volume em **`/data`** — é onde vive todo o estado. Sem ele, o histórico
se perde a cada redeploy.

No primeiro boot o AionUi cria o usuário `admin` e imprime uma senha aleatória
**uma única vez** no log de startup. Para redefinir depois: `aionui-web resetpass`.
