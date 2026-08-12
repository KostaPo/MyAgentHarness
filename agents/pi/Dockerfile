FROM eclipse-temurin:21-jdk-noble AS java-base

FROM node:24-bookworm-slim

COPY --from=java-base /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates git ripgrep curl postgresql-client maven \
    && rm -rf /var/lib/apt/lists/*

RUN git config --global --add safe.directory /workspace

RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent

RUN pi install npm:@spences10/pi-mcp
RUN npm install -g --ignore-scripts mcp-searxng fetch-mcp

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]