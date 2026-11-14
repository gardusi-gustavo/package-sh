# Agent runner image.
#
# Built from package-sh, published to GHCR. The image contains the agent script
# and opencode; the workflow supplies GITHUB_TOKEN and DEEPSEEK_API_KEY at run
# time. No credential is baked in.
FROM node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl jq ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g opencode-ai

COPY infra/scripts/agent /usr/local/share/agent
RUN chmod +x /usr/local/share/agent/agent.sh \
 && ln -s /usr/local/share/agent/agent.sh /usr/local/bin/agent

ENTRYPOINT ["/usr/local/bin/agent"]
