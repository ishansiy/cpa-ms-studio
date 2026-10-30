# syntax=docker/dockerfile:1
#
# CPA Stack — ModelScope Docker Studio（魔塔社区国际版）
#
# 单容器三进程，全部官方预编译二进制（不编译任何东西）：
#   - CLIProxyAPI v8.0.24     推理网关，127.0.0.1:8317
#   - Oh My CPA   v0.2.6      用量/控制台，127.0.0.1:18901，挂 /omc
#   - CodexComp    v0.1.7     CPA 插件（修 gpt-5.5 系 reasoning truncation）
#   - Caddy                  对外唯一入口 7860，负责分流与请求头净化
#
# 镜像内零凭据：config.yaml（含 api-keys / 上游密钥 / bcrypt 管理口令）与
# 33 个 OAuth 凭据文件全部经 Studio Secret 注入，运行时由 start.sh 落盘。
#
# 官方来源与校验（构建时重新校验，此处仅为可读记录）：
#   CPA   https://github.com/router-for-me/CLIProxyAPI/releases/tag/v8.0.47
#         CLIProxyAPI_8.0.24_linux_amd64.tar.gz  sha256 094a3acffd97e152e2b7c61231404c2e702f2188c5a9acc58a87da0c5dd57db5
#   OMC   https://github.com/WizisCool/oh-my-cpa/releases/tag/v0.3.17
#         oh-my-cpa_0.2.6_linux_amd64.tar.gz     sha256 96e4e30d286934de76c1b7a68e91d59550a442b5f900edf3262c14384a13c352
#   插件  https://github.com/uf-hy/cpa-plugin-codexcomp/releases/tag/v0.1.7
#         codexcomp_0.1.7_linux_amd64.zip        sha256 8191bc0e24f69fc2e58ad8aa3dc7d6d991402345cd39f1241debba7250cdb9ba

FROM debian:bookworm-slim AS downloader

ARG TARGETARCH=amd64
ARG CPA_VERSION=v8.0.47
ARG CPA_SHA256=2b5111dc6a0dfe0d607457787f794330d1b477bc9daa6337c26b0cd032a7827e
ARG OMC_VERSION=v0.3.17
ARG OMC_SHA256=36761c774458b63b7fa96d023f0d2acf236b47b8089e569571d63916af1b8f64
ARG CODEXCOMP_VERSION=v0.1.7
ARG CODEXCOMP_SHA256=8191bc0e24f69fc2e58ad8aa3dc7d6d991402345cd39f1241debba7250cdb9ba

RUN apt-get -o Acquire::Retries=5 update \
    && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
      ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# --- CLIProxyAPI 网关本体（cgo 构建，支持 dlopen 插件） ---
RUN set -eux; \
    asset="CLIProxyAPI_${CPA_VERSION#v}_linux_${TARGETARCH}.tar.gz"; \
    base="https://github.com/router-for-me/CLIProxyAPI/releases/download/${CPA_VERSION}"; \
    curl -fsSL --retry 5 --retry-delay 2 "${base}/${asset}" -o "${asset}"; \
    echo "${CPA_SHA256}  ${asset}" | sha256sum -c -; \
    mkdir -p /out/cpa /tmp/cpa-extract; \
    tar -xzf "${asset}" -C /tmp/cpa-extract; \
    binary="$(find /tmp/cpa-extract -type f -name cli-proxy-api -print -quit)"; \
    test -n "${binary}"; \
    install -m 0755 "${binary}" /out/cpa/cli-proxy-api

# --- Oh My CPA 控制台（单 Go 二进制，内嵌 React SPA） ---
RUN set -eux; \
    ver="${OMC_VERSION#v}"; \
    asset="oh-my-cpa_${ver}_linux_${TARGETARCH}.tar.gz"; \
    base="https://github.com/WizisCool/oh-my-cpa/releases/download/${OMC_VERSION}"; \
    curl -fsSL --retry 5 --retry-delay 2 "${base}/${asset}" -o "${asset}"; \
    echo "${OMC_SHA256}  ${asset}" | sha256sum -c -; \
    mkdir -p /out/omc /tmp/omc-extract; \
    tar -xzf "${asset}" -C /tmp/omc-extract; \
    binary="$(find /tmp/omc-extract -type f -name oh-my-cpa -print -quit)"; \
    test -n "${binary}"; \
    install -m 0755 "${binary}" /out/omc/oh-my-cpa

# --- CodexComp 插件（Go 共享库，CPA 自定义 C ABI v1） ---
RUN set -eux; \
    ver="${CODEXCOMP_VERSION#v}"; \
    asset="codexcomp_${ver}_linux_${TARGETARCH}.zip"; \
    base="https://github.com/uf-hy/cpa-plugin-codexcomp/releases/download/${CODEXCOMP_VERSION}"; \
    curl -fsSL --retry 5 --retry-delay 2 "${base}/${asset}" -o "${asset}"; \
    echo "${CODEXCOMP_SHA256}  ${asset}" | sha256sum -c -; \
    mkdir -p /out/plugins/linux/amd64; \
    unzip -o -q "${asset}" -d /tmp/cc; \
    install -m 0644 "$(find /tmp/cc -type f -name '*.so' -print -quit)" \
      "/out/plugins/linux/amd64/codexcomp-${ver}.so"

FROM debian:bookworm-slim

RUN apt-get -o Acquire::Retries=5 update \
    && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
      bash ca-certificates caddy curl jq sqlite3 tar tzdata gzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=downloader /out/cpa/cli-proxy-api /app/cli-proxy-api
COPY --from=downloader /out/omc/oh-my-cpa /app/oh-my-cpa
COPY --from=downloader /out/plugins/ /opt/cpa-stack/plugins/
COPY start.sh /app/start.sh
COPY Caddyfile /app/Caddyfile

RUN chmod 0755 /app/cli-proxy-api /app/oh-my-cpa /app/start.sh \
    && chmod -R a+rX /opt/cpa-stack/plugins \
    && bash -n /app/start.sh \
    && caddy validate --config /app/Caddyfile --adapter caddyfile

ENV TZ=Asia/Shanghai
ENV DATA_ROOT=/mnt/workspace/cpa-stack
ENV CPA_ADDR=127.0.0.1:8317
# OMC 监听地址由 start.sh 设 OMCPA_LISTEN_ADDR（创空间 8080 被平台 dashboard 占用）
ENV OMC_BASE_PATH=/omc
ENV PORT=7860

EXPOSE 7860

# start-period 给足：首次启动要落盘配置、解包凭据、CPA 加载 30+ OAuth 账号
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
  CMD curl -fsS http://127.0.0.1:7860/healthz >/dev/null || exit 1

CMD ["/app/start.sh"]
